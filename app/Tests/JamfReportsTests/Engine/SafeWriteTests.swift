import Foundation
import XCTest
@testable import JamfReports

/// Tests for formula-injection safety and value sanitization in CellValue.safe(),
/// mirroring the Python _safe_write contract exactly.
final class SafeWriteTests: XCTestCase {

    // MARK: - Formula injection prefixes

    func testEqualsSignPrefixGetsLeadingTab() {
        guard case .string(let s) = CellValue.safe("=SUM(A1:A10)") else {
            XCTFail("Expected .string"); return
        }
        XCTAssertTrue(s.hasPrefix("\t"), "= prefix must be escaped with leading tab")
        XCTAssertTrue(s.contains("=SUM"))
    }

    func testPlusPrefixGetsLeadingTab() {
        guard case .string(let s) = CellValue.safe("+1234") else {
            XCTFail("Expected .string"); return
        }
        XCTAssertTrue(s.hasPrefix("\t"))
    }

    func testMinusPrefixGetsLeadingTab() {
        guard case .string(let s) = CellValue.safe("-1234") else {
            XCTFail("Expected .string"); return
        }
        XCTAssertTrue(s.hasPrefix("\t"))
    }

    func testAtPrefixGetsLeadingTab() {
        guard case .string(let s) = CellValue.safe("@IMPORTRANGE(A1)") else {
            XCTFail("Expected .string"); return
        }
        XCTAssertTrue(s.hasPrefix("\t"))
    }

    func testNormalStringPassesThrough() {
        guard case .string(let s) = CellValue.safe("MacBook Pro") else {
            XCTFail("Expected .string"); return
        }
        XCTAssertEqual(s, "MacBook Pro")
    }

    func testEmptyStringPassesThrough() {
        guard case .string(let s) = CellValue.safe("") else {
            XCTFail("Expected .string"); return
        }
        XCTAssertEqual(s, "")
    }

    // MARK: - None / nil handling

    func testNilReturnsBlank() {
        guard case .blank = CellValue.safe(nil) else {
            XCTFail("Expected .blank for nil input"); return
        }
    }

    // MARK: - NaN / Inf doubles

    func testNaNDoubleReturnsZeroInt() {
        guard case .int(let i) = CellValue.safe(Double.nan) else {
            XCTFail("Expected .int for NaN"); return
        }
        XCTAssertEqual(i, 0)
    }

    func testInfiniteDoubleReturnsZeroInt() {
        guard case .int(let i) = CellValue.safe(Double.infinity) else {
            XCTFail("Expected .int for +Inf"); return
        }
        XCTAssertEqual(i, 0)
    }

    func testNegativeInfiniteDoubleReturnsZeroInt() {
        guard case .int(let i) = CellValue.safe(-Double.infinity) else {
            XCTFail("Expected .int for -Inf"); return
        }
        XCTAssertEqual(i, 0)
    }

    func testFiniteDoublePassesThrough() {
        guard case .double(let d) = CellValue.safe(42.5) else {
            XCTFail("Expected .double"); return
        }
        XCTAssertEqual(d, 42.5, accuracy: 0.001)
    }

    // MARK: - Control character stripping

    func testC0ControlCharsAreStripped() {
        // Null byte, BEL, ESC — must be removed.
        let raw = "hello\u{00}world\u{07}end\u{1B}"
        guard case .string(let s) = CellValue.safe(raw) else {
            XCTFail("Expected .string"); return
        }
        XCTAssertEqual(s, "helloworldend")
    }

    func testTabLFCRPreserved() {
        let raw = "col1\tcol2\nrow2\r\nrow3"
        guard case .string(let s) = CellValue.safe(raw) else {
            XCTFail("Expected .string"); return
        }
        XCTAssertEqual(s, raw)
    }

    func testC1ControlCharsAreStripped() {
        // U+0080 through U+009F are C1 controls and must be stripped.
        let raw = "abc\u{0085}def"  // U+0085 is NEL (Next Line), a C1 control
        guard case .string(let s) = CellValue.safe(raw) else {
            XCTFail("Expected .string"); return
        }
        XCTAssertEqual(s, "abcdef")
    }

    // MARK: - Worksheet.write routes through safe()

    func testWorksheetWriteRoutesUserDataThroughSafe() {
        let ws = Worksheet(name: "Test")
        // Write a formula-injection value — it must be stored as tab-prefixed string.
        ws.write("=EVIL()", row: 0, col: 0, format: .cell)
        let cell = ws.cells.first
        XCTAssertNotNil(cell)
        if case .string(let s) = cell?.value {
            XCTAssertTrue(s.hasPrefix("\t"), "User-supplied = must be escaped")
        } else {
            XCTFail("Cell value should be .string")
        }
    }
}
