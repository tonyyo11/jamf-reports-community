import XCTest
@testable import JamfReports

/// Tests for `DashboardChartExport.filename(for:profile:)` and its `sanitize`
/// helper (exercised indirectly through the public `filename` function).
///
/// The class is `@MainActor` because `DashboardChartExport` is a `@MainActor`
/// enum and `filename` is MainActor-isolated via `dateStampFormatter`.
@MainActor
final class DashboardChartExportTests: XCTestCase {

    // Timestamp component format for regex assertions (date + time since the
    // export-collision fix — exports a second apart must not overwrite).
    private let datePattern = #"\d{4}-\d{2}-\d{2}_\d{6}"#

    // MARK: - Normal label + profile produces expected structure

    func testNormalLabelAndProfile() {
        let result = DashboardChartExport.filename(for: "Fleet Overview", profile: "acme")
        XCTAssert(
            result.hasPrefix("acme-Fleet-Overview-"),
            "Expected 'acme-Fleet-Overview-<date>.png', got '\(result)'"
        )
        XCTAssert(result.hasSuffix(".png"))
        XCTAssertFalse(result.contains("--"), "No consecutive hyphens: \(result)")
    }

    func testResultMatchesDatePattern() throws {
        let result = DashboardChartExport.filename(for: "OS Versions", profile: "org")
        let regex = try NSRegularExpression(
            pattern: #"^org-OS-Versions-\d{4}-\d{2}-\d{2}_\d{6}\.png$"#
        )
        let range = NSRange(result.startIndex..., in: result)
        XCTAssertNotNil(
            regex.firstMatch(in: result, range: range),
            "Filename '\(result)' did not match expected pattern"
        )
    }

    // MARK: - Slashes and spaces become hyphens, not consecutive

    func testSlashesAndSpacesBecomeHyphens() {
        let result = DashboardChartExport.filename(for: "Top/Level Charts", profile: "org")
        XCTAssertFalse(result.contains("/"), "Slashes must be sanitized")
        XCTAssertFalse(result.contains("--"), "No consecutive hyphens after sanitization")
        XCTAssert(result.hasSuffix(".png"))
    }

    func testSpacesInLabelBecomeHyphens() {
        let result = DashboardChartExport.filename(for: "Security Posture", profile: "cbp")
        XCTAssert(result.contains("Security-Posture"), "Spaces become hyphens: \(result)")
    }

    // MARK: - Path traversal input produces clean output

    func testPathTraversalInputNoLeadingDots() {
        // "../../etc" → slashes removed → "..-..-etc" → collapse → "..-.-etc" → trim dots/hyphens
        let result = DashboardChartExport.filename(for: "../../etc", profile: "acme")
        XCTAssertFalse(result.hasPrefix("."), "Must not start with a dot: \(result)")
        XCTAssertFalse(result.contains("--"), "No consecutive hyphens: \(result)")
        XCTAssert(result.hasSuffix(".png"))
    }

    func testInputWithLeadingDotsNoHiddenFile() {
        let result = DashboardChartExport.filename(for: ".hidden", profile: "org")
        XCTAssertFalse(result.hasPrefix("."), "Leading dot must be stripped: \(result)")
    }

    // MARK: - Empty profile omits leading profile segment

    func testEmptyProfileOmitsProfileSegment() throws {
        let result = DashboardChartExport.filename(for: "Patch Status", profile: "")
        let regex = try NSRegularExpression(
            pattern: #"^Patch-Status-\d{4}-\d{2}-\d{2}_\d{6}\.png$"#
        )
        let range = NSRange(result.startIndex..., in: result)
        XCTAssertNotNil(
            regex.firstMatch(in: result, range: range),
            "Empty profile must omit profile segment; got '\(result)'"
        )
        XCTAssertFalse(result.hasPrefix("-"), "Must not start with a hyphen: \(result)")
    }

    // MARK: - Repeated special characters collapse to single hyphen

    func testRepeatedSpecialCharactersCollapse() {
        // Multiple consecutive spaces/symbols become one hyphen.
        let result = DashboardChartExport.filename(for: "A   B", profile: "org")
        XCTAssertFalse(result.contains("--"), "Repeated separators must collapse: \(result)")
        XCTAssert(result.contains("A-B"), "Should produce 'A-B' segment: \(result)")
    }

    func testManyConsecutiveHyphensInInput() {
        let result = DashboardChartExport.filename(for: "A---B", profile: "org")
        XCTAssertFalse(result.contains("--"), "Must collapse: \(result)")
        XCTAssert(result.contains("A-B"), "Should produce 'A-B': \(result)")
    }

    // MARK: - Output always ends with .png

    func testAlwaysHasPngExtension() {
        let result = DashboardChartExport.filename(for: "Any Label", profile: "p")
        XCTAssert(result.hasSuffix(".png"))
    }
}
