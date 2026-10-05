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

    // MARK: - Profiles sharing an output folder

    /// `acme`'s rotation must neither count nor move the workbooks of a profile whose name
    /// starts with the same text, even when those are older than every `acme` run.
    func testRotationLeavesProfilesSharingAPrefixAlone() throws {
        let acme = [
            "report_acme_2024-01-01_100000.xlsx",
            "report_acme_2024-01-02_100000.xlsx",
            "report_acme_2024-01-03_100000.xlsx",
        ]
        let others = [
            "report_acme-prod_2023-12-01_100000.xlsx",
            "report_acme-prod_2023-12-02_100000.xlsx",
            "report_acme_2_2023-12-03_100000.xlsx",
        ]
        try createFiles(names: acme + others, in: outputDir)
        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 2
        )
        XCTAssertEqual(try xlsxNames(in: archiveDir), ["report_acme_2024-01-01_100000.xlsx"])
        XCTAssertEqual(try xlsxNames(in: outputDir), (acme.dropFirst() + others).sorted())
    }

    /// With `timestamp_outputs: false` the workbook is the stem alone; it is still a run.
    func testUntimestampedWorkbookCountsAsARun() throws {
        try createFiles(
            names: ["report_acme.xlsx", "report_acme_2024-01-01_100000.xlsx"], in: outputDir
        )
        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 1
        )
        XCTAssertEqual(try xlsxNames(in: archiveDir), ["report_acme_2024-01-01_100000.xlsx"])
    }

    // MARK: - Companion HTML (html.with_workbook)

    /// A run is the workbook. Its companion HTML and the HTML's manifest go with it, and the
    /// kept runs keep theirs.
    func testAWorkbooksCompanionHTMLAndItsManifestRotateWithIt() throws {
        let runs = ["report_acme_2024-01-01_100000", "report_acme_2024-01-02_100000",
                    "report_acme_2024-01-03_100000"]
        for run in runs {
            try createFiles(names: ["\(run).xlsx", "\(run).xlsx.sha256", "\(run).html",
                                    "\(run).html.manifest.txt"], in: outputDir)
        }
        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 2)

        XCTAssertEqual(try names(in: archiveDir), [
            "\(runs[0]).html", "\(runs[0]).html.manifest.txt", "\(runs[0]).xlsx",
            "\(runs[0]).xlsx.sha256",
        ])
        XCTAssertEqual(try names(in: outputDir).filter { $0.hasPrefix(runs[0]) }, [])
        for run in runs.dropFirst() {
            XCTAssertEqual(try names(in: outputDir).filter { $0.hasPrefix(run) }.count, 4, run)
        }
    }

    /// `keep` counts runs: with two workbooks and their two HTML reports, keeping two keeps both.
    func testKeepCountsRunsNotFiles() throws {
        let runs = ["report_acme_2024-01-01_100000", "report_acme_2024-01-02_100000"]
        for run in runs { try createFiles(names: ["\(run).xlsx", "\(run).html"], in: outputDir) }
        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 2)
        XCTAssertEqual(try names(in: archiveDir), [])
        XCTAssertEqual(try names(in: outputDir).count, 4)

        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 1)
        XCTAssertEqual(try names(in: archiveDir), ["\(runs[0]).html", "\(runs[0]).xlsx"])
        XCTAssertEqual(try names(in: outputDir), ["\(runs[1]).html", "\(runs[1]).xlsx"])
    }

    /// The Generate sheet's HTML format and `jamf-reports html` output have no workbook beside
    /// them, so rotation leaves them where they are, however old.
    func testAStandaloneHTMLIsNeverMoved() throws {
        let standalone = ["jamf_report_acme_2023-01-01_100000.html",
                          "jamf_report_acme_2023-01-01_100000.html.manifest.txt",
                          "report_acme_2023-06-01_100000.html"]
        try createFiles(names: standalone + [
            "report_acme_2024-01-01_100000.xlsx", "report_acme_2024-01-01_100000.html",
            "report_acme_2024-01-02_100000.xlsx",
        ], in: outputDir)
        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 1)

        XCTAssertEqual(try names(in: archiveDir), [
            "report_acme_2024-01-01_100000.html", "report_acme_2024-01-01_100000.xlsx",
        ])
        XCTAssertEqual(try names(in: outputDir), standalone.sorted() + [
            "report_acme_2024-01-02_100000.xlsx",
        ])
    }

    /// With rotation switched off nothing moves, and an HTML never makes a run on its own.
    func testHTMLAloneIsNotARunToKeepOrArchive() throws {
        try createFiles(names: ["report_acme_2024-01-01_100000.html",
                                "report_acme_2024-01-02_100000.html"], in: outputDir)
        engine.archiveOldRuns(
            outputDir: outputDir, archiveDir: archiveDir, stem: "report_acme", keep: 0)
        XCTAssertEqual(try names(in: archiveDir), [])
        XCTAssertEqual(try names(in: outputDir).count, 2)
    }

    func testIsRunAcceptsEachTimestampFormatOnly() {
        let runs = [
            "report_acme", "report_acme_20240101", "report_acme_2024-01-01",
            "report_acme_2024-01-01_100000", "report_acme_2024-01-01T100000",
            "report_acme_2024-01-01T10_00_00", "report_acme_2024-01-01T10-00-00",
        ]
        for name in runs {
            XCTAssertTrue(ReportEngine.isRun(named: name, of: "report_acme"), name)
        }
        let notRuns = [
            "report_acme-prod_2024-01-01_100000", "report_acme_2_2024-01-01_100000",
            "report_acme_dev", "report_acme_2024-01-01_100000 2", "report_acm",
            "jamf_report_acme_2024-01-01_100000",
        ]
        for name in notRuns {
            XCTAssertFalse(ReportEngine.isRun(named: name, of: "report_acme"), name)
        }
    }

    // MARK: - Archive folder is the output folder

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// `output.archive_dir` set to the output folder made every move delete the report it
    /// was moving: the destination was the file itself.
    func testRotationIntoTheOutputFolderKeepsEveryFileAndWarnsOnce() throws {
        let files = ["report_2024-01-01.xlsx", "report_2024-01-02.xlsx", "report_2024-01-03.xlsx"]
        try createFiles(names: files, in: outputDir)
        let alias = tmpDir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outputDir)
        let spellings = [outputDir!, URL(fileURLWithPath: outputDir.path + "/"), alias,
                         outputDir.appendingPathComponent("../reports")]
        for archive in spellings {
            let lines = Lines()
            engine.archiveOldRuns(
                outputDir: outputDir, archiveDir: archive, stem: "report", keep: 1,
                onLine: { lines.add($0.text) })
            XCTAssertEqual(try names(in: outputDir), files, archive.path)
            XCTAssertEqual(lines.all.count, 1, "\(archive.path): \(lines.all)")
            XCTAssertTrue(lines.all.first?.hasPrefix("[warn]") == true, "\(lines.all)")
        }
    }

    /// APFS folds case, so a differently cased archive_dir is the output folder too.
    func testRotationIntoTheOutputFolderSpelledInAnotherCaseKeepsEveryFile() throws {
        let other = tmpDir.appendingPathComponent("REPORTS", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: other.path),
                          "case-sensitive volume")
        let files = ["report_2024-01-01.xlsx", "report_2024-01-02.xlsx"]
        try createFiles(names: files, in: outputDir)
        engine.archiveOldRuns(outputDir: outputDir, archiveDir: other, stem: "report", keep: 1)
        XCTAssertEqual(try names(in: outputDir), files)
    }

    func testMoveToArchiveRefusesADestinationThatIsTheSourceFile() throws {
        try createFiles(names: ["report_2024-01-01.xlsx"], in: outputDir)
        let file = outputDir.appendingPathComponent("report_2024-01-01.xlsx")
        let lines = Lines()
        let moved = ReportEngine.moveToArchive(
            file, archiveDir: outputDir, onLine: { lines.add($0.text) })
        XCTAssertFalse(moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(lines.all.count, 1)
    }

    // MARK: - Helpers

    private func createFiles(names: [String], in dir: URL) throws {
        for name in names {
            let url = dir.appendingPathComponent(name)
            try "placeholder".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func names(in dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func xlsxNames(in dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".xlsx") }
            .sorted()
    }
}
