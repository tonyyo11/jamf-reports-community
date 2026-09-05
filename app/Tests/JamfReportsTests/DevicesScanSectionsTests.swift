import XCTest
@testable import JamfReports

@MainActor
final class DevicesScanSectionsTests: XCTestCase {

    private func ddmSnapshot() -> DDMDeviceStatusService.Snapshot {
        .init(records: [
            .init(
                deviceId: "42", name: "Mac", managementId: "m", osVersion: "27.0", osBuild: nil,
                reportDate: "2026-09-04T07:00:00.000", ddmReported: true,
                declarations: [
                    .init(
                        identifier: "D-1", active: true, valid: true,
                        reasonCode: nil, reasonText: nil),
                    .init(
                        identifier: "D-2", active: false, valid: true,
                        reasonCode: nil, reasonText: nil)
                ],
                softwareUpdate: .init(
                    pendingOSVersion: "27.1", pendingBuild: nil, installState: "downloading",
                    installReason: nil, failureReason: nil, failureAt: nil, betaEnrollment: nil))
        ], isDetected: true, readFailed: false,
           snapshotDate: Date(timeIntervalSince1970: 1_788_000_000),
           sourceDates: [:])
    }

    private func healthSnapshot() -> MDMCommandHealthService.Snapshot {
        .init(records: [
            .init(
                deviceId: "42", name: "Mac", failedCount: 1, pendingCount: 2,
                failedCommands: ["InstallApplication"], oldestPendingDays: 9)
        ], isDetected: true, readFailed: false, snapshotDate: nil, sourceDates: [:])
    }

    func testModelJoinsByJamfID() {
        let m = DevicesView.scanSectionModel(
            ddm: ddmSnapshot(), health: healthSnapshot(), jamfID: "42")
        XCTAssertEqual(m.ddmLines.first?.0, "Reported")
        XCTAssertTrue(m.ddmLines.contains {
            $0.0 == "Declarations" && $0.1 == "2 (1 inactive)"
        })
        XCTAssertTrue(m.ddmLines.contains {
            $0.0 == "Pending update" && $0.1 == "27.1 (downloading)"
        })
        XCTAssertTrue(m.mdmLines.contains {
            $0.0 == "Failed" && $0.1 == "1 — InstallApplication"
        })
        XCTAssertTrue(m.mdmLines.contains {
            $0.0 == "Pending" && $0.1 == "2, oldest 9d"
        })
        XCTAssertNotNil(m.ddmDate)
    }

    func testUnknownDeviceYieldsNoLines() {
        let m = DevicesView.scanSectionModel(
            ddm: ddmSnapshot(), health: healthSnapshot(), jamfID: "7")
        XCTAssertTrue(m.ddmLines.isEmpty); XCTAssertTrue(m.mdmLines.isEmpty)
    }

    func testNilJamfIDYieldsNoLines() {
        let m = DevicesView.scanSectionModel(
            ddm: ddmSnapshot(), health: healthSnapshot(), jamfID: nil)
        XCTAssertTrue(m.ddmLines.isEmpty); XCTAssertTrue(m.mdmLines.isEmpty)
    }
}
