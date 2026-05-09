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
