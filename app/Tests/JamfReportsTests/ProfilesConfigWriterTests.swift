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
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("support"), withIntermediateDirectories: true)
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

    /// D17: only the first-write seed writes the MDM slot; the writer refuses set and clear.
    func testTheMDMSlotsAreNeverWritten() throws {
        try write("profiles:\n  jamf_pro: \(ws)\n")
        for (slot, name) in [(ProfilesConfigWriter.Slot.jamfPro, ws as String?),
                             (.jamfPro, "other"), (.jamfPro, nil), (.jamfSchool, ws)] {
            XCTAssertThrowsError(try save(slot, name)) {
                XCTAssertEqual($0 as? ProfilesConfigWriter.WriteError, .mdmIsTheWorkspace)
            }
        }
        XCTAssertEqual(try readBack(), "profiles:\n  jamf_pro: \(ws)\n")
    }

    func testASchoolPrimarySeedHasJamfSchoolAndNoJamfPro() throws {
        try write("school_cli:\n  enabled: true\n")
        try save(.platform, "\(ws)-API")
        let text = try readBack()
        XCTAssertTrue(text.contains("jamf_school: \(ws)"))
        XCTAssertFalse(text.contains("jamf_pro"))
    }

    func testAnUndecodableConfigIsRefusedAndUnchanged() throws {
        let bad = "profiles: [unclosed\nthresholds:\n  stale_device_days: {\n"
        try write(bad)
        XCTAssertThrowsError(try save(.platform, "\(ws)-API")) {
            guard case .configDoesNotLoad = $0 as? ProfilesConfigWriter.WriteError else {
                return XCTFail("wrong error \($0)")
            }
        }
        XCTAssertEqual(try readBack(), bad)
    }

    func testProtectOnWithNoProfileIsRefusedAndUnchanged() throws {
        let text = "protect:\n  enabled: true\n"
        try write(text)
        XCTAssertThrowsError(try save(.platform, "\(ws)-API")) {
            XCTAssertEqual($0 as? ProfilesConfigWriter.WriteError, .protectHasNoProfile)
        }
        XCTAssertEqual(try readBack(), text)
    }

    /// The pin takes the written token: on a shared workspace the slot is confirmed.
    func testAWrittenPlatformSlotIsConfirmedOnASharedWorkspace() throws {
        try write("shared_workspace:\n  enabled: true\n")
        SharedConfigPin.checkpoint(profile: ws, appSupport: support, onLine: nil)
        try save(.platform, "\(ws)-API")
        XCTAssertTrue(SharedConfigPin.platformAllowed(profile: ws, appSupport: support))
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
