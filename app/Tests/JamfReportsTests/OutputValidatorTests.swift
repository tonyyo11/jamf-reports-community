import XCTest
import Foundation
import ZIPFoundation
@testable import JamfReports

// MARK: - OutputValidatorTests

/// Tests for HTMLValidator, PNGValidator, XLSXValidator, and PDFValidator.
///
/// Golden fixtures live in Tests/JamfReportsTests/Fixtures/ and are loaded
/// via Bundle.module (the test target's resource bundle).
final class OutputValidatorTests: XCTestCase {

    // MARK: - Bundle helper

    /// Resolve a fixture URL from the test bundle.
    private func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw XCTSkip("Fixture '\(name)' not found in test bundle — skipping")
        }
        return url
    }

    // MARK: - PNGValidator — golden fixture

    func testGoldenPNGPassesValidation() throws {
        let url = try fixtureURL("golden_chart.png")
        let report = try PNGValidator().validate(at: url)
        XCTAssertTrue(report.isValid, "Golden PNG must pass: \(report.issues.map(\.message))")
    }

    func testGoldenPNGHasNoErrors() throws {
        let url = try fixtureURL("golden_chart.png")
        let report = try PNGValidator().validate(at: url)
        XCTAssertTrue(report.issues.filter { $0.severity == .error }.isEmpty,
                      "Golden PNG should produce no error issues")
    }

    // MARK: - PNGValidator — corrupted variants

    func testTruncatedPNGFailsValidation() {
        // Valid signature only — no IHDR.
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let data = Data(signature)
        let report = PNGValidator().validateData(data)
        XCTAssertFalse(report.isValid, "Truncated PNG (sig only) must fail validation")
        XCTAssertTrue(report.issues.contains { $0.severity == .error })
    }

    func testEmptyFileFails() {
        let report = PNGValidator().validateData(Data())
        XCTAssertFalse(report.isValid)
    }

    func testWrongSignatureFails() {
        let badSig = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07] + [UInt8](repeating: 0, count: 50))
        let report = PNGValidator().validateData(badSig)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("signature") })
    }

    func testMissingIENDFails() {
        // Build a PNG with valid signature + IHDR but no IEND.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // IHDR length (13)
        bytes += [0x00, 0x00, 0x00, 0x0D]
        // Type "IHDR"
        bytes += [0x49, 0x48, 0x44, 0x52]
        // width=1
        bytes += [0x00, 0x00, 0x00, 0x01]
        // height=1
        bytes += [0x00, 0x00, 0x00, 0x01]
        // bit depth=8, color type=2, compress=0, filter=0, interlace=0
        bytes += [0x08, 0x02, 0x00, 0x00, 0x00]
        // fake CRC (4 bytes)
        bytes += [0x00, 0x00, 0x00, 0x00]
        // Extra padding — no IEND
        bytes += [UInt8](repeating: 0xAB, count: 50)
        let report = PNGValidator().validateData(Data(bytes))
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.lowercased().contains("iend") })
    }

    func testZeroDimensionIHDRFails() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0x00, 0x00, 0x00, 0x0D]
        bytes += [0x49, 0x48, 0x44, 0x52]
        // width=0, height=0
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x08, 0x02, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00]
        bytes += [0x49, 0x45, 0x4E, 0x44]  // IEND marker (no length/crc, just type bytes)
        bytes += [UInt8](repeating: 0, count: 8)
        let report = PNGValidator().validateData(Data(bytes))
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("zero") || $0.message.contains("0×0") })
    }

    // MARK: - HTMLValidator — golden fixture

    func testGoldenHTMLPassesValidation() throws {
        let url = try fixtureURL("golden_html.html")
        let report = try HTMLValidator().validate(at: url)
        XCTAssertTrue(report.isValid, "Golden HTML must pass: \(report.issues.map(\.message))")
    }

    func testGoldenHTMLHasNoErrors() throws {
        let url = try fixtureURL("golden_html.html")
        let report = try HTMLValidator().validate(at: url)
        let errors = report.issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "Golden HTML should produce no errors: \(errors.map(\.message))")
    }

    // MARK: - HTMLValidator — corrupted variants

    func testHTMLWithEvalFailsXSSCheck() throws {
        let tmp = writeTempFile(
            name: "evil.html",
            content: "<html><body><script>eval('alert(1)')</script></body></html>"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try HTMLValidator().validate(at: tmp)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("eval") })
    }

    func testHTMLWithFunctionConstructorFailsXSSCheck() throws {
        let tmp = writeTempFile(
            name: "evil2.html",
            content: "<html><body><script>var f = new Function('return 1')</script></body></html>"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try HTMLValidator().validate(at: tmp)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("Function") })
    }

    func testHTMLWithMissingLocalImageFails() throws {
        let tmp = writeTempFile(
            name: "missing_img.html",
            content: "<html><body><img src=\"nonexistent_chart.png\"></body></html>"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try HTMLValidator().validate(at: tmp)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.lowercased().contains("missing") })
    }

    func testHTMLWithValidDataURIPassesImageCheck() throws {
        // Minimal valid base64 data URI.
        let tmp = writeTempFile(
            name: "datauri.html",
            content: "<html><body><img src=\"data:image/png;base64,iVBORw0KGgo=\"></body></html>"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try HTMLValidator().validate(at: tmp)
        // No missing image error (data URI presence accepted).
        let imgErrors = report.issues.filter {
            $0.severity == .error && $0.message.lowercased().contains("missing")
        }
        XCTAssertTrue(imgErrors.isEmpty, "Data URI should not trigger missing-image error")
    }

    func testHTMLWithEmptyDataURIFails() throws {
        let tmp = writeTempFile(
            name: "empty_data.html",
            content: "<html><body><img src=\"data:image/png;base64,\"></body></html>"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try HTMLValidator().validate(at: tmp)
        XCTAssertTrue(report.issues.contains { $0.severity == .error && $0.message.contains("Empty") })
    }

    func testUnreadableHTMLThrows() {
        XCTAssertThrowsError(
            try HTMLValidator().validate(at: URL(fileURLWithPath: "/nonexistent/path.html"))
        )
    }

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

    // MARK: - PDFValidator — basic

    func testEmptyFileFailsPDFValidation() {
        let data = Data()
        let report = PDFValidator().validateData(data, url: nil)
        XCTAssertFalse(report.isValid)
    }

    func testNonPDFBytesFailValidation() {
        let data = Data("This is not a PDF file at all.".utf8)
        let report = PDFValidator().validateData(data, url: nil)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.message.contains("%PDF-") })
    }

    func testPDFWithHeaderButNoEOFFails() {
        let content = "%PDF-1.7\nsome content\nbut no eof marker at the end"
        let data = Data(content.utf8)
        let report = PDFValidator().validateData(data, url: nil)
        // Either fails on %%EOF or PDFKit can't open it — both acceptable.
        XCTAssertFalse(report.isValid)
    }

    func testUnreadablePDFThrows() {
        XCTAssertThrowsError(
            try PDFValidator().validate(at: URL(fileURLWithPath: "/nonexistent/doc.pdf"))
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func writeTempFile(name: String, content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
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
