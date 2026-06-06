import Foundation
import XCTest
@testable import JamfReports

/// Tests for ReportEngine.archiveOldRuns — mirrors Python _archive_old_output_runs.
final class ArchiveRotationTests: XCTestCase {

    private var tmpDir: URL!
    private var outputDir: URL!
    private var archiveDir: URL!
    private var engine: ReportEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        outputDir = tmpDir.appendingPathComponent("reports", isDirectory: true)
        archiveDir = tmpDir.appendingPathComponent("archive", isDirectory: true)
        try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let config = ReportConfig()
        let dataDir = tmpDir.appendingPathComponent("data", isDirectory: true)
        engine = ReportEngine(config: config, dataDir: dataDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Date format parsing

    func testParsesYYYY_MM_DD_format() throws {
        let files = [
            "report_2024-01-01.xlsx",
            "report_2024-01-02.xlsx",
            "report_2024-01-03.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains("report_2024-01-03.xlsx"))
        XCTAssertTrue(remaining.contains("report_2024-01-02.xlsx"))
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived, ["report_2024-01-01.xlsx"])
    }

    func testParsesYYYYMMDD_format() throws {
        let files = [
            "report_20240101.xlsx",
            "report_20240102.xlsx",
            "report_20240103.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains("report_20240103.xlsx"))
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived, ["report_20240101.xlsx"])
    }

    func testParsesYYYY_MM_DD_HHMMSS_format() throws {
        let files = [
            "report_2024-01-01_100000.xlsx",
            "report_2024-01-01_110000.xlsx",
            "report_2024-01-01_120000.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains("report_2024-01-01_120000.xlsx"))
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived, ["report_2024-01-01_100000.xlsx"])
    }

    func testParsesYYYY_MM_DDTHHMMSS_format() throws {
        let files = [
            "report_2024-01-01T100000.xlsx",
            "report_2024-01-01T110000.xlsx",
            "report_2024-01-01T120000.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2)
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived.count, 1)
    }

    /// Jamf export default: underscores between hour, minute, second components.
    /// `computers_2024-01-01T10_00_00.xlsx` must parse to the same instant as
    /// `computers_2024-01-01T100000.xlsx`.
    func testParsesYYYY_MM_DDTHH_MM_SS_format() throws {
        let files = [
            "report_2024-01-01T10_00_00.xlsx",
            "report_2024-01-01T11_00_00.xlsx",
            "report_2024-01-01T12_00_00.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains("report_2024-01-01T12_00_00.xlsx"))
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived, ["report_2024-01-01T10_00_00.xlsx"])
    }

    /// Hyphen-separated time component (`YYYY-MM-DDTHH-MM-SS`) used by some
    /// exporter versions; must sort correctly against other patterns.
    func testParsesYYYY_MM_DDTHH_minus_MM_minus_SS_format() throws {
        let files = [
            "report_2024-06-15T08-00-00.xlsx",
            "report_2024-06-15T09-30-00.xlsx",
            "report_2024-06-15T10-45-00.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains("report_2024-06-15T10-45-00.xlsx"))
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived, ["report_2024-06-15T08-00-00.xlsx"])
    }

    // MARK: - keep=0: all files archived

    func testKeepZeroArchivesAll() throws {
        try createFiles(names: ["report_2024-01-01.xlsx", "report_2024-01-02.xlsx"], in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 0)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 0)
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived.count, 2)
    }

    // MARK: - keep=1: only newest retained

    func testKeepOneRetainsNewest() throws {
        let files = ["report_2024-06-01.xlsx", "report_2024-06-02.xlsx", "report_2024-06-03.xlsx"]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 1)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining, ["report_2024-06-03.xlsx"])
    }

    // MARK: - Under threshold: nothing archived

    func testBelowKeepThresholdNothingMoved() throws {
        try createFiles(names: ["report_2024-01-01.xlsx"], in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 5)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining, ["report_2024-01-01.xlsx"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.path))
    }

    // MARK: - Missing archive dir is created

    func testArchiveDirCreatedIfMissing() throws {
        try createFiles(names: ["r_2024-01-01.xlsx", "r_2024-01-02.xlsx"], in: outputDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.path))
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "r", keep: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveDir.path))
    }

    // MARK: - Sidecar archival (Fix 3)

    /// When an xlsx is archived its sha256 and manifest.txt sidecars must
    /// move with it. No orphaned sidecars should remain in the source dir.
    func testSidecarsArchivedAlongsideXLSX() throws {
        let files = [
            "report_2024-01-01.xlsx",
            "report_2024-01-02.xlsx",
            "report_2024-01-03.xlsx",
        ]
        try createFiles(names: files, in: outputDir)
        // Write .sha256 and .manifest.txt sidecars for each workbook.
        for name in files {
            let base = outputDir.appendingPathComponent(name)
            try "sha256content".write(
                to: base.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
            try "manifestcontent".write(
                to: base.appendingPathExtension("manifest.txt"), atomically: true, encoding: .utf8)
        }

        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)

        // The oldest run (2024-01-01) is archived.
        let srcContents = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
        let archContents = try FileManager.default.contentsOfDirectory(atPath: archiveDir.path)

        // No sha256 or manifest.txt for the archived run should remain in the source dir.
        XCTAssertFalse(
            srcContents.contains("report_2024-01-01.xlsx.sha256"),
            "Orphaned .sha256 must not remain in source dir"
        )
        XCTAssertFalse(
            srcContents.contains("report_2024-01-01.xlsx.manifest.txt"),
            "Orphaned .manifest.txt must not remain in source dir"
        )

        // Sidecars for the archived workbook must exist in the archive dir.
        XCTAssertTrue(
            archContents.contains("report_2024-01-01.xlsx.sha256"),
            ".sha256 sidecar must be in the archive dir"
        )
        XCTAssertTrue(
            archContents.contains("report_2024-01-01.xlsx.manifest.txt"),
            ".manifest.txt sidecar must be in the archive dir"
        )

        // Sidecars for retained workbooks must still be in the source dir.
        XCTAssertTrue(
            srcContents.contains("report_2024-01-02.xlsx.sha256"),
            ".sha256 sidecar for a kept workbook must remain in source dir"
        )
        XCTAssertTrue(
            srcContents.contains("report_2024-01-03.xlsx.sha256"),
            ".sha256 sidecar for a kept workbook must remain in source dir"
        )
    }

    /// Sidecars are optional: a workbook without sidecars archives cleanly.
    func testArchivingWorkbookWithoutSidecarsSucceeds() throws {
        let files = ["report_2024-01-01.xlsx", "report_2024-01-02.xlsx", "report_2024-01-03.xlsx"]
        try createFiles(names: files, in: outputDir)
        // No sidecars written.
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: archiveDir, stem: "report", keep: 2)
        let remaining = try xlsxNames(in: outputDir)
        XCTAssertEqual(remaining.count, 2, "Two workbooks should be retained")
        let archived = try xlsxNames(in: archiveDir)
        XCTAssertEqual(archived.count, 1, "One workbook should be in the archive")
    }

    // MARK: - Helpers

    private func createFiles(names: [String], in dir: URL) throws {
        for name in names {
            let url = dir.appendingPathComponent(name)
            try "placeholder".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func xlsxNames(in dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".xlsx") }
            .sorted()
    }
}
