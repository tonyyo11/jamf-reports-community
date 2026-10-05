import Foundation
import XCTest
@testable import JamfReports

/// Swift reads "\r\n" as ONE Character that equals neither "\r" nor "\n", so a parser that
/// walks Characters saw a CSV saved by Excel or Windows as a single row with no records, and
/// the csv-assisted report wrote empty CSV sheets with exit 0. Both CSV parsers, one test
/// per line-ending shape.
final class CSVLineEndingTests: XCTestCase {

    private let bom = "\u{FEFF}"

    // MARK: - CSVParser (report engine)

    private func parsed(_ text: String) throws -> ([String], [CSVRow]) {
        try CSVParser.parse(Data(text.utf8))
    }

    func testEngineParserReadsEveryLineEnding() throws {
        for (name, eol) in [("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")] {
            let (columns, records) = try parsed("a,b\(eol)1,2\(eol)3,4\(eol)")
            XCTAssertEqual(columns, ["a", "b"], name)
            XCTAssertEqual(records, [["a": "1", "b": "2"], ["a": "3", "b": "4"]], name)
        }
    }

    func testEngineParserReadsAFileWithNoFinalLineEnding() throws {
        let (_, records) = try parsed("a,b\r\n1,2\r\n3,4")
        XCTAssertEqual(records.count, 2)
    }

    func testEngineParserKeepsACRLFInsideAQuotedFieldAsALineBreak() throws {
        let (_, records) = try parsed("a,b\r\n\"x\r\ny\",2\r\n\"p\nq\",\"r\rs\"\r\n")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["a"], "x\r\ny")
        XCTAssertEqual(records[0]["b"], "2")
        XCTAssertEqual(records[1]["a"], "p\nq")
        XCTAssertEqual(records[1]["b"], "r\rs")
    }

    func testEngineParserReadsABOMBeforeCRLF() throws {
        let (columns, records) = try parsed(bom + "a,b\r\n1,2\r\n")
        XCTAssertEqual(columns, ["a", "b"])
        XCTAssertEqual(records, [["a": "1", "b": "2"]])
    }

    func testEngineParserSplitsOnACommaFollowedByACombiningMark() throws {
        // A combining mark fuses with the comma into one Character that is not ",".
        let (columns, _) = try parsed("a,\u{0301}b\n1,2\n")
        XCTAssertEqual(columns.count, 2)
    }

    func testEngineHeaderReaderStopsAtTheFirstLineEnding() throws {
        for eol in ["\n", "\r\n", "\r"] {
            let header = CSVParser.parseHeader(Data(("a,b" + eol + "1,2" + eol).utf8))
            XCTAssertEqual(header, ["a", "b"])
        }
        XCTAssertEqual(CSVParser.parseHeader(Data((bom + "a,b\r\n1,2\r\n").utf8)), ["a", "b"])
    }

    // MARK: - DeviceInventoryService (Devices screen)

    private func devices(fromCSV text: String) throws -> [DeviceInventoryRecord] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-csv-eol-\(UUID().uuidString)", isDirectory: true)
        let profile = "eol"
        let inbox = root.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        // No date in the name, so the age bound reads the file as current.
        try text.write(to: inbox.appendingPathComponent("inventory.csv"),
                       atomically: true, encoding: .utf8)
        return DeviceInventoryService.load(profile: profile, demoMode: false).devices
            .sorted { $0.name < $1.name }
    }

    func testDevicesReadsEveryLineEnding() throws {
        for (name, eol) in [("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")] {
            let text = "Computer Name,Serial Number,Department\(eol)"
                + "Mac-1,SER1,Eng\(eol)Mac-2,SER2,Ops\(eol)"
            let found = try devices(fromCSV: text)
            XCTAssertEqual(found.map(\.name), ["Mac-1", "Mac-2"], name)
            XCTAssertEqual(found.map(\.serial), ["SER1", "SER2"], name)
            XCTAssertEqual(found.map(\.department), ["Eng", "Ops"], name)
        }
    }

    func testDevicesKeepsACRLFInsideAQuotedFieldAndReadsABOM() throws {
        let text = bom + "Computer Name,Serial Number,Department\r\n"
            + "Mac-1,SER1,\"Eng\r\nOps\"\r\nMac-2,SER2,Ops\r\n"
        let found = try devices(fromCSV: text)
        XCTAssertEqual(found.map(\.name), ["Mac-1", "Mac-2"])
        XCTAssertEqual(found.first?.department, "Eng\r\nOps")
    }

    func testDevicesSplitsOnACommaFollowedByACombiningMark() throws {
        let text = "Computer Name,Serial Number,Department\n"
            + "Mac-1,\u{0301}SER1,Eng\n"
        let found = try devices(fromCSV: text)
        XCTAssertEqual(found.first?.department, "Eng")
    }
}
