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

/// A server-credential alert is sent once per (rule, credential, expiry, state), however many
/// days the condition lasts, and again when the credential is renewed or expires.
final class MetricAlertCredentialRunTests: XCTestCase {
    private let profile = "credalert"
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cred-alert-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile).appendingPathComponent("automation"),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(
            at: try WorkspacePaths.summariesDir(for: profile), withIntermediateDirectories: true)
        WebhookCapture.start()
    }

    override func tearDownWithError() throws {
        WebhookCapture.stop()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func config(detail: String = "full", rules: [String] = [
        "{metric: \"server_credential_days_left\", when: \"below\", threshold: 45}",
    ]) throws -> ReportConfig {
        let url = workspace.appendingPathComponent("config.yaml")
        try ("notify:\n  enabled: true\n  provider: teams\n  detail: \(detail)\n"
            + "  url: \"\(WebhookCapture.webhookURL)\"\n"
            + "alerts:\n  enabled: true\n  rules:\n"
            + rules.map { "    - \($0)\n" }.joined())
            .write(to: url, atomically: true, encoding: .utf8)
        return try ConfigLoader.load(from: url)
    }

    /// Writes the summary for `day` carrying one credential that expires `daysAhead` days after
    /// `Date.testNoon`.
    private func writeSummary(day: Date, expiries: [String: Double]) throws {
        let name = SummaryJSONParser.dateFormatter.string(from: day)
        let entries = expiries.map { key, days in
            #""\#(key)":{"expires":"\#(ISO8601Time.string(Date.testNoon.addingTimeInterval(days * 86_400)))","asOf":"\#(name)"}"#
        }.joined(separator: ",")
        try #"{"date":"\#(name)","totalDevices":5,"source":"jamf-cli","serverCredentialExpiries":{\#(entries)}}"#
            .write(to: try WorkspacePaths.summariesDir(for: profile)
                .appendingPathComponent("summary_\(name).json"), atomically: true, encoding: .utf8)
    }

    private func run(_ config: ReportConfig, on day: Date) async {
        await ScheduledRunSignals.notifyMetricAlerts(
            config: config, profile: profile, workspace: workspace, recorder: nil, now: day)
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: .testNoon) ?? .testNoon
    }

    func testACredentialPostsOnceThenStaysQuietOnLaterDays() async throws {
        let config = try config()
        try writeSummary(day: day(0), expiries: ["ca": 40])
        await run(config, on: day(0))
        await run(config, on: day(0))
        XCTAssertEqual(WebhookCapture.posted.count, 1)
        XCTAssertTrue(WebhookCapture.posted[0].contains("Built-in CA expires in 40 days"))
        try writeSummary(day: day(1), expiries: ["ca": 40])
        await run(config, on: day(1))
        XCTAssertEqual(WebhookCapture.posted.count, 1, "the next day does not repeat it")
    }

    func testExpiringThenExpiredPostsTwiceAndAnUnrenewedExpiryNeverAThirdTime() async throws {
        let config = try config()
        try writeSummary(day: day(0), expiries: ["ca": 3])
        await run(config, on: day(0))
        try writeSummary(day: day(4), expiries: ["ca": 3])
        await run(config, on: day(4))
        XCTAssertEqual(WebhookCapture.posted.count, 2)
        XCTAssertTrue(WebhookCapture.posted[1].contains("Built-in CA expired 1 day ago"))
        try writeSummary(day: day(9), expiries: ["ca": 3])
        await run(config, on: day(9))
        XCTAssertEqual(WebhookCapture.posted.count, 2)
    }

    func testTwoCredentialsCrossingOnDifferentDaysEachPostOnce() async throws {
        let config = try config()
        try writeSummary(day: day(0), expiries: ["ca": 40, "ade:1": 90])
        await run(config, on: day(0))
        try writeSummary(day: day(50), expiries: ["ca": 40, "ade:1": 90])
        await run(config, on: day(50))
        XCTAssertEqual(WebhookCapture.posted.count, 2)
        XCTAssertTrue(WebhookCapture.posted[1].contains("ADE token expires in"))
        XCTAssertFalse(WebhookCapture.posted[1].contains("ade:1"), "no ID on the card")
    }

    func testARenewedCredentialReArms() async throws {
        let config = try config()
        try writeSummary(day: day(0), expiries: ["ca": 40])
        await run(config, on: day(0))
        try writeSummary(day: day(1), expiries: ["ca": 406])
        await run(config, on: day(1))
        XCTAssertEqual(WebhookCapture.posted.count, 1, "a renewed credential is out of range")
        try writeSummary(day: day(400), expiries: ["ca": 406])
        await run(config, on: day(400))
        XCTAssertEqual(WebhookCapture.posted.count, 2, "the new expiry crossing is a new key")
    }

    func testAFailedSendLeavesTheCredentialPending() async throws {
        let config = try config()
        try writeSummary(day: day(0), expiries: ["ca": 40])
        WebhookCapture.respond(with: 500)
        await run(config, on: day(0))
        WebhookCapture.respond(with: 200)
        await run(config, on: day(0))
        XCTAssertEqual(WebhookCapture.posted.count, 2, "the failed send was not recorded")
        await run(config, on: day(0))
        XCTAssertEqual(WebhookCapture.posted.count, 2)
    }

    func testMinimalDetailNamesNeitherTheCredentialNorTheExpiry() async throws {
        let config = try config(detail: "minimal")
        try writeSummary(day: day(0), expiries: ["ca": 40])
        await run(config, on: day(0))
        let body = try XCTUnwrap(WebhookCapture.posted.first)
        XCTAssertTrue(body.contains("A server credential is expiring"), body)
        XCTAssertFalse(body.contains("Built-in CA"), body)
        XCTAssertFalse(body.contains("rule"), "no rule count for credential hits: \(body)")
    }
}
