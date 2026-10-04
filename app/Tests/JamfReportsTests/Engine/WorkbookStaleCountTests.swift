import Foundation
import XCTest
@testable import JamfReports

/// The workbook's "stale" counts follow `thresholds.stale_device_days` from each Mac's days
/// since contact, not jamf-cli's own `stale` flag (a 14-day cut), and the Compliance Posture
/// table shows that day count.
///
/// Fixture: ten invented Macs. jamf-cli flags every Mac at 14 days or more, so seven carry
/// `stale: true`; at the default 30-day threshold only the three over 30 days are stale.
final class WorkbookStaleCountTests: XCTestCase {

    private var tmpDirs: [URL] = []

    override func tearDown() {
        for dir in tmpDirs { try? FileManager.default.removeItem(at: dir) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    /// Days since contact; only the first Mac is unmanaged. jamf-cli's `stale` flag is set at
    /// 14 days or more, as in a real device-compliance report.
    private static let days = [2, 10, 13, 14, 20, 29, 30, 31, 90, 400]

    private func deviceRows(extra: [[String: Any]] = []) -> [[String: Any]] {
        let base = Self.days.enumerated().map { index, days -> [String: Any] in
            [
                "name": "Test-Mac-\(index)", "serial": "SERIAL\(index)",
                "managed": index != 0, "stale": days >= 14, "days_since_contact": String(days),
                "os_version": "15.0", "last_contact": "2026-01-01T00:00:00.000Z",
            ]
        }
        return base + extra
    }

    private func dashboard(
        rows: [[String: Any]], staleDays: Int? = nil, patch: Bool = false
    ) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        tmpDirs.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "device-compliance", dataDir: dataDir, at: anchor, rows: rows)
        if patch {
            try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: anchor, rows: [
                GoldenFleetWorkspace.patchRow(id: "1", title: "Chrome", onLatest: 8, total: 10),
            ])
        }
        var config = ReportConfig()
        if let staleDays {
            var thresholds = ThresholdsConfig()
            thresholds.staleDeviceDays = staleDays
            config.thresholds = thresholds
        }
        return CoreDashboard(config: config, dataDir: dataDir, workbook: Workbook())
    }

    private func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .blank: return ""
        }
    }

    /// The cells of the first row whose first column reads `label`, by column.
    private func row(
        _ dash: CoreDashboard, _ sheet: String, _ label: String
    ) throws -> [Int: String] {
        let cells = try XCTUnwrap(dash.workbook.sheet(named: sheet)?.dedupedCells, "no \(sheet)")
        let first = try XCTUnwrap(
            cells.first { $0.col == 0 && text($0.value) == label }, "\(sheet) has no \(label)")
        return Dictionary(uniqueKeysWithValues: cells.filter { $0.row == first.row }
            .map { ($0.col, text($0.value)) })
    }

    // MARK: - Active Devices

    func testActiveDevicesCountsAgainstTheConfiguredThresholdNotTheFourteenDayFlag() throws {
        let dash = try dashboard(rows: deviceRows())
        try dash.writeActiveDevices()

        XCTAssertEqual(try row(dash, "Active Devices", "Stale Devices")[1], "3")
        XCTAssertEqual(try row(dash, "Active Devices", "Active (non-stale)")[1], "7")
        XCTAssertEqual(try row(dash, "Active Devices", "Total Devices")[1], "10")
    }

    func testActiveDevicesFollowsAChangedThreshold() throws {
        let dash = try dashboard(rows: deviceRows(), staleDays: 20)
        try dash.writeActiveDevices()

        // More than 20 days: 29, 30, 31, 90 and 400.
        XCTAssertEqual(try row(dash, "Active Devices", "Stale Devices")[1], "5")
    }

    func testAMacWithNoDayCountFallsBackToTheFlagInsteadOfCountingActive() throws {
        let noDays: [[String: Any]] = [
            ["name": "Test-Mac-flagged", "serial": "S-F", "managed": true, "stale": true],
            ["name": "Test-Mac-clear", "serial": "S-C", "managed": true, "stale": false],
        ]
        let dash = try dashboard(rows: deviceRows(extra: noDays))
        try dash.writeActiveDevices()

        XCTAssertEqual(try row(dash, "Active Devices", "Stale Devices")[1], "4")
    }

    // MARK: - Compliance Posture

    func testCompliancePostureStaleRowMatchesItsLabel() throws {
        let dash = try dashboard(rows: deviceRows())
        try dash.writeCompliancePosture()

        XCTAssertEqual(try row(dash, "Compliance Posture", "Stale Devices (>30 days)")[1], "3")
    }

    func testCompliancePostureLabelAndCountMoveTogether() throws {
        let dash = try dashboard(rows: deviceRows(), staleDays: 60)
        try dash.writeCompliancePosture()

        XCTAssertEqual(try row(dash, "Compliance Posture", "Stale Devices (>60 days)")[1], "2")
    }

    func testPostureTableShowsDaysSinceCheckInLongestFirst() throws {
        let dash = try dashboard(rows: deviceRows())
        try dash.writeCompliancePosture()

        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Compliance Posture")?.dedupedCells)
        let header = try XCTUnwrap(
            cells.first { $0.col == 0 && text($0.value) == "Device Name" }).row
        let days = (1...4).map { offset in
            text(cells.first { $0.row == header + offset && $0.col == 2 }?.value ?? .blank)
        }
        // 400, 90, 31 are stale; the unmanaged Mac at 2 days is listed after them.
        XCTAssertEqual(days, ["400", "90", "31", "2"])
        let dashes = cells.filter { $0.row > header && $0.col == 2 && text($0.value) == "\u{2014}" }
        XCTAssertTrue(dashes.isEmpty, "no row should read a dash when the day count is known")
    }

    func testPostureTableMarksOnlyOverThresholdMacsStale() throws {
        let dash = try dashboard(rows: deviceRows())
        try dash.writeCompliancePosture()

        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Compliance Posture")?.dedupedCells)
        let header = try XCTUnwrap(
            cells.first { $0.col == 0 && text($0.value) == "Device Name" }).row
        let stale = (1...4).map { offset in
            text(cells.first { $0.row == header + offset && $0.col == 3 }?.value ?? .blank)
        }
        XCTAssertEqual(stale, ["Yes", "Yes", "Yes", "No"])
    }

    // MARK: - Device Compliance and Patch Summary Dashboard

    func testDeviceComplianceSheetShowsDaysAndTheConfiguredStaleColumn() throws {
        let dash = try dashboard(rows: deviceRows())
        try dash.writeDeviceCompliance()

        let thirty = try row(dash, "Device Compliance", "Test-Mac-6")
        XCTAssertEqual(thirty[3], "No", "exactly 30 days is not more than 30")
        XCTAssertEqual(thirty[4], "30")
        let ninety = try row(dash, "Device Compliance", "Test-Mac-8")
        XCTAssertEqual(ninety[3], "Yes")
        XCTAssertEqual(ninety[4], "90")
    }

    func testPatchSummaryDashboardActiveWindowUsesTheConfiguredThreshold() throws {
        let dash = try dashboard(rows: deviceRows(), patch: true)
        try dash.writePatchSummaryDashboard()

        XCTAssertEqual(try row(dash, "Patch Summary Dashboard", "Active Devices")[1], "7")
        XCTAssertEqual(try row(dash, "Patch Summary Dashboard", "Inactive Devices")[1], "3")
    }
}
