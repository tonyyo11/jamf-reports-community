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
        XCTAssertEqual(inventory.warnings.filter { $0.hasPrefix("jamf_cli.data_dir is not used: ") }
                        .count, 1, "\(inventory.warnings)")
        XCTAssertFalse(inventory.warnings.contains { $0.contains("/etc") }, "never the typed value")
        XCTAssertTrue(DeviceInventoryService.sourceDates(profile: profile, demoMode: false).isEmpty)
        XCTAssertNil(DeviceInventoryService.cachedComputerRecords(profile: profile))

        let lookup = DeviceLookupIndex.read(profile: profile)
        XCTAssertTrue(lookup.lastError?.hasPrefix("jamf_cli.data_dir is not used: ") == true)
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

    /// The device-detail cache's old fixed folder is read only beside a data folder that
    /// resolved, never under a refused one.
    func testTheLegacyDeviceCacheIsNotReadUnderARefusedDataFolder() async throws {
        let workspace = try workspace(dataDir: "/etc")
        let legacy = workspace.appendingPathComponent("jamf-cli-data/devices", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"general":{"name":"Planted"}}"#.utf8)
            .write(to: legacy.appendingPathComponent(deviceCacheFilename("C02TEST")))
        let profile = self.profile
        let result = await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { nil })
        XCTAssertNil(result, "the planted legacy cache is not read")
    }

    /// The three Trends backfills leave the summaries as recorded under a refused data folder,
    /// with a mobile snapshot in the default folder that a fallback would have read.
    func testTheTrendsBackfillsLeaveSummariesAsRecorded() throws {
        let workspace = try workspace(dataDir: "/etc")
        let config = "jamf_cli:\n  data_dir: \"/etc\"\nsecurity_agents:\n  - name: \"EDR\"\n"
            + "    column: \"EDR\"\n    connected_value: \"Running\"\n"
        try config.write(to: workspace.appendingPathComponent("config.yaml"), atomically: true,
                         encoding: .utf8)
        let mobile = workspace.appendingPathComponent(
            "jamf-cli-data/mobile-devices-list", isDirectory: true)
        try FileManager.default.createDirectory(at: mobile, withIntermediateDirectories: true)
        try Data(#"[{"general":{"managed":true},"hardware":{"model":"iPad"}}]"#.utf8)
            .write(to: mobile.appendingPathComponent("mobile-devices-list_20261101T060000.json"))
        let summary = try SummaryJSONParser.decode(Data(
            #"{"date":"2026-11-01","totalDevices":3,"source":"jamf-cli","patchPct":50}"#.utf8))
        XCTAssertNil(TrendStore.resolvingMobile([summary], profile: profile).first?.mobile)
        XCTAssertNil(TrendStore.resolvingAgentCoverage([summary], profile: profile)
            .first?.securityAgentCoverage)
        let patched = TrendStore.resolvingPatch([summary], profile: profile).first
        XCTAssertEqual(patched?.patchPct, 50)
        XCTAssertEqual(patched?.patchPctBasis, summary.patchPctBasis)
    }

    /// `check` names the refusal through the one seam, never the raw path error.
    func testCheckWarnsAboutTheRefusedDataFolder() throws {
        _ = try workspace(dataDir: "/etc")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        let saved = dup(2)
        fflush(stderr)
        dup2(handle.fileDescriptor, 2)
        _ = runCheck(profile: profile)
        fflush(stderr)
        dup2(saved, 2)
        close(saved)
        try handle.close()
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("[warn] jamf_cli.data_dir is not used: "), text)
        XCTAssertFalse(text.contains("/etc"), "the typed value is not echoed")
    }
}
