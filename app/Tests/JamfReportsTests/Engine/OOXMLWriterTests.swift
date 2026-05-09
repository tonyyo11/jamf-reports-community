import Foundation
import XCTest
@testable import JamfReports

final class OOXMLWriterTests: XCTestCase {

    // MARK: - CellValue.safe sanitization

    func testSafeStripsC0ControlCharacters() {
        // Null byte, BEL, ESC — all should be stripped.
        let raw = "hello\u{00}world\u{07}end\u{1B}"
        let result = CellValue.safe(raw)
        guard case .string(let s) = result else {
            XCTFail("Expected .string, got \(result)")
            return
        }
        XCTAssertEqual(s, "helloworldend")
    }

    func testSafePreservesTabAndNewline() {
        let raw = "col1\tcol2\nrow2"
        let result = CellValue.safe(raw)
        guard case .string(let s) = result else {
            XCTFail("Expected .string")
            return
        }
        XCTAssertEqual(s, raw)
    }

    func testSafeEscapesFormulaInjectionEquals() {
        let raw = "=SUM(A1:A10)"
        guard case .string(let s) = CellValue.safe(raw) else {
            XCTFail(); return
        }
        XCTAssertTrue(s.hasPrefix("\t"), "Formula-injection cell should start with tab")
        XCTAssertTrue(s.contains("=SUM"))
    }

    func testSafeEscapesFormulaInjectionPlus() {
        guard case .string(let s) = CellValue.safe("+1234") else { XCTFail(); return }
        XCTAssertTrue(s.hasPrefix("\t"))
    }

    func testSafeEscapesFormulaInjectionAt() {
        guard case .string(let s) = CellValue.safe("@IMPORTRANGE") else { XCTFail(); return }
        XCTAssertTrue(s.hasPrefix("\t"))
    }

    func testSafeNilReturnsBlank() {
        guard case .blank = CellValue.safe(nil) else {
            XCTFail("nil should produce .blank")
            return
        }
    }

    func testSafeIntPassthrough() {
        guard case .int(let v) = CellValue.safe(42) else { XCTFail(); return }
        XCTAssertEqual(v, 42)
    }

    func testSafeDoubleTruncatesAt32000Characters() {
        let longString = String(repeating: "x", count: 40_000)
        guard case .string(let s) = CellValue.safe(longString) else { XCTFail(); return }
        XCTAssertLessThanOrEqual(s.count, 32_000)
    }

    // MARK: - Workbook write to URL

    func testWorkbookWritesValidZIPFile() throws {
        let workbook = Workbook()
        let ws = workbook.addSheet("Sheet1")
        ws.write("Hello", row: 0, col: 0)
        ws.write(99, row: 0, col: 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OOXMLWriterTest-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        try workbook.write(to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        // All XLSX files are ZIP files starting with the PK magic bytes.
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
    }

    func testWorkbookWithMultipleSheetsCreatesFile() throws {
        let workbook = Workbook()
        for i in 1...5 {
            let ws = workbook.addSheet("Sheet\(i)")
            ws.write("Row \(i)", row: 0, col: 0)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiSheet-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try workbook.write(to: url))
    }

    func testEmptyWorkbookStillWritesValidFile() throws {
        let workbook = Workbook()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Empty-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        try workbook.write(to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
    }
}
