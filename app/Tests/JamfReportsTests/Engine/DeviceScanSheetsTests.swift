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
                             ["identifier": "D-2", "active": false, "valid": false],
                             ["identifier": "D-3", "active": false, "valid": true],
                             ["identifier": "D-4", "active": false]],
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
        XCTAssertTrue(ints.contains(4), "declaration count")
        XCTAssertTrue(ints.contains(1), "failing declaration count: D-2, the one invalid")
        XCTAssertFalse(ints.contains(3), "the two inactive declarations do not fail")
    }

    /// "Scanned" is the last column of both tabs; a row without `scannedAt` shows its file's stamp.
    func testScannedIsTheLastColumnOfBothTabs() throws {
        try write([[
            "deviceId": "1", "name": "Mac-1", "managementId": "m1", "ddmReported": true,
            "declarations": [], "softwareUpdate": [:], "scannedAt": "2026-11-16T08:00:00Z",
        ]], kind: "ddm-device-status")
        try write([[
            "deviceId": "1", "name": "Mac-1", "failedCount": 0, "pendingCount": 0,
            "failedCommands": [],
        ]], kind: "mdm-command-health")
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        try dash.writeDDMDeviceStatus()
        try dash.writeMDMCommandHealth()
        for (sheet, value) in [
            ("DDM Device Status", "2026-11-16T08:00:00Z"),
            ("MDM Command Health", ISO8601Time.string(try XCTUnwrap(
                CloudStorage.snapshotTimestamp(of: tmpDir.appendingPathComponent(
                    "mdm-command-health/mdm-command-health_20260904T120000.json"))))),
        ] {
            let cells = workbook.sheet(named: sheet)?.dedupedCells ?? []
            let header = try XCTUnwrap(cells.first {
                if case .string("Scanned") = $0.value { return true } else { return false }
            })
            XCTAssertEqual(header.col, cells.filter { $0.row == header.row }.map(\.col).max(),
                           "\(sheet): Scanned is the last header")
            let headers = cells.filter { $0.row == header.row }.sorted { $0.col < $1.col }
                .compactMap { cell -> String? in
                    if case .string(let s) = cell.value { return s } else { return nil }
                }
            XCTAssertEqual(headers, sheet == "DDM Device Status"
                ? ["Device ID", "Name", "OS", "Reported", "Declarations", "Failing",
                   "Pending Version", "Install State", "Failure Reason", "Report Date", "Scanned"]
                : ["Device ID", "Name", "Failed", "Pending", "Oldest Pending (days)",
                   "Failed Commands", "Scanned"], "the earlier columns are unchanged")
            let cell = cells.first { $0.row == header.row + 1 && $0.col == header.col }
            guard case .string(let text)? = cell?.value else {
                return XCTFail("\(sheet): no scan date")
            }
            XCTAssertEqual(text, value)
        }
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
