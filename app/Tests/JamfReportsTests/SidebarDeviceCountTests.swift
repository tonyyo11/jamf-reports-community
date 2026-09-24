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

    func test_deviceCount_returnsZero_whenNoDirExists() {
        let store = WorkspaceStore(demoMode: false)
        // Profile "ghost" has no workspace — summariesDir will throw.
        XCTAssertEqual(store.deviceCount(for: "ghost"), 0)
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
        XCTAssertEqual(store.deviceCount(for: "ghost"), 0)
        XCTAssertEqual(store.lastSyncedRelative(for: DemoData.org.profile), "Synced Apr 25, 06:01")
    }
}
