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
