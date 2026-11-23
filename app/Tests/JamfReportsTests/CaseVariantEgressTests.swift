import XCTest
@testable import JamfReports

/// A case variant (`Prod` beside the folder `prod/`) has no workspace of its own: the health
/// reader names the refusal, and no overdue digest, heartbeat or schedule reaches the other
/// spelling's webhook or stamps its folder.
final class CaseVariantEgressTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-variant-egress-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("prod", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ("notify:\n  enabled: true\n  provider: teams\n  heartbeat: true\n"
            + "  url: \"\(WebhookCapture.webhookURL)\"\n")
            .write(to: folder.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        WebhookCapture.start()
    }

    override func tearDownWithError() throws {
        WebhookCapture.stop()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    func testAVariantScheduleReadsAsFailingWithTheReasonNotOverdue() throws {
        let schedule = Schedule(
            name: "nightly", profile: "Prod", schedule: "Daily 06:00", cadence: "custom",
            mode: .jamfCLIOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.Prod.n")
        let inputs = LaunchAgentService.healthInputs(
            schedules: [schedule], statusProfile: nil, now: .testNoon)
        let reason = try XCTUnwrap(inputs.first?.refusal)
        XCTAssertTrue(reason.contains("'prod'"), reason)
        let issues = AutomationHealth.evaluate(inputs: inputs, now: .testNoon)
        XCTAssertEqual(issues.map(\.kind), [.failing])
        XCTAssertFalse(issues.contains { $0.kind == .overdue })
    }

    func testNotifyTargetsLeavesAVariantOut() {
        XCTAssertTrue(notifyTargets(in: ["Prod"]) { _ in false }.isEmpty)
        XCTAssertEqual(notifyTargets(in: ["prod"]) { _ in false }.map(\.profile), ["prod"])
    }

    func testNoHeartbeatGoesOutForAVariant() async throws {
        let stamps = root.appendingPathComponent("beats")
        await ScheduledRunSignals.notifyHeartbeats(
            profiles: ["Prod"], stateRoot: stamps, now: .testNoon)
        XCTAssertTrue(WebhookCapture.posted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stamps.path))
    }

    func testSchedulesAddRefusesAVariantBeforeReadingItsConfig() {
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "nightly", profile: "Prod", allProfiles: false, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:00", tiers: nil, disabled: false)
        ) { error in
            XCTAssertTrue("\(error)".contains("'prod'"), "\(error)")
        }
    }
}
