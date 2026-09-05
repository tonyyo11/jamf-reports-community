import Foundation
import XCTest
@testable import JamfReports

@MainActor
final class DeviceScanSheetsTests: XCTestCase {

    private nonisolated(unsafe) var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceScanSheets_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    private func write(_ rows: [[String: Any]], kind: String) throws {
        let dir = tmpDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows)
            .write(to: dir.appendingPathComponent("\(kind)_20260904T120000.json"))
    }

    private func strings(in sheet: String, of workbook: Workbook) -> [String] {
        (workbook.sheet(named: sheet)?.dedupedCells ?? []).compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
    }

    func testSheetIDsAndTemplateRegistration() {
        XCTAssertEqual(SheetID.ddmDeviceStatus.rawValue, "DDM Device Status")
        XCTAssertEqual(SheetID.mdmCommandHealth.rawValue, "MDM Command Health")
        XCTAssertTrue(FullInstanceTemplate().includedSheets.contains(.ddmDeviceStatus))
        XCTAssertTrue(FullInstanceTemplate().includedSheets.contains(.mdmCommandHealth))
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir,
                                 workbook: Workbook(accentColor: "#2D5EA2"))
        let names = dash.sheetPlan.map(\.name)
        XCTAssertTrue(names.contains("DDM Device Status"))
        XCTAssertTrue(names.contains("MDM Command Health"))
    }

    func testDDMSheetOneRowPerDeviceWithDeclarationCounts() throws {
        try write([[
            "deviceId": "1", "name": "Mac-1", "managementId": "m1", "osVersion": "27.0",
            "reportDate": "2026-09-04T07:00:00.000", "ddmReported": true,
            "declarations": [["identifier": "D-1", "active": true, "valid": true],
                             ["identifier": "D-2", "active": false, "valid": false]],
            "softwareUpdate": ["pendingOSVersion": "27.1", "installState": "pending",
                               "failureReason": "Insufficient space"],
        ], [
            "deviceId": "2", "name": "Mac-2", "managementId": "m2", "ddmReported": false,
            "declarations": [], "softwareUpdate": [:],
        ]], kind: "ddm-device-status")
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeDDMDeviceStatus())
        let s = strings(in: "DDM Device Status", of: workbook)
        XCTAssertTrue(s.contains("Mac-1")); XCTAssertTrue(s.contains("Mac-2"))
        XCTAssertTrue(s.contains("Insufficient space"))
        XCTAssertTrue(s.contains("27.1"))
        XCTAssertTrue(s.contains("Not reported"), "a 404 device renders as Not reported, not blank")
        let ints = (workbook.sheet(named: "DDM Device Status")?.dedupedCells ?? []).compactMap {
            if case let .int(i) = $0.value { return i } else { return nil }
        }
        XCTAssertTrue(ints.contains(2), "declaration count")
        XCTAssertTrue(ints.contains(1), "failing declaration count (inactive or invalid)")
    }

    func testMDMSheetListsFailedCommandNames() throws {
        try write([[
            "deviceId": "1", "name": "Mac-1", "failedCount": 2, "pendingCount": 1,
            "failedCommands": ["InstallApplication", "ProfileList"], "oldestPendingDays": 9,
        ]], kind: "mdm-command-health")
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeMDMCommandHealth())
        let s = strings(in: "MDM Command Health", of: workbook)
        XCTAssertTrue(s.contains("InstallApplication; ProfileList"))
        XCTAssertTrue(s.contains("Mac-1"))
    }

    func testNoSnapshotWritesNoSheet() {
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        // loadLatestJSON throws on a missing kind.
        XCTAssertThrowsError(try dash.writeDDMDeviceStatus())
        XCTAssertNil(workbook.sheet(named: "DDM Device Status"))
    }
}
