import Foundation
import XCTest
@testable import JamfReports

/// Metric alerts judge the newest summary against the run's start day. A collect that crosses
/// midnight dates its summary by its start, so the alerts must take the start too, or the
/// summary reads as "not today" and the card is skipped.
final class MetricAlertRunDayTests: XCTestCase {
    private let profile = "alertday"
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var workspace: URL!
    nonisolated(unsafe) private var config: ReportConfig!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alert-day-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile).appendingPathComponent("automation"),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let configURL = workspace.appendingPathComponent("config.yaml")
        try ("notify:\n  enabled: true\n  provider: teams\n"
            + "  url: \"\(WebhookCapture.webhookURL)\"\n"
            + "alerts:\n  enabled: true\n  rules:\n"
            + "    - {metric: \"total_devices\", when: \"above\", threshold: 0}\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        config = try ConfigLoader.load(from: configURL)
        let summaries = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        let startDay = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        try #"{"date":"\#(startDay)","totalDevices":5,"source":"jamf-cli"}"#.write(
            to: summaries.appendingPathComponent("summary_\(startDay).json"),
            atomically: true, encoding: .utf8)
        WebhookCapture.start()
    }

    override func tearDownWithError() throws {
        WebhookCapture.stop()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private var afterMidnight: Date {
        Calendar.current.date(byAdding: .hour, value: 13, to: .testNoon) ?? .testNoon
    }

    func testTheRunStartDaysSummaryIsAlertedOnAfterTheClockCrossesMidnight() async {
        // The summary is dated the start day; only the run's start says so.
        await ScheduledRunSignals.notifyMetricAlerts(
            config: config, profile: profile, workspace: workspace, recorder: nil,
            now: .testNoon)
        XCTAssertEqual(WebhookCapture.posted.count, 1)
    }

    func testTheNextDaysClockSkipsThatSummary() async {
        await ScheduledRunSignals.notifyMetricAlerts(
            config: config, profile: profile, workspace: workspace, recorder: nil,
            now: afterMidnight)
        XCTAssertTrue(WebhookCapture.posted.isEmpty)
    }

    func testACLIRunAlertsOnItsStartDay() async {
        var signals = CLIRunSignals(
            profile: profile, workspace: workspace, config: config,
            mode: CLIRunSignals.mode(for: .collect), kind: .collect,
            recorder: nil, honesty: CollectHonestyWatcher())
        signals.startedAt = .testNoon
        await signals.finishSuccess()
        XCTAssertEqual(WebhookCapture.posted.filter { $0.contains("Metric alert") }.count, 1)
    }
}
