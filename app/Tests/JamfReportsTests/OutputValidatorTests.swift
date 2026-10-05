import XCTest
import Foundation
import ZIPFoundation
@testable import JamfReports

// MARK: - OutputValidatorTests

/// Tests for XLSXValidator.
final class OutputValidatorTests: XCTestCase {

    // MARK: - XLSXValidator — positive path
    //
    // C-01 (PR-5): the prior `testGoldenXLSXPassesValidation` and
    // `testGoldenXLSXHasNoErrors` both loaded `golden_workbook.xlsx`
    // from `Bundle.module`, which was never shipped in the test
    // bundle — they skipped perpetually. Replaced with programmatic
    // tests that build a minimal valid XLSX via the same helpers the
    // negative-path tests use (`buildXLSXWithCell`), so the positive
    // path actually runs in CI. This couples positive and negative
    // coverage to a shared synthetic baseline, which is the correct
    // tradeoff once the bundle fixture is acknowledged as absent.

    func testProgrammaticXLSXPassesValidation() throws {
        let xlsx = try buildXLSXWithCell(value: "OK")
        defer { try? FileManager.default.removeItem(at: xlsx) }
        let report = try XLSXValidator().validate(at: xlsx)
        XCTAssertTrue(report.isValid,
                      "Synthetic valid XLSX must pass: \(report.issues.map(\.message))")
    }

    func testProgrammaticXLSXHasNoErrorIssues() throws {
        let xlsx = try buildXLSXWithCell(value: "OK")
        defer { try? FileManager.default.removeItem(at: xlsx) }
        let report = try XLSXValidator().validate(at: xlsx)
        let errors = report.issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,
                      "Synthetic valid XLSX should produce no error issues: \(errors.map(\.message))")
    }

    // MARK: - XLSXValidator — corrupted variants

    func testEmptyXLSXThrows() {
        let tmp = writeTempFile(name: "empty.xlsx", content: "")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try XLSXValidator().validate(at: tmp))
    }

    func testNotFoundXLSXThrows() {
        XCTAssertThrowsError(
            try XLSXValidator().validate(at: URL(fileURLWithPath: "/nonexistent/workbook.xlsx"))
        )
    }

    func testXLSXWithErrorLiteralFails() throws {
        // Build an XLSX that contains a #REF! literal in a sheet.
        let xlsx = try buildXLSXWithCell(value: "#REF!")
        defer { try? FileManager.default.removeItem(at: xlsx) }
        let report = try XLSXValidator().validate(at: xlsx)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("#REF!") })
    }

    func testXLSXWithDivZeroFails() throws {
        let xlsx = try buildXLSXWithCell(value: "#DIV/0!")
        defer { try? FileManager.default.removeItem(at: xlsx) }
        let report = try XLSXValidator().validate(at: xlsx)
        XCTAssertFalse(report.isValid)
    }

    func testXLSXMissingContentTypesFails() throws {
        let xlsx = try buildXLSXMissingEntry("[Content_Types].xml")
        defer { try? FileManager.default.removeItem(at: xlsx) }
        let report = try XLSXValidator().validate(at: xlsx)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("[Content_Types].xml") })
    }

    // MARK: - XLSXValidator — production writer round-trip (Epic #102, item #7)

    /// `testProgrammaticXLSXPassesValidation` builds an XLSX by hand via
    /// `buildXLSXWithCell`. That exercises the validator but never the
    /// production OOXML writer. This round-trips the real path: a `Workbook`
    /// populated by `CSVDashboard`, serialized through `Workbook.write(to:)`,
    /// then run through the same `XLSXValidator` — so a regression in the
    /// production writer surfaces as a validation failure.
    func testProductionWorkbookWriterPassesValidation() throws {
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        let csv = Data("Computer Name,Serial Number\nMac-001,ABC123\nMac-002,DEF456\n".utf8)

        let workbook = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csv, workbook: workbook)
        )
        let written = dashboard.writeAll()
        XCTAssertFalse(written.isEmpty, "CSVDashboard must write at least one sheet")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let xlsxURL = tmpDir.appendingPathComponent("production.xlsx")
        try workbook.write(to: xlsxURL)

        let report = try XLSXValidator().validate(at: xlsxURL)
        XCTAssertTrue(
            report.isValid,
            "Production-writer XLSX must pass XLSXValidator; issues: \(report.issues.map(\.message))"
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func writeTempFile(name: String, content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("writeTempFile: could not write fixture '\(name)' to \(url.path): \(error)")
        }
        return url
    }

    /// Build a minimal XLSX zip containing a sheet with a specific cell value.
    private func buildXLSXWithCell(value: String) throws -> URL {
        let sheet1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>\(value)</t></is></c></row>
          </sheetData>
        </worksheet>
        """
        return try buildXLSX(sheet1: sheet1, omitEntry: nil)
    }

    /// Build a minimal XLSX with a specific entry removed.
    private func buildXLSXMissingEntry(_ entryName: String) throws -> URL {
        return try buildXLSX(sheet1: minimalSheet1XML(), omitEntry: entryName)
    }

    private func minimalSheet1XML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>OK</t></is></c></row></sheetData>
        </worksheet>
        """
    }

    private func buildXLSX(sheet1: String, omitEntry: String?) throws -> URL {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).xlsx")

        let archive = try Archive(url: tmpURL, accessMode: .create)
        let entries: [(String, String)] = [
            ("[Content_Types].xml", minimalContentTypes()),
            ("xl/workbook.xml", minimalWorkbookXML()),
            ("xl/worksheets/sheet1.xml", sheet1),
            ("xl/_rels/workbook.xml.rels", minimalWBRels()),
        ]
        for (name, content) in entries {
            if name == omitEntry { continue }
            let data = Data(content.utf8)
            try archive.addEntry(with: name, type: .file,
                                 uncompressedSize: Int64(data.count)) { _, _ in data }
        }
        return tmpURL
    }

    private func minimalContentTypes() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Override PartName="/xl/workbook.xml"
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml"
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
    }

    private func minimalWorkbookXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
    }

    private func minimalWBRels() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1"
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
            Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
    }
}
