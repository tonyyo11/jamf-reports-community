import Foundation
import XCTest
@testable import JamfReports

/// v2.2.0 managed-agent layer. The correctness weight is on `owns` (never
/// removes a user agent), `desiredSchedules` (policy → specs), and `plan`
/// (idempotent diff). `reconcile` is exercised through injected spies so no
/// real `launchctl` runs.
final class ManagedAutomationTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    private func userMultiSchedule(name: String) -> Schedule {
        Schedule(
            name: name, profile: "alpha", schedule: "Daily 09:00", cadence: "daily",
            mode: .jamfCLIFull, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "\(prefix).multi.\(name)",
            multiTarget: MultiTarget(scope: .all)
        )
    }

    private func managedProfiles(_ names: [String]) -> [JamfCLIProfile] {
        names.map { JamfCLIProfile(name: $0, url: "(local)", schedules: 0, status: .idle) }
    }

    // MARK: - Ownership (the destructive-action guard)

    func testOwnsAcceptsOnlyExactReservedLabels() {
        for kind in ManagedAutomation.ManagedKind.allCases {
            XCTAssertTrue(ManagedAutomation.owns(ManagedAutomation.label(for: kind)))
        }
        // Prefix-y impostors must NOT be owned — reconcile would otherwise
        // bootout a user's agent named like a managed one.
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).multi.managed-freshness-2"))
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).multi.managed-freshnessX"))
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).multi.my-schedule"))
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).alpha.managed-freshness"))
        XCTAssertFalse(ManagedAutomation.owns("com.evil.multi.managed-freshness"))
    }

    // MARK: - Desired specs

    func testNoDesiredWhenUnmanaged() {
        XCTAssertTrue(
            ManagedAutomation.desiredSchedules(for: AutomationPolicy(), baseProfile: "alpha").isEmpty
        )
    }

    func testNoDesiredWithoutBaseProfile() {
        var p = AutomationPolicy(); p.isManaged = true
        XCTAssertTrue(ManagedAutomation.desiredSchedules(for: p, baseProfile: nil).isEmpty)
    }

    func testManagedAllPoliciesProduceFourAgents() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.backupsEnabled = true
        let desired = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
        let labels = Set(desired.compactMap(\.launchAgentLabel))
        XCTAssertEqual(labels, ManagedAutomation.reservedLabels)
        XCTAssertTrue(desired.allSatisfy(\.isMulti))
    }

    func testReportsOffAndBackupsOffDropThoseAgents() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.reportsCadence = .off
        p.backupsEnabled = false
        let labels = Set(
            ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
                .compactMap(\.launchAgentLabel)
        )
        XCTAssertEqual(labels, [
            ManagedAutomation.label(for: .freshness),
            ManagedAutomation.label(for: .scan),
        ])
    }

    func testPerKindModesTiersAndCadenceStrings() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.backupsEnabled = true
        p.scanWeekday = 1        // Mon
        p.reportsWeekday = 1     // Mon
        p.backupsWeekday = 0     // Sun
        let byLabel = Dictionary(
            uniqueKeysWithValues: ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
                .map { ($0.launchAgentLabel ?? "", $0) }
        )

        let freshness = byLabel[ManagedAutomation.label(for: .freshness)]
        XCTAssertEqual(freshness?.mode, .snapshotOnly)
        XCTAssertEqual(freshness?.tiers, [.refresh, .inventory])
        XCTAssertEqual(freshness?.schedule, "Daily 06:00")

        let scan = byLabel[ManagedAutomation.label(for: .scan)]
        XCTAssertEqual(scan?.mode, .snapshotOnly)
        XCTAssertEqual(scan?.tiers, [.scan])
        XCTAssertEqual(scan?.schedule, "Mon 06:10", "scan staggered +10")

        let reports = byLabel[ManagedAutomation.label(for: .reports)]
        XCTAssertEqual(reports?.mode, .jamfCLIOnly, "reports generate from fresh cache")
        XCTAssertNil(reports?.tiers)
        XCTAssertEqual(reports?.schedule, "Mon 06:20", "reports staggered +20")

        let backup = byLabel[ManagedAutomation.label(for: .backup)]
        XCTAssertEqual(backup?.mode, .backup)
        XCTAssertEqual(backup?.schedule, "Sun 06:30", "backup staggered +30")
    }

    func testExclusionsFlowIntoDesiredSchedules() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.excludedProfiles = ["dummy"]
        let desired = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
        XCTAssertTrue(desired.allSatisfy { $0.excludedProfiles == ["dummy"] })
    }

    func testStaggeredTimeClampsWithinDay() {
        XCTAssertEqual(ManagedAutomation.staggeredTime(base: "06:00", offsetMinutes: 30), "06:30")
        XCTAssertEqual(ManagedAutomation.staggeredTime(base: "23:50", offsetMinutes: 30), "23:59")
        XCTAssertEqual(ManagedAutomation.staggeredTime(base: "06:55", offsetMinutes: 10), "07:05")
    }

    /// The writer must emit the same string shape
    /// `LaunchAgentService.formatCalendar` renders on read-back ("Day N HH:mm"),
    /// not the ordinal form — otherwise a monthly reports agent's signature
    /// never converges and it reinstalls on every reconcile.
    func testMonthlyReportsCadenceStringMatchesReaderFormat() {
        var p = AutomationPolicy(); p.isManaged = true
        p.reportsCadence = .monthly
        p.reportsDayOfMonth = 15
        let reports = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
            .first { $0.launchAgentLabel == ManagedAutomation.label(for: .reports) }
        XCTAssertEqual(reports?.schedule, "Day 15 06:20", "reports staggered +20")
    }

    /// Real round trip through `LaunchAgentWriter.nativeMultiWrite` (the
    /// writer that consumes this string) and `LaunchAgentService.parse` (the
    /// reader that renders it back) — proves the strings agree end to end,
    /// not just that both sides independently produce "Day N".
    func testMonthlyReportsScheduleRoundTripsWithoutReinstallLoop() throws {
        var p = AutomationPolicy(); p.isManaged = true
        p.reportsCadence = .monthly
        p.reportsDayOfMonth = 15
        let desired = try XCTUnwrap(
            ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
                .first { $0.launchAgentLabel == ManagedAutomation.label(for: .reports) }
        )

        let plan = try writeFakeMultiPlist(for: desired)
        defer { removeFakeMultiPlist(plan) }

        let installedBack = try XCTUnwrap(LaunchAgentService.parse(plan.plistURL))
        XCTAssertEqual(installedBack.schedule, desired.schedule,
                       "writer and reader must agree on the monthly cadence string")

        let actions = ManagedAutomation.plan(for: p, installed: [installedBack], baseProfile: "alpha")
        XCTAssertFalse(
            actions.contains {
                if case .install(let s) = $0 { return s.launchAgentLabel == desired.launchAgentLabel }
                return false
            },
            "a monthly reports agent whose real on-disk schedule already matches must not be reinstalled"
        )
    }

    // MARK: - Plan

    func testPlanInstallsAllWhenNothingInstalled() {
        var p = AutomationPolicy(); p.isManaged = true
        let actions = ManagedAutomation.plan(for: p, installed: [], baseProfile: "alpha")
        let installs = actions.compactMap { action -> String? in
            if case .install(let s) = action { return s.launchAgentLabel }
            return nil
        }
        // freshness + scan + reports (backups off by default).
        XCTAssertEqual(Set(installs), [
            ManagedAutomation.label(for: .freshness),
            ManagedAutomation.label(for: .scan),
            ManagedAutomation.label(for: .reports),
        ])
        XCTAssertFalse(actions.contains { if case .remove = $0 { return true }; return false })
    }

    func testPlanSkipsUnchangedAndReinstallsOnForce() {
        var p = AutomationPolicy(); p.isManaged = true
        let installed = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")

        // Same specs already installed → no actions.
        XCTAssertTrue(
            ManagedAutomation.plan(for: p, installed: installed, baseProfile: "alpha").isEmpty
        )
        // force → reinstall every desired agent.
        let forced = ManagedAutomation.plan(
            for: p, installed: installed, baseProfile: "alpha", force: true
        )
        XCTAssertEqual(forced.count, installed.count)
        XCTAssertTrue(forced.allSatisfy { if case .install = $0 { return true }; return false })
    }

    func testPlanReinstallsWhenCadenceChanges() {
        var p = AutomationPolicy(); p.isManaged = true
        let installed = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
        p.runTime = "08:00"  // every cadence string changes → all reinstall
        let actions = ManagedAutomation.plan(for: p, installed: installed, baseProfile: "alpha")
        XCTAssertEqual(actions.filter { if case .install = $0 { return true }; return false }.count,
                       installed.count)
    }

    func testPlanRemovesManagedAgentsWhenTurnedOff() {
        var on = AutomationPolicy(); on.isManaged = true
        let installed = ManagedAutomation.desiredSchedules(for: on, baseProfile: "alpha")
        // isManaged off → desired empty → remove every installed managed agent.
        let actions = ManagedAutomation.plan(
            for: AutomationPolicy(), installed: installed, baseProfile: "alpha"
        )
        let removes = actions.compactMap { action -> String? in
            if case .remove(let l) = action { return l }
            return nil
        }
        XCTAssertEqual(Set(removes), Set(installed.compactMap(\.launchAgentLabel)))
    }

    func testPlanNeverRemovesUserOwnedAgents() {
        var p = AutomationPolicy(); p.isManaged = true
        // A user multi-schedule + a managed-but-undesired one (backups off).
        let userAgent = userMultiSchedule(name: "my-nightly")
        let strayManaged = ManagedAutomation.desiredSchedules(
            for: { var q = AutomationPolicy(); q.isManaged = true; q.backupsEnabled = true; return q }(),
            baseProfile: "alpha"
        ).first { $0.launchAgentLabel == ManagedAutomation.label(for: .backup) }!

        let installed = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
            + [userAgent, strayManaged]
        let actions = ManagedAutomation.plan(for: p, installed: installed, baseProfile: "alpha")

        let removes = actions.compactMap { action -> String? in
            if case .remove(let l) = action { return l }
            return nil
        }
        // Only the stray managed backup is removed; the user's agent is never touched.
        XCTAssertEqual(removes, [ManagedAutomation.label(for: .backup)])
        XCTAssertFalse(removes.contains(userAgent.launchAgentLabel ?? ""))
    }

    // MARK: - Plan (exclusions in the signature)

    /// Two schedules that agree on everything but exclusions must now be
    /// treated as changed (`signature()` includes them); two that agree on
    /// exclusions too must still be treated as unchanged (no reinstall loop).
    func testPlanReinstallsOnlyWhenExclusionsActuallyDiffer() {
        var p = AutomationPolicy(); p.isManaged = true
        p.excludedProfiles = ["dummy"]
        let installed = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")

        // Identical exclusions → identical signature → no actions.
        XCTAssertTrue(
            ManagedAutomation.plan(for: p, installed: installed, baseProfile: "alpha").isEmpty,
            "matching exclusions must not produce a reinstall loop"
        )

        // Exclusions-only edit → every desired agent's signature now differs.
        var changed = p
        changed.excludedProfiles = ["dummy", "sandbox"]
        let actions = ManagedAutomation.plan(for: changed, installed: installed, baseProfile: "alpha")
        XCTAssertFalse(actions.isEmpty, "an exclusions-only policy edit must now be detected")
        XCTAssertTrue(actions.allSatisfy { if case .install = $0 { return true }; return false })
    }

    /// The trap this fix avoids: before `LaunchAgentService.parse` read
    /// `--exclude-profiles` back, an installed agent's `excludedProfiles`
    /// was always nil, so once exclusions were included in the signature a
    /// non-empty exclusion set would have mismatched FOREVER. Round-trips a
    /// real plist to prove that no longer happens.
    func testPlanNoReinstallLoopWhenExclusionsRoundTripThroughRealPlist() throws {
        var p = AutomationPolicy(); p.isManaged = true
        p.excludedProfiles = ["dummy", "sandbox"]
        let desired = try XCTUnwrap(
            ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
                .first { $0.launchAgentLabel == ManagedAutomation.label(for: .freshness) }
        )

        let plan = try writeFakeMultiPlist(for: desired)
        defer { removeFakeMultiPlist(plan) }

        let installedBack = try XCTUnwrap(LaunchAgentService.parse(plan.plistURL))
        XCTAssertEqual(installedBack.excludedProfiles, ["dummy", "sandbox"],
                       "--exclude-profiles must round-trip so the signature check can see them")

        let actions = ManagedAutomation.plan(for: p, installed: [installedBack], baseProfile: "alpha")
        XCTAssertFalse(
            actions.contains {
                if case .install(let s) = $0 { return s.launchAgentLabel == desired.launchAgentLabel }
                return false
            },
            "an agent whose real on-disk exclusions already match the policy must not be reinstalled"
        )
    }

    /// Writes `schedule` via the real `nativeMultiWrite` using a throwaway
    /// fake executable, so tests can round-trip through the actual writer +
    /// `LaunchAgentService.parse` reader instead of comparing in-memory
    /// values computed by the same function on both sides.
    private func writeFakeMultiPlist(for schedule: Schedule) throws -> LaunchAgentWriter.SetupPlan {
        let tempExec = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-jamf-reports-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempExec.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: tempExec.path
        )
        defer { try? FileManager.default.removeItem(at: tempExec) }
        return try LaunchAgentWriter.nativeMultiWrite(for: schedule, executableURL: tempExec, load: false)
    }

    private func removeFakeMultiPlist(_ plan: LaunchAgentWriter.SetupPlan) {
        try? FileManager.default.removeItem(at: plan.plistURL)
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(plan.label)", isDirectory: true)
        try? FileManager.default.removeItem(at: logDir)
    }

    // MARK: - Reconcile (spied execution)

    func testReconcileExecutesPlanThroughInjectedClosures() async {
        var p = AutomationPolicy(); p.isManaged = true
        let installs = CallBox()
        let removes = CallBox()

        let outcomes = await ManagedAutomation.reconcile(
            policy: p,
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { [] },
            install: { schedule in installs.add(schedule.launchAgentLabel ?? schedule.name); return (0, nil) },
            remove: { label in removes.add(label); return nil }
        )

        XCTAssertEqual(installs.count, 3, "freshness + scan + reports installed")
        XCTAssertEqual(removes.count, 0)
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded), "all outcomes succeed when closures return success")
    }

    func testReconcileIsNoOpForUnmanagedWithNoInstalled() async {
        let installs = CallBox()
        let removes = CallBox()
        let outcomes = await ManagedAutomation.reconcile(
            policy: AutomationPolicy(),
            discover: { self.managedProfiles(["alpha"]) },
            installed: { [] },
            install: { _ in installs.add("x"); return (0, nil) },
            remove: { _ in removes.add("x"); return nil }
        )
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(installs.count, 0)
        XCTAssertEqual(removes.count, 0)
    }

    // MARK: - Outcome propagation

    func testReconcileOutcomesCarryFailureReasons() async {
        var p = AutomationPolicy(); p.isManaged = true
        // All three installs fail with distinct reasons.
        let outcomes = await ManagedAutomation.reconcile(
            policy: p,
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { [] },
            install: { _ in return (1, "permission denied") },
            remove: { _ in return nil }
        )
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy { !$0.succeeded })
        XCTAssertTrue(outcomes.allSatisfy { $0.failureReason == "permission denied" })
        XCTAssertTrue(outcomes.allSatisfy(\.isInstall))
    }

    func testReconcileOutcomesMixedSuccessAndFailure() async {
        var p = AutomationPolicy(); p.isManaged = true
        p.backupsEnabled = true
        let callCount = CallBox()
        // First two calls succeed, remaining fail.
        let outcomes = await ManagedAutomation.reconcile(
            policy: p,
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { [] },
            install: { sched in
                callCount.add(sched.name)
                let n = callCount.count
                return n <= 2 ? (0, nil) : (1, "disk full")
            },
            remove: { _ in return nil }
        )
        let succeeded = outcomes.filter(\.succeeded)
        let failed = outcomes.filter { !$0.succeeded }
        XCTAssertEqual(succeeded.count, 2)
        XCTAssertEqual(failed.count, 2)
        XCTAssertTrue(failed.allSatisfy { $0.failureReason == "disk full" })
    }

    func testReconcileRemoveOutcomeCarriesReason() async {
        var on = AutomationPolicy(); on.isManaged = true
        let installed = ManagedAutomation.desiredSchedules(for: on, baseProfile: "alpha")
        // Turn managed off → plan produces removes for every installed agent.
        let outcomes = await ManagedAutomation.reconcile(
            policy: AutomationPolicy(),
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { installed },
            install: { _ in return (0, nil) },
            remove: { _ in return "bootout failed" }
        )
        XCTAssertFalse(outcomes.isEmpty)
        XCTAssertTrue(outcomes.allSatisfy { !$0.isInstall })
        XCTAssertTrue(outcomes.allSatisfy { !$0.succeeded })
        XCTAssertTrue(outcomes.allSatisfy { $0.failureReason == "bootout failed" })
    }

    // MARK: - Self-skip (never bootout the currently-running job's own label)

    func testReconcileRoutesCurrentLabelInstallThroughFileOnly() async {
        var p = AutomationPolicy(); p.isManaged = true
        let normalInstalls = CallBox()
        let fileOnlyInstalls = CallBox()
        let currentLabel = ManagedAutomation.label(for: .scan)

        let outcomes = await ManagedAutomation.reconcile(
            policy: p,
            currentLabel: currentLabel,
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { [] },
            install: { schedule in
                normalInstalls.add(schedule.launchAgentLabel ?? schedule.name)
                return (0, nil)
            },
            installFileOnly: { schedule in
                fileOnlyInstalls.add(schedule.launchAgentLabel ?? schedule.name)
                return (0, nil)
            },
            remove: { _ in return nil }
        )

        // freshness + scan + reports installed (backups off by default) — only
        // the current-label (scan) agent goes through installFileOnly.
        XCTAssertEqual(fileOnlyInstalls.count, 1)
        XCTAssertEqual(normalInstalls.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
    }

    func testReconcileRoutesCurrentLabelRemoveThroughFileOnly() async {
        var on = AutomationPolicy(); on.isManaged = true
        let installed = ManagedAutomation.desiredSchedules(for: on, baseProfile: "alpha")
        let currentLabel = ManagedAutomation.label(for: .freshness)
        let normalRemoves = CallBox()
        let fileOnlyRemoves = CallBox()

        // Turn managed off → plan removes every installed managed agent,
        // including (hypothetically) the one this process is itself running.
        let outcomes = await ManagedAutomation.reconcile(
            policy: AutomationPolicy(),
            currentLabel: currentLabel,
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { installed },
            install: { _ in return (0, nil) },
            remove: { label in normalRemoves.add(label); return nil },
            removeFileOnly: { label in fileOnlyRemoves.add(label); return nil }
        )

        XCTAssertEqual(fileOnlyRemoves.count, 1)
        XCTAssertEqual(normalRemoves.count, installed.count - 1,
                       "sibling managed agents still use the normal path")
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
    }

    func testReconcileNoCurrentLabelUsesNormalPathForEveryAction() async {
        var p = AutomationPolicy(); p.isManaged = true
        let normalInstalls = CallBox()
        let fileOnlyInstalls = CallBox()

        let outcomes = await ManagedAutomation.reconcile(
            policy: p,
            currentLabel: nil,
            discover: { [JamfCLIProfile(name: "alpha", url: "(local)", schedules: 0, status: .idle)] },
            installed: { [] },
            install: { schedule in normalInstalls.add(schedule.name); return (0, nil) },
            installFileOnly: { schedule in fileOnlyInstalls.add(schedule.name); return (0, nil) },
            remove: { _ in return nil }
        )

        XCTAssertEqual(normalInstalls.count, 3)
        XCTAssertEqual(fileOnlyInstalls.count, 0)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
    }

    // MARK: - One-shot migration flag (only set on verified success)

    func testMigrationShouldCompleteOnEmptyPlan() {
        XCTAssertTrue(
            ManagedAutomation.migrationShouldComplete(outcomes: []),
            "nothing needed doing — an empty forced pass still counts as migrated"
        )
    }

    func testMigrationShouldCompleteWhenEveryActionSucceeds() {
        let outcomes = [
            ManagedAutomation.ActionOutcome(
                action: .remove(label: "a"), succeeded: true, failureReason: nil),
            ManagedAutomation.ActionOutcome(
                action: .remove(label: "b"), succeeded: true, failureReason: nil),
        ]
        XCTAssertTrue(ManagedAutomation.migrationShouldComplete(outcomes: outcomes))
    }

    func testMigrationShouldNotCompleteWhenAnyActionFails() {
        let outcomes = [
            ManagedAutomation.ActionOutcome(
                action: .remove(label: "a"), succeeded: true, failureReason: nil),
            ManagedAutomation.ActionOutcome(
                action: .remove(label: "b"), succeeded: false, failureReason: "disk full"),
        ]
        XCTAssertFalse(
            ManagedAutomation.migrationShouldComplete(outcomes: outcomes),
            "a single failure must leave the flag unset so the next pass retries"
        )
    }
}

/// Thread-safe call recorder for the `@Sendable` reconcile spies (the lock-box
/// pattern — capturing a plain `var` in an `@Sendable` closure is rejected under
/// Swift 6 strict concurrency).
private final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    func add(_ label: String) { lock.lock(); labels.append(label); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return labels.count }
}
