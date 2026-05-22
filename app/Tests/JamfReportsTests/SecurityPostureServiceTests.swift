import XCTest
@testable import JamfReports

@MainActor
final class SecurityPostureServiceTests: XCTestCase {

    func testLoadWithNonexistentProfileReturnsEmpty() {
        let snapshot = SecurityPostureService.load(profile: "nonexistent")
        XCTAssertEqual(snapshot, SecurityPostureService.Snapshot.empty)
        XCTAssertEqual(snapshot.totalDevices, 0)
    }

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = SecurityPostureService.Snapshot(
            totalDevices: 0,
            fileVaultEncrypted: nil,
            sipEnabled: nil,
            firewallEnabled: nil,
            gatekeeperEnabled: nil,
            osVersions: [],
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = SecurityPostureService.Snapshot(
            totalDevices: 100,
            fileVaultEncrypted: 80,
            sipEnabled: 95,
            firewallEnabled: 70,
            gatekeeperEnabled: 90,
            osVersions: [],
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = SecurityPostureService.Snapshot(
            totalDevices: 100,
            fileVaultEncrypted: 80,
            sipEnabled: 95,
            firewallEnabled: 70,
            gatekeeperEnabled: 90,
            osVersions: [],
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }
}