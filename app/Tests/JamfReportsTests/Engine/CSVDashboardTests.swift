import Foundation
import XCTest
@testable import JamfReports

/// Tests for CSVDashboard — focuses on the custom-EA column-not-found warning path.
final class CSVDashboardTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal CSV with a "Computer Name" and "Serial Number" column and one EA column.
    private func makeCSVData(eaColumnName: String, includeEAColumn: Bool) -> Data {
        var header = "Computer Name,Serial Number"
        if includeEAColumn { header += ",\(eaColumnName)" }
        let row1 = includeEAColumn ? "Mac-001,ABC123,Encrypted" : "Mac-001,ABC123"
        let row2 = includeEAColumn ? "Mac-002,DEF456,Not Encrypted" : "Mac-002,DEF456"
        return Data("\(header)\n\(row1)\n\(row2)".utf8)
    }

    private func makeConfig(eaName: String, eaColumn: String) -> ReportConfig {
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        config.customEas = [
            CustomEAConfig(
                name: eaName,
                column: eaColumn,
                type: .boolean,
                trueValue: "Encrypted"
            ),
        ]
        return config
    }

    // MARK: - missingEAColumns property

    func testMissingEAColumnsIsEmptyWhenColumnPresent() throws {
        let eaColumn = "FileVault 2 - Status"
        let csvData = makeCSVData(eaColumnName: eaColumn, includeEAColumn: true)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: eaColumn)
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        XCTAssertTrue(dashboard.missingEAColumns.isEmpty,
                      "No missing columns when the EA column exists in the CSV header.")
    }

    func testMissingEAColumnsContainsNameWhenColumnAbsent() throws {
        let csvData = makeCSVData(eaColumnName: "FileVault 2 - Status", includeEAColumn: false)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: "FileVault 2 - Status")
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        XCTAssertEqual(dashboard.missingEAColumns, ["FileVault Status"])
    }

    func testMissingEAColumnsMultipleEAs() throws {
        let csvData = Data("Computer Name,Serial Number\nMac-001,ABC123".utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        config.customEas = [
            CustomEAConfig(name: "EA One", column: "Missing Col 1", type: .boolean),
            CustomEAConfig(name: "EA Two", column: "Missing Col 2", type: .text),
            CustomEAConfig(name: "EA Three", column: "Missing Col 1", type: .version),
        ]
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        XCTAssertEqual(Set(dashboard.missingEAColumns), ["EA One", "EA Two", "EA Three"])
    }

    // MARK: - Family detection

    func testCSVFamilyDetectedComputers() throws {
        let csvText = "Computer Name,JSS Computer ID,Operating System Version,Last Check-in," +
            "Gatekeeper,System Integrity Protection,FileVault 2 Status,Firewall Enabled," +
            "Secure Boot Level,Processor Type,Apple Silicon,Boot Drive Percentage Full\n" +
            "Mac-001,1,15.4,2024-01-01,Enabled,Enabled,Encrypted,On,Full Security," +
            "Intel Core i9,false,45%\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        config.columns = cols
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .computers)
    }

    func testCSVFamilyDetectedMobile() throws {
        let csvText = "Display Name,JSS Mobile Device ID,OS Version,Last Inventory Update," +
            "Jailbreak Detected,Wi-Fi MAC Address,Battery Level,Lost Mode Enabled," +
            "Device Ownership Type,Passcode Status\n" +
            "iPad-001,100,18.0,2024-01-01,false,aa:bb:cc:dd:ee:ff,85%,false," +
            "Institutional,Compliant\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        let config = ReportConfig()
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .mobile)
    }

    // MARK: - Sheet routing by family

    func testSheetPlan_computerCSV_noMobileSheets() throws {
        // A computer CSV must not produce mobile sheets even when mobile_columns is configured.
        let csvText = "Computer Name,JSS Computer ID,Operating System Version,Last Check-in," +
            "Gatekeeper,Firewall Enabled,FileVault 2 Status\n" +
            "Mac-001,1,15.0,2024-01-01,Enabled,Enabled,Encrypted\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        config.columns = cols
        var mobile = MobileColumnConfig()
        mobile.deviceName = "Display Name"
        config.mobileColumns = mobile
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .computers)
        let sheetNames = dashboard.sheetPlan.map { $0.name }
        XCTAssertTrue(sheetNames.contains("Device Inventory"),
                      "Computer CSV must include Device Inventory sheet")
        XCTAssertFalse(sheetNames.contains("Mobile Device Inventory"),
                       "Computer CSV must not include Mobile Device Inventory sheet")
        XCTAssertFalse(sheetNames.contains("Mobile Stale Devices"),
                       "Computer CSV must not include Mobile Stale Devices sheet")
    }

    func testSheetPlan_mobileCSV_onlyMobileSheets() throws {
        // A mobile CSV must produce only mobile sheets (no Device Inventory etc.).
        let csvText = "Display Name,JSS Mobile Device ID,OS Version,Last Inventory Update," +
            "Jailbreak Detected,Wi-Fi MAC Address,Battery Level,Lost Mode Enabled," +
            "Device Ownership Type,Passcode Status\n" +
            "iPad-001,100,18.0,2024-01-01,false,aa:bb:cc:dd:ee:ff,85%,false," +
            "Institutional,Compliant\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        let config = ReportConfig()
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .mobile)
        let sheetNames = dashboard.sheetPlan.map { $0.name }
        XCTAssertTrue(sheetNames.contains("Mobile Device Inventory"),
                      "Mobile CSV must include Mobile Device Inventory sheet")
        XCTAssertTrue(sheetNames.contains("Mobile Stale Devices"),
                      "Mobile CSV must include Mobile Stale Devices sheet")
        XCTAssertFalse(sheetNames.contains("Device Inventory"),
                       "Mobile CSV must not include Device Inventory sheet")
        XCTAssertFalse(sheetNames.contains("Security Controls"),
                       "Mobile CSV must not include Security Controls sheet")
    }

    // MARK: - Continuation-row drop

    func testContinuationRowsDroppedFromComputerCSV() throws {
        // A 97-device export may be 607 rows due to continuation rows for
        // multi-value fields (Applications, Certificates, Groups…).
        // Rows whose Computer Name cell is blank must be dropped.
        let header = "Computer Name,Serial Number,Operating System Version"
        let real1  = "Mac-001,ABC123,15.4"
        let real2  = "Mac-002,DEF456,14.7"
        // These rows have a blank Computer Name — continuation rows.
        let cont1  = ",,"
        let cont2  = ",,"
        let cont3  = ",,"
        let csvText = [header, real1, cont1, cont2, real2, cont3].joined(separator: "\n") + "\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        // Only the 2 real device rows should survive.
        XCTAssertEqual(dashboard.rows.count, 2,
                       "Continuation rows with blank identity must be dropped")
    }

    func testContinuationRowsNotDroppedWhenIdentityColumnAbsent() throws {
        // When the configured identity column is not in the CSV headers,
        // no rows are dropped (guard: only drop when the column is present but blank).
        let csvData = Data("Serial Number,OS Version\nABC123,15.4\n,15.4\n".utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"  // not present in this CSV
        config.columns = cols
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        // Neither row has a blank Computer Name (column absent) — both kept.
        XCTAssertEqual(dashboard.rows.count, 2,
                       "Rows must not be dropped when the identity column is absent")
    }

    // MARK: - EA Warnings sheet in workbook

    func testEAWarningsSheetAbsentWhenAllColumnsPresent() throws {
        let eaColumn = "FileVault 2 - Status"
        let csvData = makeCSVData(eaColumnName: eaColumn, includeEAColumn: true)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: eaColumn)
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        dashboard.writeAll()
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        try wb.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let data = try Data(contentsOf: tmpURL)
        // "EA Warnings" sheet name should not appear in any XML when all columns are present.
        let content = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertFalse(content.contains("EA Warnings"),
                       "EA Warnings sheet must not be written when all columns are present.")
    }

    func testEAWarningsSheetPresentWhenColumnMissing() throws {
        let csvData = makeCSVData(eaColumnName: "FileVault 2 - Status", includeEAColumn: false)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: "FileVault 2 - Status")
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        dashboard.writeAll()
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        try wb.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let data = try Data(contentsOf: tmpURL)
        let content = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(content.contains("EA Warnings"),
                      "EA Warnings sheet must be written when a configured EA column is absent.")
        XCTAssertTrue(content.contains("FileVault Status"),
                      "EA Warnings sheet must name the missing EA.")
        XCTAssertTrue(content.contains("FileVault 2 - Status"),
                      "EA Warnings sheet must name the expected column.")
    }
}
