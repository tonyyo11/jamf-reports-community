import XCTest
@testable import JamfReports

final class ProfilesConfigWriterTests: XCTestCase {
    private var root: URL!
    private let ws = "profileswriter"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-ProfilesWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var configURL: URL {
        root.appendingPathComponent(ws).appendingPathComponent("config.yaml")
    }
    private var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    private func write(_ text: String) throws {
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }
    private func readBack() throws -> String { try String(contentsOf: configURL, encoding: .utf8) }
    private func environment() throws -> EnvironmentProfiles {
        EnvironmentProfiles.resolve(
            config: try ConfigLoader.load(from: configURL), workspace: ws)
    }
    private func save(_ slot: ProfilesConfigWriter.Slot, _ name: String?) throws {
        try ProfilesConfigWriter.save(slot, to: name, workspace: ws, appSupport: support)
    }

    /// The first write turns the derived slots into the block and leaves the old keys (D14).
    func testTheFirstWriteKeepsTheDerivedSlotsAndTheOldKeys() throws {
        try write("""
            # team note
            jamf_cli:
              data_dir: jamf-cli-data
            protect:
              enabled: true
              profile: "\(ws)-Protect"
            """)
        try save(.platform, "\(ws)-API")
        let after = try environment()
        XCTAssertEqual(after.source, .profilesBlock)
        XCTAssertEqual(after.jamfPro, ws)
        XCTAssertEqual(after.platform, "\(ws)-API")
        XCTAssertEqual(after.protect, "\(ws)-Protect")
        let text = try readBack()
        XCTAssertTrue(text.contains("profile: \"\(ws)-Protect\""), "old protect.profile kept")
        XCTAssertTrue(text.contains("# team note"), "comment outside the block kept")
    }

    func testClearingASlotRemovesOnlyThatSlot() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n  protect: \(ws)-Protect\n"
            + "  platform: \(ws)-API\n")
        try save(.protect, nil)
        let after = try environment()
        XCTAssertNil(after.protect)
        XCTAssertEqual(after.platform, "\(ws)-API")
        XCTAssertEqual(after.jamfPro, ws)
    }

    /// D17: the MDM slot is always the workspace; the writer never names another profile there.
    func testTheMDMSlotCannotNameAnotherProfile() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n")
        XCTAssertThrowsError(try save(.jamfPro, "other")) {
            XCTAssertEqual($0 as? ProfilesConfigWriter.WriteError, .mdmIsTheWorkspace)
        }
        XCTAssertThrowsError(try save(.jamfPro, nil))
    }

    func testAnUnusableSlotNameIsRefused() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n")
        XCTAssertThrowsError(try save(.platform, "bad\u{7}name"))
        XCTAssertFalse(try readBack().contains("bad"))
    }

    /// D14: a scoped save of another block on a file without `profiles:` keeps the old keys.
    func testTheBackupsProtectSwitchKeepsProtectProfile() throws {
        try write("protect:\n  enabled: true\n  profile: \"\(ws)-Protect\"\n")
        try BackupChoiceConfigWriter.save(.protect, on: true, profile: ws)
        XCTAssertEqual(try environment().protect, "\(ws)-Protect")
    }

    func testTheWriterKeysAreKnownToTheConfigScreen() {
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["profiles", "platform"]))
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["profiles", "protect"]))
    }
}
