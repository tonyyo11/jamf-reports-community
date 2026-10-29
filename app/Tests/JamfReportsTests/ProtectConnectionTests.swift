import XCTest
@testable import JamfReports

/// Data Sources > Additional Products: the Protect state (config.yaml against jamf-cli's
/// profile list) and the Disconnect write, which re-pins `protect.profile` on this Mac.
final class ProtectConnectionTests: XCTestCase {

    private let fileManager = FileManager.default
    private let profile = "disconnectprofile"
    private var root: URL!
    private var workspace: URL!
    private var appSupport: URL!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-protect-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent(profile, isDirectory: true)
        appSupport = root.appendingPathComponent(".app-support", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
    }

    private var configURL: URL { workspace.appendingPathComponent("config.yaml") }

    private func writeConfig(_ text: String) throws {
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: State

    func testNothingConfiguredIsNotConnected() {
        XCTAssertEqual(ProtectConnection.state(configured: nil, cliProfiles: ["a"]), .notConnected)
    }

    func testAProfileJamfCLIListsIsConnected() {
        XCTAssertEqual(
            ProtectConnection.state(configured: "protect", cliProfiles: ["main", "protect"]),
            .connected(profile: "protect"))
    }

    func testAProfileJamfCLIDoesNotListIsMissing() {
        XCTAssertEqual(
            ProtectConnection.state(configured: "protect", cliProfiles: ["main"]),
            .profileMissing(profile: "protect"))
    }

    func testAnUnreadOrEmptyProfileListIsNotTakenAsMissing() {
        XCTAssertEqual(ProtectConnection.state(configured: "protect", cliProfiles: nil),
                       .connected(profile: "protect"))
        XCTAssertEqual(ProtectConnection.state(configured: "protect", cliProfiles: []),
                       .connected(profile: "protect"))
    }

    // MARK: Words

    func testTheCredentialsNoteSeparatesProtectFromTheJamfAccountIntegration() {
        XCTAssertEqual(
            ProtectConnection.credentialsNote,
            "Jamf Protect uses its own API client from Jamf Protect, not your Jamf Account "
                + "integration.")
    }

    func testTheDisconnectNoteNamesTheCommandThatRemovesTheProfile() {
        let note = ProtectConnection.disconnectedNote(profile: "my protect", profileMissing: false)
        XCTAssertTrue(note.contains("jamf-cli config remove-profile 'my protect'"), note)
        let gone = ProtectConnection.disconnectedNote(profile: "x", profileMissing: true)
        XCTAssertFalse(gone.contains("remove-profile"))
    }

    // MARK: Disconnect

    func testDisconnectTurnsProtectOffRemovesTheProfileAndKeepsTheRest() throws {
        try writeConfig("""
        jamf_cli:
          profile: "\(profile)"
        protect:
          enabled: true
          profile: "protect-login"
          extra: keep-me
        thresholds:
          stale_device_days: 21
        """)
        try ProtectConnection.disconnect(workspace: profile, appSupport: appSupport)

        let config = try ConfigLoader.load(from: configURL)
        XCTAssertEqual(config.protect?.enabled, false)
        XCTAssertNil(config.protect?.profile)
        XCTAssertNil(EnvironmentProfiles.read(configURL: configURL, workspace: profile).protect)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("extra: keep-me"))
        XCTAssertTrue(text.contains("stale_device_days: 21"))
        XCTAssertFalse(text.contains("protect-login"))
    }

    func testDisconnectKeepsACommentByCopyingTheFileFirst() throws {
        try writeConfig("""
        protect:
          # set up by the 2026 rollout
          enabled: true
          profile: "protect-login"
        """)
        let report = try ProtectConnection.disconnect(workspace: profile, appSupport: appSupport)
        let backup = try XCTUnwrap(report.backupName)
        let copy = try String(
            contentsOf: workspace.appendingPathComponent(backup), encoding: .utf8)
        XCTAssertTrue(copy.contains("# set up by the 2026 rollout"))
    }

    func testDisconnectRepinsTheProfileSoTheNextRunSeesNoDrift() throws {
        try writeConfig("""
        shared_workspace:
          enabled: true
        protect:
          enabled: true
          profile: "protect-login"
        """)
        _ = SharedConfigPin.check(profile: profile, appSupport: appSupport)
        XCTAssertEqual(SharedConfigPin.load(profile: profile, appSupport: appSupport)?
            .protectProfile, "protect-login")

        try ProtectConnection.disconnect(workspace: profile, appSupport: appSupport)

        XCTAssertEqual(SharedConfigPin.load(profile: profile, appSupport: appSupport)?
            .protectProfile, "")
        XCTAssertFalse(SharedConfigPin.check(profile: profile, appSupport: appSupport)
            .drifts.contains { $0.key == .protectProfile })
    }

    func testDisconnectWithNoProtectBlockWritesNothing() throws {
        let original = "jamf_cli:\n  profile: \"\(profile)\"\n"
        try writeConfig(original)
        try ProtectConnection.disconnect(workspace: profile, appSupport: appSupport)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }
}
