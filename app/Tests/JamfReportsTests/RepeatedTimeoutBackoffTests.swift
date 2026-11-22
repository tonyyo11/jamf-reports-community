import XCTest
@testable import JamfReports

/// A kind that timed out on its last two attempts is left alone by self-remediation, so an
/// hourly retry cannot hold the tick lock for the whole limit each time. Collect now and the
/// tick's same-day retry still try it.
final class RepeatedTimeoutBackoffTests: XCTestCase {

    nonisolated(unsafe) private var dir: URL!
    private let timedOut = CLIBridge.exitCodeTimedOut

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeout-streak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        try super.tearDownWithError()
    }

    private func fail(_ store: StateFileStore, _ code: Int32?, kind: String = "ea-results") {
        store.record(.failed(exitCode: code), report: kind, at: Date())
    }

    func testTheStreakCountsConsecutiveTimeoutsOnly() {
        let store = StateFileStore(directory: dir)
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 0)
        fail(store, timedOut)
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 1)
        fail(store, timedOut)
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 2)
        fail(store, 1)
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 0, "another failure ends it")
        fail(store, timedOut)
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 1, "and it starts again")
        store.record(.landed, report: "ea-results", at: Date())
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 0)
    }

    /// `patch-status` and `patch-device-failures` both start with the patch-title request, so
    /// one timeout of each is two in a row on that request and holds both.
    func testKindsThatShareARequestShareTheStreakAndTheHold() {
        let store = StateFileStore(directory: dir)
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        let second = first.addingTimeInterval(7_200)
        store.record(.failed(exitCode: timedOut), report: "patch-status", at: first)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-device-failures"))
        store.record(.failed(exitCode: timedOut), report: "patch-device-failures", at: second)
        XCTAssertEqual(store.consecutiveTimeouts(for: "patch-status"), 2)
        XCTAssertEqual(store.consecutiveTimeouts(for: "patch-device-failures"), 2)
        let until = second.addingTimeInterval(StateFileStore.timeoutHold)
        XCTAssertEqual(store.timeoutHoldUntil(report: "patch-status"), until)
        XCTAssertEqual(store.timeoutHoldUntil(report: "patch-device-failures"), until)
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 0, "no other kind is held")
        store.record(.landed, report: "patch-status", at: second)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-device-failures"),
                     "the request answered: one timeout left is not a hold")
    }

    func testTheLastDurationIsReadBackAndAnUnreadableOneIsNone() throws {
        let store = StateFileStore(directory: dir)
        XCTAssertNil(store.lastDuration(for: "ea-results"))
        store.recordDuration(report: "ea-results", seconds: 722)
        XCTAssertEqual(store.lastDuration(for: "ea-results"), 722)
        try "soon".write(
            to: dir.appendingPathComponent("ea-results.took"), atomically: true, encoding: .utf8)
        XCTAssertNil(store.lastDuration(for: "ea-results"))
    }

    /// The planner's hold: 20 hours after the last failure once two in a row timed out.
    func testTheHoldStartsAfterTwoTimeoutsInARowAndEndsWhenTheKindLands() throws {
        let store = StateFileStore(directory: dir)
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-status"))
        store.record(.failed(exitCode: timedOut), report: "patch-status", at: first)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-status"), "one timeout is retried")
        let second = first.addingTimeInterval(3_600)
        store.record(.failed(exitCode: timedOut), report: "patch-status", at: second)
        XCTAssertEqual(
            store.timeoutHoldUntil(report: "patch-status"),
            second.addingTimeInterval(StateFileStore.timeoutHold))
        store.record(.failed(exitCode: 1), report: "patch-status", at: second)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-status"), "another failure is no hold")
        store.record(.failed(exitCode: timedOut), report: "patch-status", at: second)
        store.record(.failed(exitCode: timedOut), report: "patch-status", at: second)
        store.record(.landed, report: "patch-status", at: second)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-status"))
    }

    /// An older build reads only the two- and three-field `.fail` forms, and a record without a
    /// streak file reads as none.
    func testAPeerWrittenFutureDateOrHugeCountHoldsNothing() throws {
        let store = StateFileStore(directory: dir)
        let future = Date().addingTimeInterval(SharedWorkspace.clockSkewTolerance * 2)
        for _ in 0..<4 {
            store.record(.failed(exitCode: timedOut), report: "computers", at: future)
        }
        XCTAssertNil(store.timeoutHoldUntil(report: "computers"),
                     "a failure dated ahead holds nothing")
        XCTAssertTrue(CadenceResolver.isDue(lastRun: future, cadence: .seconds(86_400)),
                      "a success dated ahead cannot make a source not due")

        fail(store, timedOut, kind: "patch-status")
        fail(store, timedOut, kind: "patch-device-failures")
        for kind in ["patch-status", "patch-device-failures"] {
            try "\(Int.max)".write(to: dir.appendingPathComponent("\(kind).timeouts"),
                                    atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(store.consecutiveTimeouts(for: "patch-status"), Int.max,
                       "the shared sum saturates instead of trapping")
    }

    func testTheFailFileKeepsItsFormatAndAnOlderRecordReadsAsNoStreak() throws {
        let store = StateFileStore(directory: dir)
        fail(store, timedOut)
        let text = try String(
            contentsOf: dir.appendingPathComponent("ea-results.fail"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: " ").count, 3, text)
        XCTAssertEqual(store.lastFailureExitCode(for: "ea-results"), timedOut)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("ea-results.timeouts"))
        XCTAssertEqual(store.consecutiveTimeouts(for: "ea-results"), 0)
    }

    func testSelfRemediationLeavesAKindAloneAfterTwoTimeoutsInARow() {
        let store = StateFileStore(directory: dir)
        fail(store, timedOut)
        XCTAssertFalse(WorkspaceStore.lastFailureRepeatsOnRetry(
            "ea-results", in: store, countingRepeatedTimeouts: true), "one timeout still retries")
        fail(store, timedOut)
        XCTAssertTrue(WorkspaceStore.lastFailureRepeatsOnRetry(
            "ea-results", in: store, countingRepeatedTimeouts: true))
        XCTAssertFalse(WorkspaceStore.lastFailureRepeatsOnRetry("ea-results", in: store),
                       "Collect now and the unauthorized-aware callers keep the old rule")
    }

    /// A 60-minute timeout retried at 1 h, 2 h and 4 h held the tick lock most of the day.
    func testTheSameDayRetryLeavesASourceAloneAfterTwoTimeoutsInARow() throws {
        let profile = "retry-timeout"
        let root = dir.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let start = Date()
        let watcher = CollectHonestyWatcher()
        watcher.observe(ReportEngine.unlandedSourcesLine(["patch-status"], attempted: 20))

        fail(store, timedOut, kind: "patch-status")
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile), "one timeout still retries")
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start))
        fail(store, timedOut, kind: "patch-status")
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile))
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start))

        watcher.observe(ReportEngine.unlandedSourcesLine(["patch-status", "computers"], attempted: 20))
        fail(store, 1, kind: "computers")
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile),
                      "another source that failed for a retryable reason still retries")
    }

    func testTheRemediationFilterDropsTheRepeatedlyTimedOutKind() throws {
        let profile = "timeout-backoff"
        let root = dir.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        fail(store, timedOut, kind: "ea-results")
        fail(store, timedOut, kind: "ea-results")
        fail(store, 1, kind: "policies")
        let issues = ["ea-results", "policies"].map {
            DataFreshnessIssue(
                snapshotKind: $0, tier: .inventory, kind: .failing, lastSuccess: nil,
                consecutiveFailures: 2, lastFailure: Date())
        }

        let kept = WorkspaceStore.excludingPermanentUsageFailures(issues, profile: profile)

        XCTAssertEqual(kept.map(\.snapshotKind), ["policies"])
    }
}
