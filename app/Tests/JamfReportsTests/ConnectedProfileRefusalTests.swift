import XCTest

@testable import JamfReports

final class ConnectedProfileRefusalTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("jrc-conn-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fm.removeItem(at: root)
    }

    private func workspace(_ name: String, _ yaml: String) throws {
        let dir = root.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    func testMergedAwayProfileIsRefusedAndNothingIsCreated() throws {
        try workspace("OnPrem", "profiles:\n  jamf_pro: \"OnPrem\"\n  platform: \"Cloud\"\n")
        let refusal = try XCTUnwrap(ProfileService.connectedProfileRefusal(of: "Cloud", under: root))
        XCTAssertTrue(refusal.contains("environment 'OnPrem'"), refusal)
        XCTAssertNil(ProfileService.connectedProfileRefusal(of: "OnPrem", under: root))
        XCTAssertNil(ProfileService.connectedProfileRefusal(of: "Other", under: root))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Cloud").path))
    }

    func testProfileWithItsOwnWorkspaceIsNotRefused() throws {
        try workspace("OnPrem", "profiles:\n  jamf_pro: \"OnPrem\"\n  platform: \"Cloud\"\n")
        try workspace("Cloud", "jamf_cli:\n  profile: \"Cloud\"\n")
        XCTAssertNil(ProfileService.connectedProfileRefusal(of: "Cloud", under: root))
    }

    func testScheduledRunSkipsAndCreatesNoFolder() async throws {
        try workspace("OnPrem", "profiles:\n  jamf_pro: \"OnPrem\"\n  platform: \"Cloud\"\n")
        let schedule = Schedule(
            name: "t", profile: "Cloud", schedule: "manual", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "t.cloud", multiTarget: nil, tiers: nil,
            excludedProfiles: nil)
        let code = await runSchedule(schedule, verbose: false).exitCode
        XCTAssertEqual(code, 0)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Cloud").path))
    }
}
