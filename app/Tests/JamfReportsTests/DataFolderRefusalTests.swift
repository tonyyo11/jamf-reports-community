import XCTest
@testable import JamfReports

/// A `jamf_cli.data_dir` the path rules refuse is never swapped for `<workspace>/jamf-cli-data`:
/// each reader reads nothing, even with snapshots sitting in the default folder.
@MainActor
final class DataFolderRefusalTests: XCTestCase {
    private let profile = "refuseddataprof"

    private func workspace(dataDir: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Refused-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let workspace = workspaces.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        try "jamf_cli:\n  data_dir: \"\(dataDir)\"\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        // A snapshot in the default folder, which a fallback would have read.
        let computers = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try FileManager.default.createDirectory(at: computers, withIntermediateDirectories: true)
        try Data(#"[{"id":"1","general":{"name":"Planted"}}]"#.utf8).write(
            to: computers.appendingPathComponent("computers_20261101T060000.json"))
        return workspace
    }

    func testRefusedDataFolderReadsNothingFromTheDefaultFolder() throws {
        _ = try workspace(dataDir: "/etc")
        XCTAssertThrowsError(try WorkspacePaths.dataDir(for: profile), "a system folder is refused")

        let inventory = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertTrue(inventory.devices.isEmpty, "the planted default-folder Mac is not read")
        XCTAssertEqual(inventory.warnings.filter { $0.contains("data_dir could not be used") }.count,
                       1, "\(inventory.warnings)")
        XCTAssertTrue(DeviceInventoryService.sourceDates(profile: profile, demoMode: false).isEmpty)
        XCTAssertNil(DeviceInventoryService.cachedComputerRecords(profile: profile))

        let lookup = DeviceLookupIndex.read(profile: profile)
        XCTAssertTrue(lookup.lastError?.contains("data_dir could not be used") == true)
        XCTAssertTrue(SourcesView.newestSnapshots(kinds: ["computers"], profile: profile).isEmpty)
    }

    /// The same workspace with the default data folder reads the Mac, so the test above is
    /// about the refusal, not a broken fixture.
    func testTheDefaultDataFolderStillReads() throws {
        _ = try workspace(dataDir: "jamf-cli-data")
        let inventory = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(inventory.devices.count, 1)
        XCTAssertFalse(SourcesView.newestSnapshots(kinds: ["computers"], profile: profile).isEmpty)
    }
}
