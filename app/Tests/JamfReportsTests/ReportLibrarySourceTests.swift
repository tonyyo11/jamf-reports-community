import Foundation
import XCTest
@testable import JamfReports

/// The Generated list's Type column says what a file is, and names a schedule only when a
/// schedule's status file names that exact file. The Devices column gives no count once a
/// later collect has rewritten the day's summary.
final class ReportLibrarySourceTests: XCTestCase {

    private let profile = "typecheck"
    private let fm = FileManager.default

    // MARK: - Kind from the file name

    func testKindComesFromTheNameTheWritersGive() {
        let cases: [(String, String)] = [
            ("report_typecheck_2026-10-05_132238.xlsx", "Workbook"),
            ("report_typecheck_2026-10-05_132238.html", "HTML report"),
            ("jamf_report_typecheck_2026-10-05_111523.pdf", "PDF report"),
            ("jamf_report_typecheck_2026-10-04_122132.html", "HTML report"),
            ("school-report_typecheck_2026-10-05_091500.xlsx", "Jamf School workbook"),
            ("inventory_typecheck_2026-10-05_151526.csv", "Inventory CSV"),
            ("automation_inventory_typecheck_2026-04-25_060155.csv", "Inventory CSV"),
            ("patch-compliance-typecheck-2026-10-04_135800.csv", "Patch compliance CSV"),
            ("audit-findings-typecheck-2026-10-04_135800.csv", "Audit findings CSV"),
            ("outreach-stale-devices-typecheck-2026-10-04_135800.csv", "Offline outreach CSV"),
            ("devices-typecheck-2026-10-04_135800.csv", "Devices CSV"),
            ("period-report-20260827-20260903-typecheck-2026-09-03_174158.xlsx", "Period report"),
            ("notes.csv", "CSV export"),
            ("notes.txt", "Report file"),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(ReportLibrary.kindLabel(forFilename: name), kind, name)
        }
    }

    func testNoSchedulePhraseIsInventedFromAName() {
        for name in ["jamf_report_typecheck_2026-10-04_122132.html",
                     "patch-compliance-typecheck-2026-10-04_135800.csv"] {
            let label = ReportLibrary.sourceLabel(forFilename: name, schedule: nil)
            XCTAssertFalse(label.contains("Weekly") || label.contains("Monthly"), label)
        }
    }

    func testAKnownScheduleFollowsTheKind() {
        XCTAssertEqual(
            ReportLibrary.sourceLabel(
                forFilename: "report_typecheck_2026-10-05_132238.xlsx",
                schedule: "Managed Reports"),
            "Workbook \u{00B7} Managed Reports")
        XCTAssertEqual(
            ReportLibrary.sourceLabel(forFilename: "report_a_2026-10-05_132238.xlsx", schedule: ""),
            "Workbook")
    }

    // MARK: - Schedules proven by status files

    func testStatusFilesNameTheFilesTheirLastRunWrote() throws {
        let dir = try makeTemp()
        let label = "\(LaunchAgentWriter.labelPrefix).multi.managed-reports"
        let status = dir.appendingPathComponent("\(label)_status.json")
        try writeJSON([
            "label": label,
            "xlsx_report_path": "/anywhere/report_typecheck_2026-10-05_132238.xlsx",
            "html_report_path": "/anywhere/report_typecheck_2026-10-05_132238.html",
            "exit_code": 0,
        ], to: status)
        let noArtifacts = dir.appendingPathComponent("collect_status.json")
        try writeJSON(["label": "\(LaunchAgentWriter.labelPrefix).manual-collect"], to: noArtifacts)
        let broken = dir.appendingPathComponent("broken_status.json")
        try Data("not json".utf8).write(to: broken)

        let named = ReportLibrary.scheduledFiles(statusFiles: [status, noArtifacts, broken])

        XCTAssertEqual(named, [
            "report_typecheck_2026-10-05_132238.xlsx": "Managed Reports",
            "report_typecheck_2026-10-05_132238.html": "Managed Reports",
        ])
    }

    func testTheListNamesAScheduleOnlyForTheFileItsStatusFileNames() throws {
        let workspace = try makeWorkspace()
        let reports = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        let proven = "report_\(profile)_2026-10-05_132238.xlsx"
        let other = "report_\(profile)_2026-10-05_090000.xlsx"
        let manualHTML = "jamf_report_\(profile)_2026-10-05_111520.html"
        for name in [proven, other, manualHTML] {
            try Data("x".utf8).write(to: reports.appendingPathComponent(name))
        }
        let automation = workspace.appendingPathComponent("automation", isDirectory: true)
        try fm.createDirectory(at: automation, withIntermediateDirectories: true)
        let label = "\(LaunchAgentWriter.labelPrefix).multi.managed-reports"
        try writeJSON(
            ["label": label, "xlsx_report_path": "/elsewhere/\(proven)"],
            to: automation.appendingPathComponent("\(label)_status.json"))

        let listed = ReportLibrary().list(profile: profile)
        let sources = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0.source) })

        XCTAssertEqual(sources[proven], "Workbook \u{00B7} Managed Reports")
        XCTAssertEqual(sources[other], "Workbook")
        XCTAssertEqual(sources[manualHTML], "HTML report")
    }

    // MARK: - Devices

    func testASummaryRewrittenAfterTheWorkbookGivesNoCount() throws {
        let dir = try makeTemp()
        let summary = dir.appendingPathComponent("summary_2026-10-05.json")
        try writeJSON(["totalDevices": 664], to: summary)
        let report = URL(fileURLWithPath: "report_\(profile)_2026-10-05_132238.xlsx")
        let generated = Date(timeIntervalSince1970: 1_790_000_000)
        let library = ReportLibrary()

        func count(summaryWrittenAt offset: TimeInterval) throws -> Int? {
            let stamp = generated.addingTimeInterval(offset)
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: summary.path)
            return library.deviceCount(
                forReportURL: report, summariesDir: dir, reportModified: generated)
        }

        XCTAssertEqual(try count(summaryWrittenAt: -3_600), 664, "written before the workbook")
        XCTAssertEqual(try count(summaryWrittenAt: 60), 664, "emitted by the same generate run")
        XCTAssertNil(try count(summaryWrittenAt: ReportLibrary.summaryGrace + 60),
                     "a later collect rewrote it")
        XCTAssertNil(try count(summaryWrittenAt: 2 * 3_600))
        XCTAssertEqual(
            library.deviceCount(forReportURL: report, summariesDir: dir), 664,
            "without a workbook time the lookup is as before")
    }

    // MARK: - Helpers

    private func makeTemp() throws -> URL {
        let dir = fm.temporaryDirectory
            .appendingPathComponent("ReportLibrarySource-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A workspace under the home folder (the temp folder resolves under /private, which the
    /// path rules refuse), hidden and removed at teardown.
    private func makeWorkspace() throws -> URL {
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("jrc-test-reportsource-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        return workspace.resolvingSymlinksInPath().standardizedFileURL
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
