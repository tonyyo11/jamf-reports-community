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

    func testResolveOutputURLIncludesProfile() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = engine.resolveOutputURL(stem: "report", profile: "prod")

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
        let url = engine.resolveOutputURL(stem: "report", profile: "prod")

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
}
