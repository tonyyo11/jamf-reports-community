import XCTest
@testable import JamfReports

/// Paths that only generate have no product check, so the folder rule refuses a case variant
/// there too: the CLI before any command runs, a scheduled run before it writes a record, a
/// report or an attention item into the other spelling's folder.
final class CaseVariantGenerateGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-variant-gen-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("prod", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "jamf_cli:\n  profile: prod\n".write(
            to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    func testTheCLIRefusesACaseVariantBeforeAnyCommandRuns() throws {
        let refusal = try XCTUnwrap(CLIRun.profileRefusal("Prod"))
        XCTAssertTrue(refusal.contains("'prod'"), refusal)
        XCTAssertNil(CLIRun.profileRefusal("prod"))
        XCTAssertEqual(CLIRun.profileRefusal("bad\nname"), "invalid profile 'badname'")
    }

    func testAScheduledReportRunOfACaseVariantWritesNothingIntoTheFolder() async throws {
        let schedule = Schedule(
            name: "reports", profile: "Prod", schedule: "manual", cadence: "custom",
            mode: .jamfCLIOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: nil, multiTarget: nil, tiers: nil,
            excludedProfiles: nil)
        let outcome = await runSchedule(schedule, verbose: false)
        XCTAssertEqual(outcome.exitCode, 1)
        let folder = root.appendingPathComponent("prod")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path),
                       ["config.yaml"])
    }
}
