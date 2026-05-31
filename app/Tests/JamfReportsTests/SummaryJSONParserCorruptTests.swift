import Foundation
import XCTest
@testable import JamfReports

/// v2.1.1 review item #10: SummaryJSONParser.parseDirectory used
/// `compactMap { try? parse }` which silently drops corrupt summary files.
/// The fix replaces it with do/catch + AppLogger.engine.warning so a trend
/// gap becomes diagnosable. These tests verify the parse-then-filter contract.
final class SummaryJSONParserCorruptTests: XCTestCase {

    // MARK: - Helpers

    @discardableResult
    private func writeSummaryJSON(date: String, totalDevices: Int, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("summary_\(date).json")
        let json = """
        {"date":"\(date)","totalDevices":\(totalDevices),"staleCount":0,"source":"jamf-cli"}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Tests

    func test_parseDirectory_returnsValidSummaries() throws {
        let dir = try makeDir()
        try writeSummaryJSON(date: "2026-04-01", totalDevices: 100, to: dir)
        try writeSummaryJSON(date: "2026-04-02", totalDevices: 105, to: dir)

        let summaries = SummaryJSONParser.parseDirectory(dir)
        XCTAssertEqual(summaries.count, 2)
    }

    func test_parseDirectory_skipsCorruptFile_returnsOnlyValid() throws {
        let dir = try makeDir()
        try writeSummaryJSON(date: "2026-04-01", totalDevices: 100, to: dir)

        // Write a corrupt file that looks like a summary but isn't valid JSON.
        let corrupt = dir.appendingPathComponent("summary_2026-04-02.json")
        try "NOT VALID JSON {{".write(to: corrupt, atomically: true, encoding: .utf8)

        let summaries = SummaryJSONParser.parseDirectory(dir)
        // The corrupt file is dropped; only the valid one is returned.
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.totalDevices, 100)
    }

    func test_parseDirectory_skipsNonSummaryFiles() throws {
        let dir = try makeDir()
        try writeSummaryJSON(date: "2026-04-01", totalDevices: 99, to: dir)

        // A valid JSON file that doesn't start with "summary_" must be ignored.
        let other = dir.appendingPathComponent("metadata.json")
        try "{\"foo\": 1}".write(to: other, atomically: true, encoding: .utf8)

        let summaries = SummaryJSONParser.parseDirectory(dir)
        XCTAssertEqual(summaries.count, 1)
    }

    func test_parseDirectory_emptyDir_returnsEmpty() throws {
        let dir = try makeDir()
        XCTAssertTrue(SummaryJSONParser.parseDirectory(dir).isEmpty)
    }

    func test_parseDirectory_allCorrupt_returnsEmpty() throws {
        let dir = try makeDir()
        let corrupt1 = dir.appendingPathComponent("summary_2026-04-01.json")
        let corrupt2 = dir.appendingPathComponent("summary_2026-04-02.json")
        try "BAD".write(to: corrupt1, atomically: true, encoding: .utf8)
        try "ALSO BAD".write(to: corrupt2, atomically: true, encoding: .utf8)

        let summaries = SummaryJSONParser.parseDirectory(dir)
        XCTAssertTrue(summaries.isEmpty)
    }

    func test_parse_singleCorruptURL_throws() throws {
        let dir = try makeDir()
        let corrupt = dir.appendingPathComponent("summary_2026-04-01.json")
        try "NOT JSON".write(to: corrupt, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SummaryJSONParser.parse(corrupt))
    }
}
