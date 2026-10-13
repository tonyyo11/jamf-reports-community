import Foundation
import XCTest
@testable import JamfReports

/// Connecting Jamf Protect makes a second jamf-cli profile named in the workspace's
/// `protect.profile`. That profile is a connection, not a workspace (#271).
final class PairedProtectProfileTests: XCTestCase {
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
        let listed = ProfileService.droppingPairedProtectProfiles(
            [profile("prod"), profile("protect")], under: root)
        XCTAssertEqual(names(listed), ["prod"])
    }

    func testProtectProfileWithItsOwnWorkspaceStaysListed() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        try workspace("protect", config: "jamf_cli: {}\n")
        let listed = ProfileService.droppingPairedProtectProfiles(
            [profile("prod"), profile("protect")], under: root)
        XCTAssertEqual(names(listed), ["prod", "protect"])
    }

    func testActiveProfileStaysListed() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        let listed = ProfileService.droppingPairedProtectProfiles(
            [profile("prod"), profile("protect")], under: root, keeping: ["protect"])
        XCTAssertEqual(names(listed), ["prod", "protect"])
    }

    func testDisabledOrBlankProtectBlockHidesNothing() throws {
        try workspace("a", config: "protect:\n  enabled: false\n  profile: p1\n")
        try workspace("b", config: "protect:\n  enabled: true\n  profile: \"\"\n")
        let listed = ProfileService.droppingPairedProtectProfiles(
            [profile("a"), profile("b"), profile("p1")], under: root)
        XCTAssertEqual(names(listed), ["a", "b", "p1"])
    }

    func testJamfSchoolProfileStaysListed() throws {
        try workspace("prod", config: "school_cli:\n  enabled: true\n  profile: school\n")
        let listed = ProfileService.droppingPairedProtectProfiles(
            [profile("prod"), profile("school")], under: root)
        XCTAssertEqual(names(listed), ["prod", "school"])
    }

    func testPairedProfileIsNotARunTarget() throws {
        try workspace("prod", config: "protect:\n  enabled: true\n  profile: protect\n")
        let listed = ProfileService.droppingPairedProtectProfiles(
            [profile("prod"), profile("protect")], under: root)
        XCTAssertEqual(names(ProfileService.runnableProfiles(listed, excluding: [])), ["prod"])
    }

    func testConnectedProductsReadsEnabledBlocksWithAProfile() throws {
        try workspace("prod", config: """
            protect:
              enabled: true
              profile: " protect "
            school_cli:
              enabled: false
              profile: school
            """)
        XCTAssertEqual(
            ConnectedProducts.read(profile: "prod", under: root),
            ConnectedProducts(protectProfile: "protect", schoolProfile: nil))
    }

    func testConnectedProductsIsNoneForMissingOrBlankConfig() throws {
        try workspace("blank", config: "protect:\n  enabled: true\n")
        XCTAssertEqual(ConnectedProducts.read(profile: "blank", under: root), .none)
        XCTAssertEqual(ConnectedProducts.read(profile: "absent", under: root), .none)
    }
}
