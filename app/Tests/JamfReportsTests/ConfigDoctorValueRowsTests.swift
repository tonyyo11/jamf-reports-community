import Foundation
import XCTest
@testable import JamfReports

/// Values the app replaced, clamped or ignored are stated by the Config Doctor, and the two
/// value-reading changes that go with them.
final class ConfigDoctorValueRowsTests: XCTestCase {

    // MARK: - notify.detail fails toward sending less

    func testAnUnrecognisedNotifyDetailResolvesToMinimal() throws {
        for typed in ["verbose", "", "ful", "everything"] {
            let notify = try XCTUnwrap(
                try ConfigLoader.loadFromString("notify:\n  detail: \"\(typed)\"\n").notify)
            XCTAssertEqual(notify.resolvedDetail, .minimal,
                           "\"\(typed)\" is neither full nor minimal, so it must send less")
        }
    }

    func testNotifyDetailIsReadCaseInsensitivelyAndAbsentStaysFull() throws {
        let upper = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  detail: MINIMAL\n").notify)
        XCTAssertEqual(upper.resolvedDetail, .minimal)
        let mixed = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  detail: Full\n").notify)
        XCTAssertEqual(mixed.resolvedDetail, .full)
        let absent = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  enabled: false\n").notify)
        XCTAssertEqual(absent.resolvedDetail, .full, "no value typed: the documented default")
    }

    // MARK: - output.keep_latest_runs below 1 is 1

    func testAKeepLatestRunsBelowOneIsTreatedAsOne() throws {
        for typed in [0, -1, -50] {
            let output = try XCTUnwrap(
                try ConfigLoader.loadFromString("output:\n  keep_latest_runs: \(typed)\n").output)
            XCTAssertEqual(output.resolvedKeepLatestRuns, 1, "\(typed) must keep the newest run")
        }
        let five = try XCTUnwrap(
            try ConfigLoader.loadFromString("output:\n  keep_latest_runs: 5\n").output)
        XCTAssertEqual(five.resolvedKeepLatestRuns, 5)
        XCTAssertEqual(OutputConfig().resolvedKeepLatestRuns, 10, "absent: the documented default")
    }

    /// `generate` hands `resolvedKeepLatestRuns` to `archiveOldRuns` right after it writes the
    /// workbook, so a resolved 0 moved the report it had just written into the archive.
    func testKeepLatestRunsZeroLeavesTheReportJustWritten() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-keep-\(UUID().uuidString)", isDirectory: true)
        let reports = tmp.appendingPathComponent("reports", isDirectory: true)
        let archive = tmp.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in ["report_2026-10-01_080000.xlsx", "report_2026-10-02_080000.xlsx"] {
            try Data().write(to: reports.appendingPathComponent(name))
        }
        let config = try ConfigLoader.loadFromString("output:\n  keep_latest_runs: 0\n")
        let keep = try XCTUnwrap(config.output).resolvedKeepLatestRuns

        ReportEngine(config: config, dataDir: tmp).archiveOldRuns(
            outputDir: reports, archiveDir: archive, stem: "report", keep: keep)

        let left = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        XCTAssertEqual(left, ["report_2026-10-02_080000.xlsx"],
                       "the newest run, the one just written, stays in the reports folder")
    }
}
