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
        func stop(after seconds: TimeInterval, pending: Bool = false) -> ReportEngine.RunStop? {
            ReportEngine.RunStop.evaluate(
                started: start, budgetMinutes: 45, manualRefreshPending: pending,
                now: start.addingTimeInterval(seconds))
        }
        XCTAssertNil(stop(after: 2_699))
        XCTAssertEqual(stop(after: 2_700), .budgetUsed(minutes: 45))
        XCTAssertEqual(stop(after: 10, pending: true), .manualRefresh)
        XCTAssertEqual(stop(after: 9_000, pending: true), .manualRefresh)
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
        XCTAssertFalse(ManualRefreshRequest.isPending(now: posted, appSupport: support))
        ManualRefreshRequest.post(now: posted, appSupport: support)
        XCTAssertTrue(ManualRefreshRequest.isPending(now: posted, appSupport: support))
        XCTAssertTrue(ManualRefreshRequest.isPending(
            now: posted.addingTimeInterval(ManualRefreshRequest.lifetime), appSupport: support))
        XCTAssertFalse(ManualRefreshRequest.isPending(
            now: posted.addingTimeInterval(ManualRefreshRequest.lifetime + 1), appSupport: support),
            "a request an app left behind cannot stop every later run")
        XCTAssertFalse(ManualRefreshRequest.isPending(
            now: posted.addingTimeInterval(-3_600), appSupport: support), "dated ahead of now")
        ManualRefreshRequest.clear(appSupport: support)
        XCTAssertFalse(ManualRefreshRequest.isPending(now: posted, appSupport: support))
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
        XCTAssertFalse(
            lines.all.contains { $0.contains(ReportEngine.unlandedSourcesMarker) },
            "a source the run did not start is not one that failed to land: \(lines.all)")
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile),
                      "the background item comes back for what is left")
        // The stop alone is not Partial (the stub's empty rows are why no summary was written).
        let stopOnly = CollectHonestyWatcher()
        stopOnly.observe(stopLine)
        XCTAssertFalse(stopOnly.incomplete)
        XCTAssertTrue(stopOnly.retryCouldHelp(profile: profile))
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
