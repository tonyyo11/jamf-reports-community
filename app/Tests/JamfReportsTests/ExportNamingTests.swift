import XCTest
@testable import JamfReports

/// ExportNaming is the single naming convention for user exports and engine
/// reports: `<kind>-<profile>-<yyyy-MM-dd_HHmmss>.<ext>`. Production surfaced
/// exports without timestamps (silent overwrite on re-export) and reports
/// without profile names (unattributable once moved between folders).
final class ExportNamingTests: XCTestCase {

    func testFilenameContainsKindProfileTimestampAndExtension() throws {
        let fixed = Date(timeIntervalSince1970: 1_790_000_000)
        let name = ExportNaming.filename(
            kind: "patch-compliance", profile: "prod", ext: "csv", now: fixed
        )
        let regex = try NSRegularExpression(
            pattern: #"^patch-compliance-prod-\d{4}-\d{2}-\d{2}_\d{6}\.csv$"#
        )
        let range = NSRange(name.startIndex..., in: name)
        XCTAssertNotNil(regex.firstMatch(in: name, range: range), "got '\(name)'")
    }

    func testEmptyProfileOmitsProfileSegment() throws {
        let name = ExportNaming.filename(kind: "devices", profile: "", ext: "csv")
        let regex = try NSRegularExpression(
            pattern: #"^devices-\d{4}-\d{2}-\d{2}_\d{6}\.csv$"#
        )
        let range = NSRange(name.startIndex..., in: name)
        XCTAssertNotNil(regex.firstMatch(in: name, range: range), "got '\(name)'")
    }

    func testTimestampsDifferAcrossSeconds() {
        let first = ExportNaming.filename(
            kind: "audit-findings", profile: "prod", ext: "csv",
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let second = ExportNaming.filename(
            kind: "audit-findings", profile: "prod", ext: "csv",
            now: Date(timeIntervalSince1970: 1_790_000_001)
        )
        XCTAssertNotEqual(first, second, "exports one second apart must not collide")
    }

    func testSanitizeStripsUnsafeCharacters() {
        XCTAssertEqual(ExportNaming.sanitize("Fleet Overview"), "Fleet-Overview")
        XCTAssertEqual(ExportNaming.sanitize("a/b\\c:d"), "a-b-c-d")
        XCTAssertEqual(ExportNaming.sanitize("..hidden"), "hidden")
        XCTAssertEqual(ExportNaming.sanitize("a---b"), "a-b")
        XCTAssertEqual(ExportNaming.sanitize(""), "")
    }

    func testTimestampFormatIsSortable() throws {
        let earlier = ExportNaming.timestamp(Date(timeIntervalSince1970: 1_790_000_000))
        let later = ExportNaming.timestamp(Date(timeIntervalSince1970: 1_790_086_400))
        XCTAssertLessThan(earlier, later, "lexicographic order must match chronological order")
    }
}

/// Engine report naming: profile must appear in the generated filename.
final class ReportNamingProfileTests: XCTestCase {

    /// The folder now comes from the profile's config.yaml, so a profile name must never reach
    /// the real workspaces folder.
    private func inEmptyWorkspacesRoot(_ body: () throws -> URL) rethrows -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-naming-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        }
        return try body()
    }

    func testResolveOutputURLIncludesProfile() throws {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = try inEmptyWorkspacesRoot {
            try engine.inWorkspace("prod").resolveOutputURL(stem: "report")
        }

        XCTAssertTrue(
            url.lastPathComponent.hasPrefix("report_prod_"),
            "expected 'report_prod_<timestamp>.xlsx', got '\(url.lastPathComponent)'"
        )
        XCTAssertEqual(url.pathExtension, "xlsx")
    }

    func testResolveOutputURLIncludesProfileWithoutTimestamp() throws {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = false

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = try inEmptyWorkspacesRoot {
            try engine.inWorkspace("prod").resolveOutputURL(stem: "report")
        }

        XCTAssertEqual(url.lastPathComponent, "report_prod.xlsx")
    }

    func testResolveOutputURLWithoutProfileKeepsLegacyName() throws {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = try engine.resolveOutputURL(stem: "report")

        XCTAssertTrue(
            url.lastPathComponent.hasPrefix("report_2"),
            "no-profile callers keep the legacy stem; got '\(url.lastPathComponent)'"
        )
    }

    /// One definition of each report's name, for the writers and the Generate sheet.
    func testEachFormatHasOneStem() {
        func stem(_ type: GenerateOutputType, school: Bool = false) -> String {
            ExportNaming.stem(for: type, profile: "a/b", schoolMode: school)
        }
        XCTAssertEqual(stem(.xlsx), "jamf_report_a%2Fb")
        XCTAssertEqual(stem(.xlsx, school: true), "jamf_school_report_a%2Fb")
        XCTAssertEqual(stem(.html), "jamf_report_a%2Fb")
        XCTAssertEqual(stem(.pdf, school: true), "jamf_report_a%2Fb")
        XCTAssertEqual(stem(.csv), "jamf_inventory_a%2Fb")
    }

    /// The workbook writers name their file through `resolveOutputURL`, which appends the
    /// profile itself; that name starts with the format's stem.
    func testTheEngineNamesAWorkbookWithItsStem() throws {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        for school in [false, true] {
            let url = try inEmptyWorkspacesRoot {
                try engine.inWorkspace("prod").resolveOutputURL(
                    stem: ExportNaming.reportKind(for: .xlsx, schoolMode: school))
            }
            XCTAssertTrue(url.lastPathComponent.hasPrefix(
                ExportNaming.stem(for: .xlsx, profile: "prod", schoolMode: school) + "_"),
                url.lastPathComponent)
        }
    }
}

// MARK: - Workbook stamp

final class WorkbookTimestampTests: XCTestCase {

    /// 2026-10-05 15:15:06 UTC.
    private let sample = Date(timeIntervalSince1970: 1_791_213_306)

    func testStampIsDateUnderscoreTimeInThisMacsZone() {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd_HHmmss"
        XCTAssertEqual(ReportEngine.workbookTimestamp(sample), local.string(from: sample))
        // The HTML, PDF and PNGs a run writes beside the workbook use this stamp too.
        XCTAssertEqual(ReportEngine.workbookTimestamp(sample), ExportNaming.timestamp(sample))
    }

    func testWorkbookNameEndsInTheStampTheConfigExampleShows() throws {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true
        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))

        let name = try engine.resolveOutputURL(stem: "report").deletingPathExtension()
            .lastPathComponent
        let stamp = String(name.dropFirst("report_".count))

        // Read back in this Mac's zone, as run rotation reads it, the stamp is now.
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = .current
        reader.dateFormat = "yyyy-MM-dd_HHmmss"
        let written = try XCTUnwrap(reader.date(from: stamp), stamp)
        XCTAssertLessThan(abs(written.timeIntervalSinceNow), 5)
    }
    /// Every generated report starts with `jamf_` (2.12), and the names before it still read
    /// back to their profile and label.
    func testGeneratedReportsStartWithJamfAndOldNamesStillRead() {
        for type in GenerateOutputType.allCases {
            for school in [false, true] {
                XCTAssertTrue(ExportNaming.reportKind(for: type, schoolMode: school)
                    .hasPrefix("jamf_"), "\(type) school=\(school)")
            }
        }
        for name in ["report_prod_2026-11-03_090000.xlsx", "jamf_report_prod_2026-11-03_090000.xlsx",
                     "school-report_prod_2026-11-03_090000.xlsx",
                     "jamf_school_report_prod_2026-11-03_090000.xlsx"] {
            XCTAssertEqual(ReportsView.profile(fromReportFilename: name), "prod", name)
        }
        XCTAssertEqual(ReportLibrary.kindLabel(
            forFilename: "jamf_school_report_k12_2026-11-03_090000.xlsx"), "Jamf School workbook")
        XCTAssertEqual(ReportLibrary.kindLabel(
            forFilename: "school-report_k12_2026-11-03_090000.xlsx"), "Jamf School workbook")
        XCTAssertEqual(ReportLibrary.kindLabel(
            forFilename: "jamf_inventory_prod_2026-11-03_090000.csv"), "Inventory CSV")
        XCTAssertEqual(ReportLibrary.kindLabel(
            forFilename: "inventory_prod_2026-11-03_090000.csv"), "Inventory CSV")
    }

    /// `output.file_prefix` names every generated report and falls back to `jamf` when it
    /// could not start a file name.
    func testFilePrefixNamesEveryReportAndFallsBackToJamf() throws {
        XCTAssertEqual(ExportNaming.validFilePrefix(" Acme-1 "), "Acme-1")
        let tooLong = String(repeating: "a", count: 25)
        for bad in ["", "   ", "acme_co", "acme co", "acme/co", "ÄCME", tooLong] {
            XCTAssertNil(ExportNaming.validFilePrefix(bad), bad)
        }
        let stem = { ExportNaming.stem(for: $0, profile: "prod", schoolMode: $1, prefix: "acme") }
        XCTAssertEqual(stem(.xlsx, true), "acme_school_report_prod")
        XCTAssertEqual(stem(.csv, false), "acme_inventory_prod")
        let yaml = { (value: String) in "output:\n  file_prefix: \(value)\n" }
        func decoded(_ text: String) throws -> String {
            try ConfigLoader.loadFromString(text).filePrefix
        }
        XCTAssertEqual(try decoded(yaml("acme")), "acme")
        XCTAssertEqual(try decoded(yaml("\"acme_co\"")), "jamf")
        XCTAssertEqual(try decoded(yaml("2026")), "jamf")
        XCTAssertEqual(try decoded("output:\n  keep_latest_runs: 3\n"), "jamf")
        XCTAssertEqual(ReportsView.profile(
            fromReportFilename: "acme_report_prod_2026-11-03_090000.xlsx"), "prod")
        XCTAssertEqual(ReportLibrary.kindLabel(
            forFilename: "acme_school_report_k12_2026-11-03_090000.xlsx"), "Jamf School workbook")
        XCTAssertEqual(ReportLibrary.kindLabel(
            forFilename: "acme_inventory_prod_2026-11-03_090000.csv"), "Inventory CSV")
    }

}
