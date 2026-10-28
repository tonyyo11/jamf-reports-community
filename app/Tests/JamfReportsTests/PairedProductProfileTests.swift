import Foundation
import XCTest
@testable import JamfReports

/// Connecting Jamf Protect makes a second jamf-cli profile named in the workspace's
/// `protect.profile`, and earlier builds did the same for a School login in `school_cli.profile`.
/// Those profiles are connections, not workspaces (#271, #278).
final class PairedProductProfileTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("paired-protect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace(_ name: String, config: String) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.yaml"))
    }

    private func profile(_ name: String) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: "", schedules: 0, status: .idle)
    }

    private func names(_ profiles: [JamfCLIProfile]) -> [String] { profiles.map(\.name) }

    func testProfileNamedOnlyAsProtectConnectionIsNotListed() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("protect")], under: root)
        XCTAssertEqual(names(listed), ["prod"])
    }

    func testProtectProfileWithItsOwnWorkspaceStaysListed() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        try workspace("protect", config: "jamf_cli: {}\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("protect")], under: root)
        XCTAssertEqual(names(listed), ["prod", "protect"])
    }

    func testActiveProfileStaysListed() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("protect")], under: root, keeping: ["protect"])
        XCTAssertEqual(names(listed), ["prod", "protect"])
    }

    func testDisabledOrBlankProtectBlockHidesNothing() throws {
        try workspace("a", config: "protect:\n  enabled: false\n  profile: p1\n")
        try workspace("b", config: "protect:\n  enabled: true\n  profile: \"\"\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("a"), profile("b"), profile("p1")], under: root)
        XCTAssertEqual(names(listed), ["a", "b", "p1"])
    }

    func testProfileNamedOnlyAsAnotherWorkspacesSchoolLoginIsNotListed() throws {
        try workspace("prod", config: "school_cli:\n  enabled: true\n  profile: school\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("school")], under: root)
        XCTAssertEqual(names(listed), ["prod"])
    }

    func testSchoolWorkspaceNamingItsOwnProfileIsListedAndHidesNothing() throws {
        try workspace("edu", config: "school_cli:\n  enabled: true\n  profile: edu\n")
        try workspace("blank", config: "school_cli:\n  enabled: true\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("edu"), profile("blank"), profile("other")], under: root)
        XCTAssertEqual(names(listed), ["edu", "blank", "other"])
    }

    func testSchoolLoginWithItsOwnWorkspaceOrActiveStaysListed() throws {
        try workspace("prod", config: "school_cli:\n  enabled: true\n  profile: school\n")
        try workspace("school", config: "school_cli:\n  enabled: true\n  profile: school\n")
        XCTAssertEqual(names(ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("school")], under: root)), ["prod", "school"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("school"))
        XCTAssertEqual(names(ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("school")], under: root, keeping: ["school"])),
            ["prod", "school"])
    }

    func testPairedProfileIsNotARunTarget() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        let listed = ProfileService.droppingPairedProductProfiles(
            [profile("prod"), profile("protect")], under: root)
        XCTAssertEqual(names(ProfileService.runnableProfiles(listed, excluding: [])), ["prod"])
    }

    func testEnvironmentReadsEnabledBlocksWithAProfile() throws {
        try workspace("prod", config: """
            protect:
              enabled: true
              profile: " protect "
            school_cli:
              enabled: false
              profile: school
            """)
        XCTAssertEqual(
            EnvironmentProfiles.read(workspace: "prod", under: root).connectedProfiles, ["protect"])
    }

    func testEnvironmentNamesOnlyAForeignSchoolProfile() throws {
        try workspace("prod", config: "school_cli:\n  enabled: true\n  profile: school\n")
        try workspace("edu", config: "school_cli:\n  enabled: true\n  profile: edu\n")
        XCTAssertEqual(
            EnvironmentProfiles.read(workspace: "prod", under: root).connectedProfiles, ["school"])
        XCTAssertEqual(
            EnvironmentProfiles.read(workspace: "edu", under: root).connectedProfiles, [])
    }

    func testEnvironmentNamesNoLoginForMissingOrBlankConfig() throws {
        try workspace("blank", config: "protect:\n  enabled: true\n")
        for name in ["blank", "absent"] {
            XCTAssertEqual(
                EnvironmentProfiles.read(workspace: name, under: root).connectedProfiles, [], name)
        }
    }
}
