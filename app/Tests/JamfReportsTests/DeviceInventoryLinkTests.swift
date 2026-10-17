import Foundation
import XCTest
@testable import JamfReports

/// #207 M4: Devices judged a link only after resolving it, so a link to a file or folder inside
/// the workspace passed every check. A link at the entry itself is now refused; config.yaml is
/// still read through one, as `ConfigLoader` reads it.
final class DeviceInventoryLinkTests: XCTestCase {

    private var root: URL!
    private let profile = "links"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-inventory-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: URL {
        root.appendingPathComponent(profile, isDirectory: true)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func link(_ relative: String, to target: String) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: workspace.appendingPathComponent(target)
        )
    }

    private func computers(named name: String, id: String) -> String {
        """
        [{"id": "\(id)", "general": {"name": "\(name)"},
          "hardware": {"serialNumber": "SER\(id)"}}]
        """
    }

    private func deviceNames() -> [String] {
        DeviceInventoryService.load(profile: profile, demoMode: false).devices.map(\.name)
    }

    func testARegularSnapshotIsRead() throws {
        try write(computers(named: "Mac-A", id: "1"),
                  to: "jamf-cli-data/computers/computers_20261015T060000.json")
        XCTAssertEqual(deviceNames(), ["Mac-A"])
    }

    func testALinkedSnapshotFileIsPassedOver() throws {
        try write(computers(named: "Mac-A", id: "1"),
                  to: "jamf-cli-data/computers/computers_20261015T060000.json")
        try write(computers(named: "Mac-B", id: "2"),
                  to: "elsewhere/computers_20261016T060000.json")
        try link("jamf-cli-data/computers/computers_20261016T060000.json",
                 to: "elsewhere/computers_20261016T060000.json")
        XCTAssertEqual(deviceNames(), ["Mac-A"], "the newer name is a link, so it is not read")
    }

    func testALinkedKindFolderIsNotRead() throws {
        try write(computers(named: "Mac-B", id: "2"),
                  to: "elsewhere/computers_20261016T060000.json")
        try link("jamf-cli-data/computers", to: "elsewhere")
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.devices.map(\.name), [])
        let linkWarnings = snapshot.warnings.filter { $0.contains("symbolic link") }
        XCTAssertEqual(linkWarnings.count, 1, "the folder is named once: \(snapshot.warnings)")
        XCTAssertTrue(linkWarnings.first?.contains("jamf-cli-data/computers") == true)
    }

    func testALinkedInboxIsNamedAndARealFolderIsNot() throws {
        try write("Computer Name,Serial Number\nMac-C,SER3\n", to: "elsewhere/inventory.csv")
        try link("csv-inbox", to: "elsewhere")
        try write(computers(named: "Mac-A", id: "1"),
                  to: "jamf-cli-data/computers/computers_20261015T060000.json")
        let warnings = DeviceInventoryService.load(profile: profile, demoMode: false).warnings
            .filter { $0.contains("symbolic link") }
        XCTAssertEqual(warnings.count, 1, "only csv-inbox is a link: \(warnings)")
        XCTAssertTrue(warnings.first?.contains("csv-inbox") == true)
    }

    func testALinkedConfigYAMLIsStillRead() throws {
        try write("thresholds:\n  stale_device_days: 7\n", to: "shared/config.yaml")
        try link("config.yaml", to: "shared/config.yaml")
        XCTAssertEqual(DeviceInventoryService.load(profile: profile, demoMode: false).staleDays, 7)
    }
}
