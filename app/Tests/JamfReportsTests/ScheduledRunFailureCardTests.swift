import XCTest
@testable import JamfReports

/// Failures a scheduled run ends with before any collect still page the notify webhook.
final class ScheduledRunFailureCardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var savedProbe: (@Sendable () -> String?)!
    private let profile = "card"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-card-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        savedProbe = JamfCLIInstaller.installedVersionProbe
        WebhookCapture.start()
        try writeConfig(
            "notify:\n  enabled: true\n  provider: teams\n  url: \"\(WebhookCapture.webhookURL)\"\n")
    }

    override func tearDownWithError() throws {
        JamfCLIInstaller.installedVersionProbe = savedProbe
        WebhookCapture.stop()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func writeConfig(_ yaml: String) throws {
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    private func schedule(_ mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: "card", profile: profile, schedule: "manual", cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.card.\(mode.rawValue)")
    }

    func testAJamfCLIBelowTheFloorPostsAFailureCard() async {
        JamfCLIInstaller.installedVersionProbe = { "1.28.0" }
        let outcome = await runSchedule(schedule(.snapshotOnly), verbose: false)
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(WebhookCapture.posted.count, 1)
        XCTAssertTrue(WebhookCapture.posted.first?.contains("Failed") == true)
    }

    // MARK: - Refused runs

    private func refusedSchedule() -> Schedule {
        Schedule(
            name: "refused", profile: profile, schedule: "manual", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.r\(UUID().uuidString.prefix(8))")
    }

    func testARefusedRunPostsOneCardADayAndWritesNothingInTheWorkspace() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let schedule = refusedSchedule()
        for _ in 0..<3 {
            let outcome = await runSchedule(schedule, verbose: false)
            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertTrue(outcome.endsRetries)
        }
        XCTAssertEqual(WebhookCapture.posted.count, 1, "once a day, not once a wake")
        XCTAssertTrue(WebhookCapture.posted.first?.contains("Failed") == true)
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("automation").path))
    }

    // MARK: - One card a day per failure

    private func loadConfig() throws -> ReportConfig {
        try ConfigLoader.load(from: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml"))
    }

    private func post(
        _ key: String, _ reason: String, state: URL, at day: Date, config: ReportConfig
    ) async {
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: config, profile: profile, mode: .snapshotOnly, errorDescription: reason,
            recorder: nil, scheduleKey: key, stateRoot: state, now: day)
    }

    func testTheSameFailurePostsOnceADayPerScheduleAndAgainTheNextDay() async throws {
        let config = try loadConfig()
        let state = root.appendingPathComponent("card-state")
        let today = Date.testNoon
        let tomorrow = today.addingTimeInterval(86_400)
        for (key, day) in [("a", today), ("a", today), ("b", today), ("a", tomorrow)] {
            await post(key, "refused", state: state, at: day, config: config)
        }
        XCTAssertEqual(WebhookCapture.posted.count, 3)
    }

    func testADifferentFailureTheSameDayPostsAndOnlyNumbersDoNotCount() async throws {
        let config = try loadConfig()
        let state = root.appendingPathComponent("card-state")
        let now = Date.testNoon
        await post("a", "collect timed out after 60 s", state: state, at: now, config: config)
        await post("a", "collect timed out after 61 s", state: state, at: now, config: config)
        XCTAssertEqual(WebhookCapture.posted.count, 1)
        await post("a", "authentication rejected", state: state, at: now, config: config)
        XCTAssertEqual(WebhookCapture.posted.count, 2)
    }

    func testAFailedSendStampsNothingSoTheNextPassRetries() async throws {
        try writeConfig("notify:\n  enabled: true\n  provider: teams\n"
            + "  url: \"https://127.0.0.1:1/hook\"\n")
        let broken = try loadConfig()
        try writeConfig("notify:\n  enabled: true\n  provider: teams\n"
            + "  url: \"\(WebhookCapture.webhookURL)\"\n")
        let working = try loadConfig()
        let state = root.appendingPathComponent("card-state")
        let now = Date.testNoon
        await post("a", "refused", state: state, at: now, config: broken)
        XCTAssertTrue(WebhookCapture.posted.isEmpty)
        await post("a", "refused", state: state, at: now, config: working)
        XCTAssertEqual(WebhookCapture.posted.count, 1)
    }

    /// A webhook that answers non-2xx names the status in the run record, not just "failed".
    func testARejectedSendNamesTheStatusInTheRunRecord() async throws {
        WebhookCapture.respond(with: 503)
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let recorder = try XCTUnwrap(ScheduledRunRecorder(
            workspace: workspace,
            label: "com.github.tonyyo11.jamf-reports-community.card.snapshot-only"))
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: try loadConfig(), profile: profile, mode: .snapshotOnly,
            errorDescription: "refused", recorder: recorder, scheduleKey: "a",
            stateRoot: root.appendingPathComponent("card-state"))
        recorder.finish(exitCode: 1)
        let text = try String(contentsOf: recorder.logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("failure webhook notification failed for '\(profile)': HTTP 503"),
                      text)
        XCTAssertFalse(text.contains(WebhookCapture.captureHost), "the URL is never written")
    }
}
