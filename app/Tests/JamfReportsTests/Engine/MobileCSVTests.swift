import XCTest
@testable import JamfReports

final class MobileCSVTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(staleDays: Int = 30) -> ReportConfig {
        var config = ReportConfig()
        var mc = MobileColumnConfig()
        mc.deviceName = "Device Name"
        mc.serialNumber = "Serial Number"
        mc.operatingSystem = "OS Version"
        mc.lastCheckin = "Last Inventory Update"
        mc.email = "Email"
        mc.model = "Model"
        mc.deviceFamily = "Device Family"
        mc.managed = "Managed"
        mc.supervised = "Supervised"
        config.mobileColumns = mc
        var t = ThresholdsConfig()
        t.staleDeviceDays = staleDays
        config.thresholds = t
        return config
    }

    private func makeCSV(rows: [(name: String, serial: String, checkin: String)]) -> Data {
        var lines = ["Device Name,Serial Number,OS Version,Last Inventory Update,Email,Model,Device Family,Managed,Supervised"]
        for row in rows {
            lines.append("\(row.name),\(row.serial),18.0,,,,iPhone,Yes,Yes")
            // Replace last field group to use proper checkin
            lines[lines.count - 1] = "\(row.name),\(row.serial),18.0,\(row.checkin),test@example.com,iPhone 14,iPhone,Yes,Yes"
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func recentDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - writeMobileInventoryCSV

    func testMobileInventoryIncludesActiveDevices() {
        let config = makeConfig(staleDays: 30)
        let csvData = makeCSV(rows: [
            ("iPad1", "AAA", recentDate(daysAgo: 5)),
            ("iPad2", "BBB", recentDate(daysAgo: 45)),  // stale — excluded
        ])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed")
            return
        }
        dashboard.writeMobileInventoryCSV()
        let ws = wb.sheets.first { $0.name == "Mobile Device Inventory" }
        XCTAssertNotNil(ws, "Mobile Device Inventory sheet should exist")
        // Header row + 1 active device row (row 2 is the data row after title+subtitle+header)
        let dataRows = ws!.cells.filter { $0.col == 0 }
        let names = dataRows.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(names.contains("iPad1"), "Active device iPad1 should appear")
        XCTAssertFalse(names.contains("iPad2"), "Stale device iPad2 should be excluded")
    }

    func testMobileInventoryExcludesUnparseableCheckin() {
        let config = makeConfig(staleDays: 30)
        let csvData = makeCSV(rows: [
            ("iPad3", "CCC", ""),  // no check-in date — excluded
            ("iPad4", "DDD", recentDate(daysAgo: 2)),
        ])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        dashboard.writeMobileInventoryCSV()
        let ws = wb.sheets.first { $0.name == "Mobile Device Inventory" }!
        let names = ws.cells.compactMap { cell -> String? in
            guard cell.col == 0, case .string(let s) = cell.value else { return nil }
            return s
        }
        XCTAssertFalse(names.contains("iPad3"), "Device with no checkin date should be excluded")
        XCTAssertTrue(names.contains("iPad4"), "Active device iPad4 should appear")
    }

    func testMobileInventoryHasNineColumns() {
        let config = makeConfig(staleDays: 30)
        let csvData = makeCSV(rows: [("iPad5", "EEE", recentDate(daysAgo: 1))])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        dashboard.writeMobileInventoryCSV()
        let ws = wb.sheets.first { $0.name == "Mobile Device Inventory" }!
        // Find the header row (format == .header)
        let headerCells = ws.cells.filter { $0.format == .header }
        XCTAssertEqual(headerCells.count, 9, "Should have exactly 9 header columns")
    }

    // MARK: - writeMobileStaleCSV

    func testMobileStaleIncludesStaleDevices() {
        let config = makeConfig(staleDays: 30)
        let csvData = makeCSV(rows: [
            ("iPad6", "FFF", recentDate(daysAgo: 5)),   // active — excluded
            ("iPad7", "GGG", recentDate(daysAgo: 60)),  // stale — included
        ])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        dashboard.writeMobileStaleCSV()
        let ws = wb.sheets.first { $0.name == "Mobile Stale Devices" }
        XCTAssertNotNil(ws, "Mobile Stale Devices sheet should exist")
        let names = ws!.cells.compactMap { cell -> String? in
            guard cell.col == 0, case .string(let s) = cell.value else { return nil }
            return s
        }
        XCTAssertTrue(names.contains("iPad7"), "Stale device iPad7 should appear")
        XCTAssertFalse(names.contains("iPad6"), "Active device iPad6 should be excluded")
    }

    func testMobileStaleExcludesUnparseableCheckin() {
        let config = makeConfig(staleDays: 30)
        let csvData = makeCSV(rows: [
            ("iPad8", "HHH", ""),            // no date — excluded (not shown as stale)
            ("iPad9", "III", recentDate(daysAgo: 90)),
        ])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        dashboard.writeMobileStaleCSV()
        let ws = wb.sheets.first { $0.name == "Mobile Stale Devices" }!
        let names = ws.cells.compactMap { cell -> String? in
            guard cell.col == 0, case .string(let s) = cell.value else { return nil }
            return s
        }
        XCTAssertFalse(names.contains("iPad8"), "Device with no checkin should not appear as stale")
        XCTAssertTrue(names.contains("iPad9"), "Stale device iPad9 should appear")
    }

    func testMobileStaleHasDaysStaleAsInteger() {
        let config = makeConfig(staleDays: 30)
        let csvData = makeCSV(rows: [("iPad10", "JJJ", recentDate(daysAgo: 50))])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        dashboard.writeMobileStaleCSV()
        let ws = wb.sheets.first { $0.name == "Mobile Stale Devices" }!
        // Col 2 is "Days Stale" — should be an integer cell value
        let daysCells = ws.cells.filter { $0.col == 2 && $0.format == .int }
        XCTAssertFalse(daysCells.isEmpty, "Days Stale column should have int-formatted cells")
        if let first = daysCells.first, case .int(let days) = first.value {
            XCTAssertGreaterThan(days, 30, "Days stale should exceed threshold")
        }
    }

    // MARK: - Sheet plan wiring

    func testMobileSheetsInPlanWhenDeviceNameConfigured() {
        let config = makeConfig()
        let csvData = makeCSV(rows: [])
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        let names = dashboard.sheetPlan.map { $0.name }
        XCTAssertTrue(names.contains("Mobile Device Inventory"))
        XCTAssertTrue(names.contains("Mobile Stale Devices"))
    }

    func testMobileSheetsAbsentWhenDeviceNameNotConfigured() {
        var config = ReportConfig()
        config.mobileColumns = MobileColumnConfig()  // deviceName is nil
        let csvData = Data("Name,Serial\n".utf8)
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        let names = dashboard.sheetPlan.map { $0.name }
        XCTAssertFalse(names.contains("Mobile Device Inventory"))
        XCTAssertFalse(names.contains("Mobile Stale Devices"))
    }
}

// MARK: - Test helper: expose internal sheets array

extension Workbook {
    var sheets: [Worksheet] {
        // Access via a mirror since the property is private.
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if child.label == "sheets", let sheets = child.value as? [Worksheet] {
                return sheets
            }
        }
        return []
    }
}
