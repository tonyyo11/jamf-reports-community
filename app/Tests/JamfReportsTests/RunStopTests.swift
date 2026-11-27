import XCTest
@testable import JamfReports

/// A scheduled run gives up the lock between sources when its budget is used or someone asks
/// for a refresh in the app. What is left stays due, the run is not Partial, and the
/// background item comes back for it.
final class RunStopTests: XCTestCase {

    private var root: URL!
    private let profile = "runstop"

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line.text) } }
        var all: [String] { lock.withLock { stored } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-RunStop-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testTheDecisionPutsAManualRefreshAheadOfTheBudget() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func stop(
            after seconds: TimeInterval, refresh: ManualRefreshRequest.Pending = .none
        ) -> ReportEngine.RunStop? {
            ReportEngine.RunStop.evaluate(
                started: start, budgetMinutes: 45, refresh: refresh, profile: "a",
                now: start.addingTimeInterval(seconds))
        }
        XCTAssertNil(stop(after: 2_699))
        XCTAssertEqual(stop(after: 2_700), .budgetUsed(minutes: 45))
        XCTAssertEqual(stop(after: 10, refresh: .unnamed), .manualRefresh(sameWorkspaceFull: true))
        XCTAssertEqual(stop(after: 9_000, refresh: .named(workspace: "a", full: true)),
                       .manualRefresh(sameWorkspaceFull: true))
        XCTAssertEqual(stop(after: 10, refresh: .named(workspace: "b", full: true)),
                       .manualRefresh(sameWorkspaceFull: false))
        XCTAssertEqual(stop(after: 10, refresh: .named(workspace: "a", full: false)),
                       .manualRefresh(sameWorkspaceFull: false))
    }

    func testTheRequestNamesItsWorkspaceAndWhetherItIsFull() throws {
        let support = root.appendingPathComponent("named-support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let now = Date()
        ManualRefreshRequest.post(workspace: "acme", full: false, now: now, appSupport: support)
        XCTAssertEqual(ManualRefreshRequest.pending(now: now, appSupport: support),
                       .named(workspace: "acme", full: false))
        ManualRefreshRequest.post(now: now, appSupport: support)
        XCTAssertEqual(ManualRefreshRequest.pending(now: now, appSupport: support), .unnamed)
        XCTAssertTrue(isPending(now: now, appSupport: support))
    }

    func testTheBudgetSettingsAreClampedAndAMistypedOneReadsAsTheDefault() throws {
        func config(_ yaml: String) throws -> JamfCLIConfig {
            try XCTUnwrap(ConfigLoader.loadFromString(yaml).jamfCli)
        }
        let absent = try config("jamf_cli:\n  profile: \"x\"\n")
        XCTAssertEqual(absent.resolvedRunBudgetMinutes, 45)
        XCTAssertEqual(absent.resolvedScanBudgetMinutes, 30)
        let typed = try config("jamf_cli:\n  run_budget_minutes: 90\n  scan_budget_minutes: 1\n")
        XCTAssertEqual(typed.resolvedRunBudgetMinutes, 90)
        XCTAssertEqual(typed.resolvedScanBudgetMinutes, 5)
        let wrong = try config("jamf_cli:\n  run_budget_minutes: soon\n  scan_budget_minutes: 999\n")
        XCTAssertEqual(wrong.resolvedRunBudgetMinutes, 45)
        XCTAssertEqual(wrong.resolvedScanBudgetMinutes, 240)
    }

    func testARequestIsPendingForItsLifetimeOnly() {
        let support = root.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let posted = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(isPending(now: posted, appSupport: support))
        ManualRefreshRequest.post(now: posted, appSupport: support)
        XCTAssertTrue(isPending(now: posted, appSupport: support))
        XCTAssertTrue(isPending(
            now: posted.addingTimeInterval(ManualRefreshRequest.lifetime), appSupport: support))
        XCTAssertFalse(isPending(
            now: posted.addingTimeInterval(ManualRefreshRequest.lifetime + 1), appSupport: support),
            "a request an app left behind cannot stop every later run")
        XCTAssertFalse(isPending(
            now: posted.addingTimeInterval(-3_600), appSupport: support), "dated ahead of now")
        ManualRefreshRequest.clear(appSupport: support)
        XCTAssertFalse(isPending(now: posted, appSupport: support))
    }

    /// Protect and Security Cloud figures reach the daily summary from the run that landed
    /// them, so the cadence holds only within a local day.
    func testAnAddOnSourceIsDueOnEachLocalDaysFirstUnforcedRun() throws {
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let store = StateFileStore(directory: stateDir)
        let calendar = Calendar.current
        let evening = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 16, hour: 22)))
        store.record(.landed, report: "protect-computers", at: evening)
        let commands = [(args: ["x"], kind: "protect-computers")]
        func skip(at now: Date) -> ReportEngine.CollectSkipReason? {
            ReportEngine.$addOnCollectForced.withValue(false) {
                ReportEngine.planAddOn(commands: commands, stateStore: store, now: now)[0].skip
            }
        }
        XCTAssertNotNil(skip(at: evening.addingTimeInterval(3_600)), "same day, inside 12 hours")
        XCTAssertNil(skip(at: evening.addingTimeInterval(8 * 3_600)),
                     "the next morning is under 12 hours later and still collects")
        XCTAssertNil(ReportEngine.planAddOn(
            commands: commands, stateStore: store, now: evening.addingTimeInterval(60))[0].skip,
                     "a direct or forced call collects everything")
    }

    func testAProtectCollectStopsBeforeItsNextSource() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let stub = root.appendingPathComponent("bin/stub-cli")
        let calls = root.appendingPathComponent("protect-calls")
        try "#!/bin/sh\necho x >> '\(calls.path)'\nprintf '[]'\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let asked = Counter()
        let lines = Lines()
        let landed = try await ReportEngine.$runStop.withValue({
            asked.next() > 1 ? .manualRefresh(sameWorkspaceFull: true) : nil
        }) {
            try await ReportEngine.protectCollect(
                profile: profile, dataDir: data, locateJamfCLI: { stub },
                readVersion: { _ in "1.38.0" }, onLine: lines.add)
        }
        let first = try XCTUnwrap(ReportEngine.protectCommandMatrix(profile: profile).first?.kind)
        XCTAssertEqual(landed, [first])
        XCTAssertEqual(
            try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertTrue(lines.all.contains {
            $0.hasPrefix(ReportEngine.stoppedEarlyMarker + "stopped for a manual refresh")
        }, "\(lines.all)")
        XCTAssertFalse(lines.all.contains { $0.hasPrefix("[partial]") }, "\(lines.all)")
    }

    /// The app's own background refresh, self-repair and catch-up stop for a manual refresh
    /// too: the click waits for them instead of getting "A refresh is already running".
    @MainActor
    func testAManualRefreshWaitsForAnAutomaticCollectInThisApp() async throws {
        let lock = useTemporaryTickLock()
        _ = lock
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.manualRefreshWait = 5
        store.manualRefreshPoll = 0.05
        let idle = await store.manualCollectMayStart(full: true)
        XCTAssertTrue(idle, "nothing is running")

        WorkspaceStore.automaticCollectsRunning.withLock { $0 += 1 }
        let finishing = Task {
            try? await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(ManualRefreshRequest.pending() != .none, "the automatic collect is asked to stop")
            WorkspaceStore.automaticCollectsRunning.withLock { $0 -= 1 }
        }
        let mayStart = await store.manualCollectMayStart(full: true)
        await finishing.value
        XCTAssertTrue(mayStart)
        XCTAssertFalse(ManualRefreshRequest.pending() != .none, "the request is withdrawn")
        XCTAssertNil(store.globalStatus)
    }

    /// Trends advance before the slow part of a run, but only from a run with no failure so
    /// far: the dead-run verdicts are judged at the end.
    func testTheSummaryIsWrittenBeforeASlowSourceUnlessSomethingFailed() async throws {
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("bin/stub-cli")
        let failOverview = root.appendingPathComponent("fail-overview")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *"pro overview"*) [ -f '\(failOverview.path)' ] && exit 1 ;;
          *"report security"*)
            printf '%s' '[{"section":"summary","data":{"total_devices":3,"filevault_encrypted":3,\
        "gatekeeper_enabled":3,"sip_enabled":3,"firewall_enabled":3}}]'
            exit 0 ;;
        esac
        printf '[]'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        store.recordDuration(report: "patch-status", seconds: 500)

        func run() async throws -> [String] {
            let lines = Lines()
            _ = try? await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
                force: true, authConfirmationProbe: { _, _ in false },
                locateJamfCLI: { stub }, refreshSOFA: { _ in (.empty, []) }, onLine: lines.add)
            return lines.all
        }
        let early = "[info] summary written before the slow sources"

        let clean = try await run()
        let wrote = try XCTUnwrap(clean.firstIndex(of: early), "\(clean)")
        let slow = try XCTUnwrap(
            clean.firstIndex(of: "[info] collecting patch-status for \(profile)"))
        XCTAssertLessThan(wrote, slow)
        XCTAssertEqual(slow, clean.lastIndex { $0.hasPrefix("[info] collecting ") && !$0.contains("sofa") && !$0.contains("patch-release") },
                       "the slow source runs last")

        let summaries = try WorkspacePaths.summariesDir(for: profile)
        for name in try FileManager.default.contentsOfDirectory(atPath: summaries.path) {
            try FileManager.default.removeItem(at: summaries.appendingPathComponent(name))
        }
        store.recordDuration(report: "patch-status", seconds: 500)
        try Data().write(to: failOverview)
        let failed = try await run()
        XCTAssertFalse(failed.contains(early), "a failure so far waits for the verdicts: \(failed)")
    }

    func testAStoppedRunLeavesTheRestDueAndIsNotPartial() async throws {
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("bin/stub-cli")
        let calls = root.appendingPathComponent("calls")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        echo "$*" >> '\(calls.path)'
        printf '[]'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let lines = Lines()
        let watcher = CollectHonestyWatcher()
        let asked = Counter()
        // Lets two sources run, then stops.
        try await ReportEngine.$runStop.withValue({
            asked.next() > 2 ? .budgetUsed(minutes: 45) : nil
        }) {
            _ = try await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
                force: true, authConfirmationProbe: { _, _ in false },
                locateJamfCLI: { stub }, refreshSOFA: { _ in (.empty, []) },
                onLine: { lines.add($0); watcher.observe($0.text) })
        }

        let ran = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
            .filter { $0.contains(" pro ") }
        XCTAssertEqual(ran.count, 2, "\(ran)")
        let stopLine = try XCTUnwrap(
            lines.all.first { $0.hasPrefix(ReportEngine.stoppedEarlyMarker) }, "\(lines.all)")
        XCTAssertTrue(stopLine.contains("run budget used (45 minutes)"), stopLine)
        XCTAssertTrue(stopLine.contains("left for the next run"), stopLine)
        XCTAssertFalse(lines.all.contains { $0.contains("collecting sofa") },
                       "nothing else starts after the stop")
        // On a workspace with nothing to summarize yet, a stopped run is still not Partial: the
        // summary line is information, and the retry writes the summary.
        XCTAssertFalse(lines.all.contains { $0.hasPrefix("[partial]") }, "\(lines.all)")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("[info] summary not written yet:") })
        XCTAssertFalse(watcher.incomplete)
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile),
                      "the background item comes back for what is left")
        let stopOnly = watcher
        // Exit 0 that does not end the retries: `TickScheduler` retries it after its backoff.
        let outcome = ScheduleRunOutcome(
            exitCode: 0, incomplete: stopOnly.incomplete,
            retryCouldHelp: stopOnly.retryCouldHelp(profile: profile, exitCode: 0, since: Date()))
        XCTAssertFalse(outcome.endsRetries)
        XCTAssertFalse(outcome.incomplete)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let matrix = ReportEngine.collectCommandMatrix(profile: profile, staleDays: 30)
        let left = matrix.map(\.kind).filter {
            CollectionTier.tier(forReport: $0) == .refresh && store.lastRun(report: $0) == nil
        }
        XCTAssertFalse(left.isEmpty)
        XCTAssertTrue(left.allSatisfy { store.failures(report: $0) == nil },
                      "a source the run never started records no failure")
    }
}

private func isPending(now: Date, appSupport: URL) -> Bool {
    ManualRefreshRequest.pending(now: now, appSupport: appSupport) != .none
}
