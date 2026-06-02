import Foundation
import XCTest
@testable import JamfReports

/// Tests for `SOFAFeedService`: date parsing, feed decode, fleet currency,
/// EOL detection, and graceful degradation on missing/corrupt data.
@MainActor
final class SOFAFeedServiceTests: XCTestCase {

    // MARK: - Helpers

    private nonisolated(unsafe) var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SOFATests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Date parsing

    func testParseISOTimestamp() throws {
        let parsedDate = try XCTUnwrap(SOFAFeedService.parseSOFADate("2026-06-01T00:00:00Z"))
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: parsedDate)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 1)
    }

    func testParseDateOnlyString() throws {
        let parsedDate = try XCTUnwrap(SOFAFeedService.parseSOFADate("2026-05-11"))
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: parsedDate)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 11)
    }

    func testParseEmptyReturnsNil() {
        XCTAssertNil(SOFAFeedService.parseSOFADate(""))
        XCTAssertNil(SOFAFeedService.parseSOFADate("  "))
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(SOFAFeedService.parseSOFADate("not-a-date"))
        XCTAssertNil(SOFAFeedService.parseSOFADate("99999"))
    }

    // MARK: - Version tuple comparison

    func testVersionTupleParsesNormal() {
        XCTAssertEqual(SOFAFeedService.versionTuple("15.7.10"), [15, 7, 10])
        XCTAssertEqual(SOFAFeedService.versionTuple("26.5.1"), [26, 5, 1])
    }

    func testVersionTupleNumericComparisonCorrect() {
        // "15.7.10" > "15.7.3" — numeric comparison must win, not string.
        // Compare the third component directly.
        let a = SOFAFeedService.versionTuple("15.7.10")
        let b = SOFAFeedService.versionTuple("15.7.3")
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(b.count, 3)
        XCTAssertGreaterThan(a[2], b[2],
                             "15.7.10 patch component (10) must be > 15.7.3 (3)")
    }

    func testVersionTupleHandlesLeadingDigitsOnly() {
        // "0-rc1" component → 0
        let t = SOFAFeedService.versionTuple("15.0-rc1.3")
        XCTAssertEqual(t[0], 15)
        XCTAssertEqual(t[1], 0)
        XCTAssertEqual(t[2], 3)
    }

    func testVersionTupleEmpty() {
        XCTAssertTrue(SOFAFeedService.versionTuple("").isEmpty)
    }

    // MARK: - Fleet currency

    func testFleetCurrencyOnLatestExact() {
        let counts = ["26.5.1": 100, "26.4.0": 50]
        let (onLatest, behind) = SOFAFeedService.fleetCurrency(
            latestVersion: "26.5.1", osCounts: counts)
        XCTAssertEqual(onLatest, 100)
        XCTAssertEqual(behind, 50)
    }

    func testFleetCurrencyNewerVersionCountsAsOnLatest() {
        // Both 15.7.10 and 15.7.3 are >= 15.7.3 → both on-latest.
        // A device ahead of the published latest still counts as on-latest.
        let counts = ["15.7.10": 10, "15.7.3": 20]
        let (onLatest, behind) = SOFAFeedService.fleetCurrency(
            latestVersion: "15.7.3", osCounts: counts)
        XCTAssertEqual(onLatest, 30, "15.7.10 and 15.7.3 are both >= 15.7.3 → both on-latest")
        XCTAssertEqual(behind, 0, "No devices are behind 15.7.3")
    }

    func testFleetCurrencyDifferentMajorExcluded() {
        // Major 14 devices are not counted for a major-15 family.
        let counts = ["15.7.3": 100, "14.7.5": 200]
        let (onLatest, behind) = SOFAFeedService.fleetCurrency(
            latestVersion: "15.7.3", osCounts: counts)
        XCTAssertEqual(onLatest, 100)
        XCTAssertEqual(behind, 0, "Major-14 devices are a different family, not 'behind'")
    }

    func testFleetCurrencyEmptyCountsReturnsZero() {
        let (on, behind) = SOFAFeedService.fleetCurrency(latestVersion: "26.5.1", osCounts: [:])
        XCTAssertEqual(on, 0)
        XCTAssertEqual(behind, 0)
    }

    // MARK: - EOL count

    func testFleetEOLCountDetectsOldMajors() {
        let familyMajors: Set<Int> = [15, 26]
        let osCounts = ["14.7.5": 30, "13.7.0": 10, "15.1.0": 100]
        let (eolDevices, eolVersions) = SOFAFeedService.fleetEOLCount(
            familyMajors: familyMajors, osCounts: osCounts)
        XCTAssertEqual(eolDevices, 40, "14.x and 13.x = 40 EOL devices")
        XCTAssertEqual(eolVersions, 2, "2 distinct EOL version strings")
    }

    func testFleetEOLCountEmptyFamiliesReturnsZero() {
        let (devices, versions) = SOFAFeedService.fleetEOLCount(
            familyMajors: [], osCounts: ["14.7.5": 50])
        XCTAssertEqual(devices, 0)
        XCTAssertEqual(versions, 0)
    }

    func testFleetEOLCountNoOldDevicesReturnsZero() {
        let familyMajors: Set<Int> = [15]
        let (devices, _) = SOFAFeedService.fleetEOLCount(
            familyMajors: familyMajors, osCounts: ["15.7.3": 100])
        XCTAssertEqual(devices, 0)
    }

    // MARK: - Feed decode from real fixtures

    func testDecodesMacOSFixture() throws {
        let fixtureURL = fixtureURL(named: "macos_data_feed.json")
        let rows = SOFAFeedService.load(from: fixtureURL, platform: "macos",
                                        referenceDate: referenceDate())
        XCTAssertFalse(rows.isEmpty, "macos fixture must decode at least one row")
        let firstRow = try XCTUnwrap(rows.first)
        XCTAssertEqual(firstRow.platform, "macOS")
        XCTAssertFalse(firstRow.productVersion.isEmpty)
        XCTAssertFalse(firstRow.releaseDate.isEmpty)
    }

    func testDecodesIOSFixture() throws {
        let fixtureURL = fixtureURL(named: "ios_data_feed.json")
        let rows = SOFAFeedService.load(from: fixtureURL, platform: "ios",
                                        referenceDate: referenceDate())
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.first?.platform, "iOS / iPadOS")
    }

    func testDecodesTvOSFixtureDateOnlyFormat() throws {
        // tvOS/watchOS use date-only format ("2026-05-11"), not full ISO timestamp.
        let fixtureURL = fixtureURL(named: "tvos_data_feed.json")
        let rows = SOFAFeedService.load(from: fixtureURL, platform: "tvos",
                                        referenceDate: referenceDate())
        XCTAssertFalse(rows.isEmpty, "tvOS fixture must decode")
        XCTAssertEqual(rows.first?.platform, "tvOS")
        XCTAssertFalse(rows.first?.releaseDate.isEmpty ?? true,
                       "Date-only format must be parsed")
    }

    func testDecodesWatchOSFixture() throws {
        let fixtureURL = fixtureURL(named: "watchos_data_feed.json")
        let rows = SOFAFeedService.load(from: fixtureURL, platform: "watchos",
                                        referenceDate: referenceDate())
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.first?.platform, "watchOS")
    }

    func testDaysSinceReleaseIsNonNegative() throws {
        let fixtureURL = fixtureURL(named: "macos_data_feed.json")
        // Use a reference date well after the fixture's release date.
        let ref = date(year: 2026, month: 12, day: 1)
        let rows = SOFAFeedService.load(from: fixtureURL, platform: "macos",
                                        referenceDate: ref)
        for row in rows {
            if let days = row.daysSinceRelease {
                XCTAssertGreaterThanOrEqual(days, 0)
            }
        }
    }

    func testActivelyExploitedCVEsAreCounted() throws {
        // Inline feed with known CVEs — the live-captured fixture has zero
        // actively-exploited CVEs, which can't distinguish "parsed" from "ignored".
        let json = """
        {"OSVersions": [{"OSVersion": "Sequoia 15",
          "Latest": {"ProductVersion": "15.7.7", "Build": "24G720",
                     "ReleaseDate": "2026-05-11T00:00:00Z",
                     "ActivelyExploitedCVEs": ["CVE-2026-0001", "CVE-2026-0002", "CVE-2026-0003"]},
          "SecurityReleases": []}]}
        """
        let url = tmpDir.appendingPathComponent("inline_macos_feed.json")
        try Data(json.utf8).write(to: url)
        let rows = SOFAFeedService.load(from: url, platform: "macos",
                                        referenceDate: referenceDate())
        let sequoiaRow = rows.first { $0.osFamily.contains("Sequoia") }
        XCTAssertEqual(sequoiaRow?.activelyExploitedCVEs, 3)

        // And the real fixture (currently zero exploited CVEs) parses without error.
        let fixtureRows = SOFAFeedService.load(from: fixtureURL(named: "macos_data_feed.json"),
                                               platform: "macos",
                                               referenceDate: referenceDate())
        XCTAssertNotNil(fixtureRows.first { $0.osFamily.contains("Sequoia") })
    }

    // MARK: - Missing cache → empty snapshot

    func testMissingCacheReturnsEmpty() {
        let empty = SOFAFeedService.load(dataDir: tmpDir)
        XCTAssertTrue(empty.rows.isEmpty)
    }

    // MARK: - Corrupt JSON → graceful

    func testCorruptJSONReturnsEmptyRows() throws {
        let sofaDir = tmpDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: sofaDir, withIntermediateDirectories: true)
        let corrupt = sofaDir.appendingPathComponent("macos_data_feed.json")
        try Data("{not valid json".utf8).write(to: corrupt)
        let snap = SOFAFeedService.load(dataDir: tmpDir)
        XCTAssertTrue(snap.rows.isEmpty, "Corrupt JSON must produce empty rows + warning")
        XCTAssertFalse(snap.warnings.isEmpty, "Corrupt JSON must surface a warning")
    }

    // MARK: - Helpers

    private func fixtureURL(named filename: String) -> URL {
        // Match the pattern from CoreDashboardTests.swift.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures/sofa")
            .appendingPathComponent(filename)
    }

    /// A stable reference date for deterministic daysSinceRelease computation.
    private func referenceDate() -> Date {
        date(year: 2026, month: 6, day: 15)
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .iso8601).date(from: comps)!
    }
}
