import XCTest
@testable import JamfReports

/// Tick-level failures reach Run History under the background item's own label (#226 5d),
/// in the workspace of every profile the affected schedule runs for.
final class TickFailureLogTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-TickFailure-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        for name in ["alpha", "beta", "gamma"] {
            try FileManager.default.createDirectory(
                at: workspacesRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func schedule(multi: Bool = false, excluded: [String]? = nil) -> Schedule {
        Schedule(
            name: "daily", profile: "alpha", schedule: "Daily 06:00", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true,
            launchAgentLabel: "\(LaunchAgentWriter.labelPrefix).alpha.daily",
            multiTarget: multi ? MultiTarget(scope: .all, sequential: true) : nil,
            excludedProfiles: excluded
        )
    }

    private func logText(_ profile: String) throws -> [String] {
        let run = try XCTUnwrap(RunHistoryService.list(profile: profile).first)
        return RunHistoryService.loadLog(run.logURL).map(\.text)
    }

    func testATickFailureShowsInRunHistoryAsAFailedBackgroundItemRun() throws {
        let log = TickFailureLog(profiles: [])
        log.record(schedule(), "skipped daily: its start could not be recorded")
        log.finish()

        let runs = RunHistoryService.list(profile: "alpha")
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.name, "Background item")
        XCTAssertEqual(run.status, .fail)
        let text = try logText("alpha")
        XCTAssertTrue(
            text.contains("[error] tick: skipped daily: its start could not be recorded"), "\(text)")
        XCTAssertTrue(RunHistoryService.list(profile: "beta").isEmpty,
                      "a single-profile schedule's failure stays in its own workspace")
    }

    /// One record per workspace per wake, in every profile a multi schedule runs for.
    func testAMultiScheduleFailureReachesEachProfileItRunsFor() throws {
        let profiles = ["alpha", "beta", "gamma"].map {
            JamfCLIProfile(name: $0, url: "", schedules: 0, status: .ok)
        }
        let log = TickFailureLog(profiles: profiles)
        log.record(schedule(multi: true, excluded: ["gamma"]), "first failure")
        log.record(schedule(multi: true, excluded: ["gamma"]), "second failure")
        log.finish()

        XCTAssertEqual(RunHistoryService.list(profile: "alpha").count, 1)
        XCTAssertEqual(RunHistoryService.list(profile: "beta").count, 1)
        XCTAssertTrue(RunHistoryService.list(profile: "gamma").isEmpty)
        let text = try logText("beta")
        XCTAssertTrue(text.contains("[error] tick: first failure"), "\(text)")
        XCTAssertTrue(text.contains("[error] tick: second failure"), "\(text)")
    }

    func testAWakeWithNoFailureWritesNothing() {
        TickFailureLog(profiles: []).finish()
        XCTAssertTrue(RunHistoryService.list(profile: "alpha").isEmpty)
    }
}
