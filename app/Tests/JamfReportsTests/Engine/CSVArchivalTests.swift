import Foundation
import XCTest
@testable import JamfReports

/// Tests for ReportEngine.archiveCurrentCSV — mirrors Python _archive_csv_snapshot.
final class CSVArchivalTests: XCTestCase {

    private var tmpDir: URL!
    private var historicalDir: URL!
    private var engine: ReportEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        historicalDir = tmpDir.appendingPathComponent("snapshots", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let config = ReportConfig()
        let dataDir = tmpDir.appendingPathComponent("data", isDirectory: true)
        engine = ReportEngine(config: config, dataDir: dataDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testArchiveCopiesFileWithTimestampSuffix() throws {
        let csvContent = "Computer Name,Serial Number\nMac-001,ABC123"
        let csvURL = tmpDir.appendingPathComponent("export.csv")
        try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)

        engine.archiveCurrentCSV(csvURL: csvURL, historicalDir: historicalDir)

        let files = try FileManager.default.contentsOfDirectory(atPath: historicalDir.path)
        XCTAssertEqual(files.count, 1, "Exactly one file should be archived")
        let archived = files[0]
        XCTAssertTrue(archived.hasPrefix("computers_"), "Archived file must start with computers_")
        XCTAssertTrue(archived.hasSuffix(".csv"), "Archived file must end with .csv")

        // Verify content is preserved.
        let archivedURL = historicalDir.appendingPathComponent(archived)
        let content = try String(contentsOf: archivedURL, encoding: .utf8)
        XCTAssertEqual(content, csvContent)
    }

    func testArchiveCreatesHistoricalDirIfMissing() throws {
        let csvURL = tmpDir.appendingPathComponent("export.csv")
        try "data".write(to: csvURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historicalDir.path))
        engine.archiveCurrentCSV(csvURL: csvURL, historicalDir: historicalDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historicalDir.path))
    }

    func testArchiveFilenameContainsTimestampMatchingDatePattern() throws {
        let csvURL = tmpDir.appendingPathComponent("export.csv")
        try "data".write(to: csvURL, atomically: true, encoding: .utf8)
        engine.archiveCurrentCSV(csvURL: csvURL, historicalDir: historicalDir)

        let files = try FileManager.default.contentsOfDirectory(atPath: historicalDir.path)
        let name = files.first ?? ""
        // Pattern: computers_YYYY-MM-DD_HHmmss.csv
        let regex = try NSRegularExpression(pattern: #"^computers_\d{4}-\d{2}-\d{2}_\d{6}\.csv$"#)
        let matches = regex.numberOfMatches(
            in: name,
            range: NSRange(name.startIndex..., in: name)
        )
        XCTAssertEqual(matches, 1, "Filename must match computers_YYYY-MM-DD_HHmmss.csv, got: \(name)")
    }

    func testArchiveMissingSourceFileSilentlyFails() throws {
        let missingURL = tmpDir.appendingPathComponent("nonexistent.csv")
        // Should not throw — failures are logged and swallowed.
        engine.archiveCurrentCSV(csvURL: missingURL, historicalDir: historicalDir)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: historicalDir.path)) ?? []
        XCTAssertTrue(files.isEmpty, "No files should be created when source is missing")
    }
}
