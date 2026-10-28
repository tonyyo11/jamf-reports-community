import XCTest
@testable import JamfReports

/// `notify.heartbeat`: the decode, the writer, the card facts and the tick's once-a-day send.
final class NotifyHeartbeatTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "beat"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        WebhookCapture.start()
    }

    override func tearDownWithError() throws {
        WebhookCapture.stop()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func configURL() throws -> URL {
        try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml")
    }

    private func writeNotify(_ extra: String = "", enabled: Bool = true) throws {
        try ("notify:\n  enabled: \(enabled)\n  provider: teams\n"
            + "  url: \"\(WebhookCapture.webhookURL)\"\n\(extra)")
            .write(to: configURL(), atomically: true, encoding: .utf8)
    }

    private func beat(on day: Date, excluding: Set<String> = []) async {
        await ScheduledRunSignals.notifyHeartbeats(
            profiles: [profile], excluding: excluding,
            stateRoot: root.appendingPathComponent("beats"), now: day)
    }

    // MARK: - Decode and write

    func testHeartbeatIsOffWhenAbsentAndAWrongTypeDoesNotFailTheDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertFalse(try decoder.decode(
            NotifyConfig.self, from: Data(#"{"enabled":true}"#.utf8)).sendsHeartbeat)
        let mistyped = try decoder.decode(
            NotifyConfig.self, from: Data(#"{"enabled":true,"heartbeat":"yes"}"#.utf8))
        XCTAssertTrue(mistyped.isEnabled)
        XCTAssertFalse(mistyped.sendsHeartbeat)
        XCTAssertTrue(try decoder.decode(
            NotifyConfig.self, from: Data(#"{"heartbeat":true}"#.utf8)).sendsHeartbeat)
    }

    func testTheWriterRoundTripsTheHeartbeatAndWritesFalseOnlyWhereTheFileSetsIt() throws {
        func save(_ heartbeat: Bool?) throws {
            try NotifyConfigWriter.save(
                enabled: true, provider: "teams", url: "https://hooks.example.com/a",
                detail: "full", heartbeat: heartbeat, profile: profile)
        }
        func text() throws -> String { try String(contentsOf: configURL(), encoding: .utf8) }
        try save(false)
        XCTAssertFalse(try text().contains("heartbeat"))
        try save(true)
        XCTAssertTrue(NotifyConfigLoader.load(profile: profile).sendsHeartbeat)
        try save(nil)
        XCTAssertTrue(NotifyConfigLoader.load(profile: profile).sendsHeartbeat, "nil keeps it")
        try save(false)
        XCTAssertTrue(try text().contains("heartbeat: false"))
        XCTAssertFalse(NotifyConfigLoader.load(profile: profile).sendsHeartbeat)
    }

    func testTheKeyIsKnownToTheSchemaAndToTheEditedKeys() {
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["notify", "heartbeat"]))
        XCTAssertTrue(ConfigSchema.unknownKeys(in: ["notify": ["heartbeat": true]]).isEmpty)
    }

    // MARK: - Facts and payloads

    func testFullFactsNameTheNewestSummaryAndMinimalDropsIt() {
        let full = heartbeatFacts(detail: .full, profile: "p", newestSummaryDay: "2026-10-18")
        XCTAssertEqual(full.map(\.label), ["Profile", "Status", "Newest summary"])
        XCTAssertEqual(full.last?.value, "2026-10-18")
        XCTAssertEqual(heartbeatFacts(detail: .full, profile: "p", newestSummaryDay: nil).last?.value,
                       "none")
        XCTAssertEqual(
            heartbeatFacts(detail: .minimal, profile: "p", newestSummaryDay: "2026-10-18")
                .map(\.label), ["Profile", "Status"])
    }

    func testBothProvidersEscapeTheProfileInTheCard() throws {
        let facts = heartbeatFacts(detail: .full, profile: "<!channel> *x*", newestSummaryDay: nil)
        let teams = try XCTUnwrap(String(data: try XCTUnwrap(WebhookNotifier.payload(
            provider: .teams, title: "t", facts: facts)), encoding: .utf8))
        XCTAssertTrue(teams.contains("&lt;!channel&gt; \\\\*x\\\\*"), teams)
        let slack = try XCTUnwrap(String(data: try XCTUnwrap(WebhookNotifier.payload(
            provider: .slack, title: "t", facts: facts)), encoding: .utf8))
        XCTAssertFalse(slack.contains("<!channel>"), slack)
    }

    // MARK: - The tick's send

    func testOneCardADayPerWorkspaceAndAgainTheNextDay() async throws {
        try writeNotify("  heartbeat: true\n")
        let today = Date.testNoon
        for _ in 0..<3 { await beat(on: today) }
        XCTAssertEqual(WebhookCapture.posted.count, 1)
        XCTAssertTrue(WebhookCapture.posted[0].contains("Background item ran"))
        await beat(on: today.addingTimeInterval(86_400))
        XCTAssertEqual(WebhookCapture.posted.count, 2)
    }

    /// The GUI's and `schedules run`'s Run now go through `--tick --now`: no heartbeat from
    /// those, one from the background item's own wake.
    func testARunNowTickPostsNoHeartbeat() async throws {
        try writeNotify("  heartbeat: true\n")
        let lock = TickLock(url: root.appendingPathComponent(".tick.lock"))
        let label = "\(LaunchAgentWriter.labelPrefix).\(profile).none"
        _ = await runTick(
            arguments: ["--tick", "--now", label], environment: TickEnvironment(lock: lock))
        XCTAssertTrue(WebhookCapture.posted.isEmpty, "\(WebhookCapture.posted)")
        _ = await runTick(arguments: ["--tick"], environment: TickEnvironment(lock: lock))
        XCTAssertEqual(WebhookCapture.posted.count, 1)
    }

    func testNothingIsSentUnlessHeartbeatAndNotifyAreOn() async throws {
        try writeNotify()
        await beat(on: .testNoon)
        try writeNotify("  heartbeat: true\n", enabled: false)
        await beat(on: .testNoon)
        try writeNotify("  heartbeat: true\n")
        await beat(on: .testNoon, excluding: [profile])
        XCTAssertTrue(WebhookCapture.posted.isEmpty)
    }

    func testTheCardCarriesTheNewestSummaryDayUnlessDetailIsMinimal() async throws {
        let summaries = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        for day in ["2026-10-01", "2026-10-17"] {
            try Data("{}".utf8).write(to: summaries.appendingPathComponent("summary_\(day).json"))
        }
        XCTAssertEqual(SummaryJSONParser.newestSummaryDay(profile: profile), "2026-10-17")
        try writeNotify("  heartbeat: true\n")
        await beat(on: .testNoon)
        XCTAssertTrue(WebhookCapture.posted.first?.contains("2026-10-17") == true)
        try writeNotify("  heartbeat: true\n  detail: minimal\n")
        await beat(on: .testNoon.addingTimeInterval(86_400))
        XCTAssertEqual(WebhookCapture.posted.count, 2)
        XCTAssertFalse(WebhookCapture.posted[1].contains("2026-10-17"))
    }
}
