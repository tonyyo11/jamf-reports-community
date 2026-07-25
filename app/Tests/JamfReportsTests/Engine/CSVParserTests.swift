import Foundation
import XCTest
@testable import JamfReports

final class CSVParserTests: XCTestCase {

    // MARK: - Basic parsing

    func testSimpleCSV() throws {
        let csv = "Name,Age\nAlice,30\nBob,25"
        let (cols, rows) = try CSVParser.parse(Data(csv.utf8))

        XCTAssertEqual(cols, ["Name", "Age"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["Name"], "Alice")
        XCTAssertEqual(rows[0]["Age"], "30")
        XCTAssertEqual(rows[1]["Name"], "Bob")
    }

    func testQuotedFieldsWithCommasInside() throws {
        let csv = "Name,Location\n\"Smith, John\",\"New York, NY\""
        let (_, rows) = try CSVParser.parse(Data(csv.utf8))

        XCTAssertEqual(rows[0]["Name"], "Smith, John")
        XCTAssertEqual(rows[0]["Location"], "New York, NY")
    }

    func testEscapedQuoteInsideQuotedField() throws {
        let csv = "Name,Note\n\"She said \"\"hello\"\"\",ok"
        let (_, rows) = try CSVParser.parse(Data(csv.utf8))

        XCTAssertEqual(rows[0]["Name"], "She said \"hello\"")
    }

    func testUTF8BOMIsStripped() throws {
        // UTF-8 BOM: 0xEF 0xBB 0xBF
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "Name,Value\nTest,1".utf8)
        let (cols, _) = try CSVParser.parse(data)

        // BOM should not appear in the first column name.
        XCTAssertEqual(cols.first, "Name")
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try CSVParser.parse(Data()))
    }

    func testHeaderOnlyNoDataRows() throws {
        let csv = "Name,Age\n"
        let (cols, rows) = try CSVParser.parse(Data(csv.utf8))

        XCTAssertEqual(cols, ["Name", "Age"])
        XCTAssertTrue(rows.isEmpty)
    }

    func testTrailingNewlineIgnored() throws {
        let csv = "A,B\n1,2\n"
        let (_, rows) = try CSVParser.parse(Data(csv.utf8))
        XCTAssertEqual(rows.count, 1)
    }

    func testRowWithFewerColumnsThanHeader() throws {
        let csv = "A,B,C\n1,2"
        let (_, rows) = try CSVParser.parse(Data(csv.utf8))

        // Short row: missing column C should default to empty string.
        XCTAssertEqual(rows[0]["A"], "1")
        XCTAssertEqual(rows[0]["B"], "2")
        XCTAssertEqual(rows[0]["C"], "")
    }

    // MARK: - Dummy fixture CSV

    func testDummyFixtureCSVParsesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("csv/dummy_all_macs.csv")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available: \(fixtureURL.lastPathComponent)")
        }

        let data = try Data(contentsOf: fixtureURL)
        let (cols, rows) = try CSVParser.parse(data)

        XCTAssertFalse(cols.isEmpty)
        XCTAssertFalse(rows.isEmpty)
        // "Computer Name" must be present — it's mapped by default config.
        XCTAssertTrue(cols.contains("Computer Name"))
    }

    // MARK: - Helper

    private var fixturesDir: URL { TestFixtures.root }
}
