import Foundation
import XCTest
@testable import JamfReports

/// Tests for `PatchReleaseDateService`: merged snapshot decode,
/// latest-definition matching, and days-behind computation.
@MainActor
final class PatchReleaseDateServiceTests: XCTestCase {

    // MARK: - Merged snapshot decode

    func testDecodesMergedSnapshot() throws {
        let json = """
        [
          {"title_id": "2", "title": "Mozilla Firefox",
           "latest_version": "151.0.2",
           "release_date": "2026-05-26T13:48:54Z"}
        ]
        """
        let url = try writeTmp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = PatchReleaseDateService.load(from: url)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.titleId, "2")
        XCTAssertEqual(row.title, "Mozilla Firefox")
        XCTAssertEqual(row.latestVersion, "151.0.2")
        XCTAssertEqual(row.releaseDate, "2026-05-26T13:48:54Z")
    }

    func testDecodesRealFixture() throws {
        let url = fixtureURL("patch-release-dates_20260526T120000.json")
        let rows = PatchReleaseDateService.load(from: url)
        XCTAssertFalse(rows.isEmpty, "Real fixture must decode")
        XCTAssertEqual(rows.first?.titleId, "2")
    }

    func testMissingFileReturnsEmpty() {
        let missing = URL(fileURLWithPath: "/tmp/no_such_file_\(UUID().uuidString).json")
        XCTAssertTrue(PatchReleaseDateService.load(from: missing).isEmpty)
    }

    func testCorruptJSONReturnsEmpty() throws {
        let url = try writeTmp("{bad json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(PatchReleaseDateService.load(from: url).isEmpty)
    }

    func testEmptyArrayReturnsEmpty() throws {
        let url = try writeTmp("[]")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(PatchReleaseDateService.load(from: url).isEmpty)
    }

    // MARK: - Release date lookup

    func testReleaseDateLookupBuildsCorrectly() throws {
        let rows = [
            PatchReleaseDateService.Row(
                titleId: "1", title: "Self Service",
                latestVersion: "11.0", releaseDate: "2026-01-01T00:00:00Z"),
            PatchReleaseDateService.Row(
                titleId: "2", title: "Firefox",
                latestVersion: "151.0.2", releaseDate: "2026-05-26T13:48:54Z"),
        ]
        let lookup = PatchReleaseDateService.releaseDateLookup(from: rows)
        XCTAssertEqual(lookup["1"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(lookup["2"], "2026-05-26T13:48:54Z")
    }

    // MARK: - Latest definition matching

    func testMatchesExactVersion() {
        let defs: [[String: Any]] = [
            ["version": "151.0.2", "releaseDate": "2026-05-26T00:00:00Z",
             "absoluteOrderId": "0"],
            ["version": "150.0.1", "releaseDate": "2026-04-10T00:00:00Z",
             "absoluteOrderId": "1"],
        ]
        let (ver, date) = PatchReleaseDateService.latestDefinitionDate(
            definitions: defs, latestVersion: "151.0.2")
        XCTAssertEqual(ver, "151.0.2")
        XCTAssertEqual(date, "2026-05-26T00:00:00Z")
    }

    func testFallsBackToAbsoluteOrderIdZero() {
        let defs: [[String: Any]] = [
            ["version": "151.0.2", "releaseDate": "2026-05-26T00:00:00Z",
             "absoluteOrderId": "0"],
            ["version": "150.0.1", "releaseDate": "2026-04-10T00:00:00Z",
             "absoluteOrderId": "1"],
        ]
        let (ver, date) = PatchReleaseDateService.latestDefinitionDate(
            definitions: defs, latestVersion: "999.0.0")
        XCTAssertEqual(ver, "151.0.2", "absoluteOrderId=0 is fallback when no exact match")
        XCTAssertEqual(date, "2026-05-26T00:00:00Z")
    }

    func testFallsBackToFirstRecordWhenNoOrderId() {
        let defs: [[String: Any]] = [
            ["version": "2.0.0", "releaseDate": "2026-03-01T00:00:00Z"],
            ["version": "1.0.0", "releaseDate": "2026-01-01T00:00:00Z"],
        ]
        let (ver, date) = PatchReleaseDateService.latestDefinitionDate(
            definitions: defs, latestVersion: "99.0.0")
        XCTAssertEqual(ver, "2.0.0", "First record is last resort")
        XCTAssertEqual(date, "2026-03-01T00:00:00Z")
    }

    func testEmptyDefinitionsReturnsEmpty() {
        let (ver, date) = PatchReleaseDateService.latestDefinitionDate(
            definitions: [], latestVersion: "1.0")
        XCTAssertTrue(ver.isEmpty)
        XCTAssertTrue(date.isEmpty)
    }

    func testMatchingWithBlankLatestVersion() {
        let defs: [[String: Any]] = [
            ["version": "5.0", "releaseDate": "2026-05-01T00:00:00Z",
             "absoluteOrderId": "0"],
        ]
        let (ver, date) = PatchReleaseDateService.latestDefinitionDate(
            definitions: defs, latestVersion: "")
        XCTAssertEqual(ver, "5.0", "Empty latestVersion skips exact match, falls through to id=0")
        XCTAssertEqual(date, "2026-05-01T00:00:00Z")
    }

    // MARK: - Days behind

    func testDaysBehindComputation() {
        let ref = date(year: 2026, month: 6, day: 1)
        let days = PatchReleaseDateService.daysBehind(
            releaseDate: "2026-05-26T13:48:54Z", referenceDate: ref)
        XCTAssertEqual(days, 5, "June 1 - May 26 = 5 days (May has 31 days)")
    }

    func testDaysBehindEmptyReturnsNil() {
        XCTAssertNil(PatchReleaseDateService.daysBehind(releaseDate: ""))
    }

    func testDaysBehindFutureReleaseClampsToZero() {
        let ref = date(year: 2026, month: 1, day: 1)
        let days = PatchReleaseDateService.daysBehind(
            releaseDate: "2026-06-01T00:00:00Z", referenceDate: ref)
        XCTAssertEqual(days, 0, "Future release date must clamp to 0")
    }

    // MARK: - Helpers

    private func writeTmp(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prd-test-\(UUID().uuidString).json")
        try Data(content.utf8).write(to: url)
        return url
    }

    private func fixtureURL(_ filename: String) -> URL {
        TestFixtures.dir("jamf-cli-data/patch-release-dates")
            .appendingPathComponent(filename)
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .iso8601).date(from: comps)!
    }
}

// MARK: - Convenience init for Row

extension PatchReleaseDateService.Row {
    init(titleId: String, title: String, latestVersion: String, releaseDate: String) {
        let json = """
        {"title_id": \(jsonString(titleId)), "title": \(jsonString(title)),
         "latest_version": \(jsonString(latestVersion)), "release_date": \(jsonString(releaseDate))}
        """
        self = try! JSONDecoder().decode(
            PatchReleaseDateService.Row.self, from: Data(json.utf8))
    }
}

private func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
