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
    private func inEmptyWorkspacesRoot(_ body: () -> URL) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-naming-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        }
        return body()
    }

    func testResolveOutputURLIncludesProfile() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = inEmptyWorkspacesRoot { engine.resolveOutputURL(stem: "report", profile: "prod") }

        XCTAssertTrue(
            url.lastPathComponent.hasPrefix("report_prod_"),
            "expected 'report_prod_<timestamp>.xlsx', got '\(url.lastPathComponent)'"
        )
        XCTAssertEqual(url.pathExtension, "xlsx")
    }

    func testResolveOutputURLIncludesProfileWithoutTimestamp() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = false

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = inEmptyWorkspacesRoot { engine.resolveOutputURL(stem: "report", profile: "prod") }

        XCTAssertEqual(url.lastPathComponent, "report_prod.xlsx")
    }

    func testResolveOutputURLWithoutProfileKeepsLegacyName() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = engine.resolveOutputURL(stem: "report")

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
        XCTAssertEqual(stem(.xlsx), "report_a%2Fb")
        XCTAssertEqual(stem(.xlsx, school: true), "school-report_a%2Fb")
        XCTAssertEqual(stem(.html), "jamf_report_a%2Fb")
        XCTAssertEqual(stem(.pdf, school: true), "jamf_report_a%2Fb")
        XCTAssertEqual(stem(.csv), "inventory_a%2Fb")
    }

    /// The workbook writers name their file through `resolveOutputURL`, which appends the
    /// profile itself; that name starts with the format's stem.
    func testTheEngineNamesAWorkbookWithItsStem() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        for school in [false, true] {
            let url = inEmptyWorkspacesRoot {
                engine.resolveOutputURL(
                    stem: ExportNaming.reportKind(for: .xlsx, schoolMode: school),
                    profile: "prod")
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

    func testStampIsDateUnderscoreTimeInUTC() {
        XCTAssertEqual(ReportEngine.workbookTimestamp(sample), "2026-10-05_151506")
    }

    func testWorkbookNameEndsInTheStampTheConfigExampleShows() throws {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true
        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))

        let name = engine.resolveOutputURL(stem: "report").deletingPathExtension().lastPathComponent
        let stamp = String(name.dropFirst("report_".count))

        // Read back as UTC, the stamp is now: the example and the file agree on the zone.
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(identifier: "UTC")
        reader.dateFormat = "yyyy-MM-dd_HHmmss"
        let written = try XCTUnwrap(reader.date(from: stamp), stamp)
        XCTAssertLessThan(abs(written.timeIntervalSinceNow), 5)
    }
}
