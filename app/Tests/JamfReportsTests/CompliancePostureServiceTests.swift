import XCTest
@testable import JamfReports

@MainActor
final class CompliancePostureServiceTests: XCTestCase {

    func testLoadWithNonexistentProfileReturnsEmpty() {
        let snapshot = CompliancePostureService.load(profile: "nonexistent")
        XCTAssertEqual(snapshot, CompliancePostureService.Snapshot.empty)
        XCTAssertEqual(snapshot.totalDevices, 0)
    }

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = CompliancePostureService.Snapshot(
            totalDevices: 0,
            bands: [],
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = CompliancePostureService.Snapshot(
            totalDevices: 100,
            bands: [],
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = CompliancePostureService.Snapshot(
            totalDevices: 100,
            bands: [],
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }
}