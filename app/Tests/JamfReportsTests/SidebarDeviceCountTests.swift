import XCTest
@testable import JamfReports

/// Tests for `WorkspaceStore.deviceCount(for:)` and `lastSyncedRelative(for:)` added in Unit 10.
@MainActor
final class SidebarDeviceCountTests: XCTestCase {

    nonisolated(unsafe) var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarDeviceCountTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - deviceCount

    func test_deviceCount_isNil_whenNoDirExists() {
        let store = WorkspaceStore(demoMode: false)
        // Profile "ghost" has no workspace — summariesDir will throw.
        XCTAssertNil(store.deviceCount(for: "ghost"))
        XCTAssertNil(SummaryJSONParser.newestDeviceCount(profile: "ghost"))
    }

    func test_newestDeviceCount_readsTotalDevices() throws {
        let profile = try makeWorkspace()
        try writeSummary(profile, day: "2026-11-14", json: ["totalDevices": 524])
        XCTAssertEqual(SummaryJSONParser.newestDeviceCount(profile: profile), 524)
    }

    func test_newestDeviceCount_goesByTheDateInTheName_notMtime() throws {
        let profile = try makeWorkspace()
        let newer = try writeSummary(profile, day: "2026-11-14", json: ["totalDevices": 600])
        let older = try writeSummary(profile, day: "2026-11-10", json: ["totalDevices": 500])
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: newer.path)
        XCTAssertEqual(SummaryJSONParser.newestDeviceCount(profile: profile), 600)
    }

    func test_newestDeviceCount_ignoresSyncConflictCopies() throws {
        let profile = try makeWorkspace()
        try writeSummary(profile, day: "2026-11-10", json: ["totalDevices": 500])
        try writeSummary(profile, day: "2026-11-15 2", json: ["totalDevices": 999])
        XCTAssertEqual(SummaryJSONParser.newestDeviceCount(profile: profile), 500)
    }

    /// Jamf School and mobile-only days write `totalDevices` 0 beside `mobileDeviceCount`.
    func test_newestDeviceCount_addsMobileDevices() throws {
        let profile = try makeWorkspace()
        try writeSummary(
            profile, day: "2026-11-14", json: ["totalDevices": 0, "mobileDeviceCount": 120])
        XCTAssertEqual(SummaryJSONParser.newestDeviceCount(profile: profile), 120)
        try writeSummary(
            profile, day: "2026-11-15", json: ["totalDevices": 40, "mobileDeviceCount": 120])
        XCTAssertEqual(SummaryJSONParser.newestDeviceCount(profile: profile), 160)
    }

    func test_refreshDeviceCounts_fillsTheCacheTheMenuReads() async throws {
        let profile = try makeWorkspace()
        try writeSummary(profile, day: "2026-11-14", json: ["totalDevices": 524])
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [JamfCLIProfile(name: profile, url: "", schedules: 0, status: .ok)]
        XCTAssertNil(store.deviceCount(for: profile), "nothing read until refreshed")
        await store.refreshDeviceCounts()
        XCTAssertEqual(store.deviceCount(for: profile), 524)
    }

    private func makeWorkspace() throws -> String {
        setenv("JRC_TEST_WORKSPACES_ROOT", tempDir.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "badge-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(
            at: try WorkspacePaths.summariesDir(for: profile), withIntermediateDirectories: true)
        return profile
    }

    @discardableResult
    private func writeSummary(_ profile: String, day: String, json: [String: Any]) throws -> URL {
        var body = json
        body["date"] = day
        body["source"] = "jamf-cli"
        let url = try WorkspacePaths.summariesDir(for: profile)
            .appendingPathComponent("summary_\(day).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    // MARK: - lastSyncedRelative

    func test_lastSyncedRelative_returnsNeverSynced_whenNoDirExists() {
        let store = WorkspaceStore(demoMode: false)
        XCTAssertEqual(store.lastSyncedRelative(for: "ghost"), "Never synced")
    }

    // MARK: - Demo mode

    /// Demo mode read the disk too, so every demo screen's profile chip said
    /// "Never synced" and the profile menu listed no device counts.
    func test_demoMode_describesTheDemoFleet() {
        let store = WorkspaceStore(demoMode: true)
        XCTAssertEqual(store.deviceCount(for: DemoData.org.profile), DemoData.totalDevices)
        XCTAssertEqual(store.deviceCount(for: "meridianedu"), DemoData.totalDevices - 37)
        XCTAssertNil(store.deviceCount(for: "ghost"))
        XCTAssertEqual(store.lastSyncedRelative(for: DemoData.org.profile), "Synced Apr 25, 06:01")
    }
}
