import XCTest
@testable import JamfReports

/// A shared-workspace freshness stand-down ends the day only when today's summary exists.
final class StandDownRetryTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "standdown"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standdown-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func watcherAfterFreshnessStandDown() -> CollectHonestyWatcher {
        let watcher = CollectHonestyWatcher()
        watcher.observe(ReportEngine.standDownLine(
            reason: "[info] skipping collect — peer-mac collected 14 hours ago"))
        return watcher
    }

    func testAFreshnessStandDownIsRetriedWhileTodaysSummaryIsMissing() {
        let watcher = watcherAfterFreshnessStandDown()
        XCTAssertFalse(watcher.incomplete, "Run History still shows a clean stand-down")
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile, now: .testNoon))
        let outcome = ScheduleRunOutcome(
            exitCode: 0, incomplete: watcher.incomplete,
            retryCouldHelp: watcher.retryCouldHelp(profile: profile, now: .testNoon))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(outcome.endsRetries, "the tick must not stamp the day done")
    }

    func testAFreshnessStandDownEndsTheDayOnceTodaysSummaryExists() throws {
        let dir = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let today = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("summary_\(today).json"))
        XCTAssertFalse(
            watcherAfterFreshnessStandDown().retryCouldHelp(profile: profile, now: .testNoon))
    }

    /// A dead collect prints no `[partial]` line, so the verdict comes from the failures it
    /// recorded: one a retry repeats (exit 8, a 403) ends the hourly retries, an outage does not.
    func testAFailedRunIsJudgedByTheFailuresItRecorded() throws {
        let start = Date().addingTimeInterval(-60)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let watcher = CollectHonestyWatcher()
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start),
                      "nothing recorded: retry as before")
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile, exitCode: 0, since: start))
        try store.recordFailure(report: "computers", at: start.addingTimeInterval(-3600),
                                exitCode: 1)
        try store.recordFailure(report: "policies", at: start, exitCode: 8)
        let forbidden = FailureCause(kind: .missingPermission, names: [], hint: nil, exitCode: 5)
        store.record(.failed(exitCode: 5), report: "patch-status", at: start, cause: forbidden)
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start),
                       "an older failure is not this run's")
        try store.recordFailure(report: "computers", at: start, exitCode: 1)
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start))
    }

    func testARunThatDidNotStandDownIsUnaffected() {
        let watcher = CollectHonestyWatcher()
        watcher.observe("[ok] collected")
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile, now: .testNoon))
    }
}
