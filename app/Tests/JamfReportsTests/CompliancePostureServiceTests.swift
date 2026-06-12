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

    private func decodeDevice(_ json: String) throws -> SecurityDevice {
        try JSONDecoder().decode(SecurityDevice.self, from: Data(json.utf8))
    }

    func testNotCollectedControlsAreUnknownNotFailing() throws {
        // "NOT_COLLECTED" used to count as a failing control, making the
        // compliance proxy report a measured 0% on partially-collected tenants
        // (real shape from a live `pro report security` snapshot).
        let device = try decodeDevice("""
        {"section": "device", "name": "Mac-1", "serial": "X1",
         "filevault": "ENCRYPTED", "sip": "NOT_COLLECTED",
         "gatekeeper": "NOT_COLLECTED", "os_version": "15.0"}
        """)
        XCTAssertFalse(CompliancePostureService.isSIPFailing(device))
        XCTAssertFalse(CompliancePostureService.isGatekeeperFailing(device))
        XCTAssertEqual(CompliancePostureService.deviceGapCount(device), 0,
                       "only the measured (passing) FileVault control participates")

        let allUnknown = try decodeDevice("""
        {"section": "device", "name": "Mac-2", "serial": "X2",
         "filevault": "NOT_COLLECTED", "sip": "UNKNOWN", "gatekeeper": ""}
        """)
        XCTAssertNil(CompliancePostureService.deviceGapCount(allUnknown),
                     "a device with no measured controls is No Data, not compliant")
    }
}
