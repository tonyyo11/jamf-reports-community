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

    /// An older build reads only the two- and three-field `.fail` forms, and a record without a
    /// streak file reads as none.
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
        XCTAssertFalse(WorkspaceStore.lastFailureRepeatsOnRetry(
            "ea-results", in: store, countingUnauthorized: false),
                       "the tick's same-day retry keeps trying")
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
