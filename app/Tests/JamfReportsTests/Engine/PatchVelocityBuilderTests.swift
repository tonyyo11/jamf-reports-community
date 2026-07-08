import Foundation
import XCTest
@testable import JamfReports

// MARK: - PatchVelocityBuilderTests
//
// Covers PatchVelocityBuilder.compute:
//   - series built across dated files (adoption rising, ascending order)
//   - same-day dedupe (newest file per day wins)
//   - total == 0 days skipped
//   - manifest.json ignored
//   - undecodable file skipped
//   - daysTo50 crossing math
//   - daysTo50 nil when series starts above threshold
//   - daysToX nil without a release date
//   - daysBehind join by id and by name fallback
//   - sort order (daysBehind desc, nil last, then title)
//   - empty dir → empty result

final class PatchVelocityBuilderTests: XCTestCase {

    private nonisolated(unsafe) var tmpDir: URL!
    private nonisolated(unsafe) var patchDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchVelocityTests-\(UUID().uuidString)", isDirectory: true)
        patchDir = tmpDir.appendingPathComponent("patch-status", isDirectory: true)
        try FileManager.default.createDirectory(at: patchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Fixture helpers

    /// Write a patch-status snapshot file at a specific `yyyyMMddTHHmmss` stamp.
    /// `rows` = (id, title, onLatest, total).
    private func writeSnapshot(
        stamp: String, _ rows: [(id: String, title: String, onLatest: Int, total: Int)]
    ) throws {
        let objects: [[String: Any]] = rows.map { r in
            [
                "title": r.title,
                "id": r.id,
                "on_latest": r.onLatest,
                "on_other": max(0, r.total - r.onLatest),
                "total": r.total,
                "latest": "1.0",
                "compliance_pct": "\(r.total > 0 ? Int(Double(r.onLatest) / Double(r.total) * 100) : 0)%",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects)
        let url = patchDir.appendingPathComponent("patch-status_\(stamp).json")
        try data.write(to: url)
    }

    private func releaseRow(id: String, title: String, iso: String) -> PatchReleaseDateService.Row {
        // Row has no memberwise init exposed; build via JSON decode.
        let json = """
        {"title_id":"\(id)","title":"\(title)","latest_version":"1.0","release_date":"\(iso)"}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(PatchReleaseDateService.Row.self, from: Data(json.utf8))
    }

    private func velocity(_ vs: [TitleVelocity], id: String) -> TitleVelocity? {
        vs.first { $0.titleId == id }
    }

    // MARK: - Series across dated files, ascending

    func testSeriesBuiltAcrossThreeDatedFilesAscending() throws {
        try writeSnapshot(stamp: "20260101T100000", [("1", "Firefox", 20, 100)])
        try writeSnapshot(stamp: "20260105T100000", [("1", "Firefox", 55, 100)])
        try writeSnapshot(stamp: "20260110T100000", [("1", "Firefox", 95, 100)])

        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertEqual(firefox.series.count, 3)
        // Ascending by date.
        XCTAssertTrue(firefox.series[0].date < firefox.series[1].date)
        XCTAssertTrue(firefox.series[1].date < firefox.series[2].date)
        // Adoption percentages rising.
        XCTAssertEqual(firefox.series[0].adoptionPct, 20.0, accuracy: 0.001)
        XCTAssertEqual(firefox.series[2].adoptionPct, 95.0, accuracy: 0.001)
        // Current adoption = newest sample.
        let current = try XCTUnwrap(firefox.adoptionPct)
        XCTAssertEqual(current, 95.0, accuracy: 0.001)
    }

    // MARK: - Same-day dedupe: newest file wins

    func testSameDayDedupeNewestFileWins() throws {
        try writeSnapshot(stamp: "20260101T080000", [("1", "Firefox", 10, 100)])
        try writeSnapshot(stamp: "20260101T200000", [("1", "Firefox", 40, 100)])

        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertEqual(firefox.series.count, 1, "one point per calendar day")
        XCTAssertEqual(firefox.series[0].adoptionPct, 40.0, accuracy: 0.001,
                       "newest file for the day wins")
    }

    // MARK: - total == 0 skipped

    func testTotalZeroDaySkipped() throws {
        try writeSnapshot(stamp: "20260101T100000", [("1", "Firefox", 0, 0)])
        try writeSnapshot(stamp: "20260102T100000", [("1", "Firefox", 50, 100)])

        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertEqual(firefox.series.count, 1, "the total==0 day contributes no point")
        XCTAssertEqual(firefox.series[0].adoptionPct, 50.0, accuracy: 0.001)
    }

    // MARK: - manifest.json ignored

    func testManifestJSONIgnored() throws {
        try writeSnapshot(stamp: "20260101T100000", [("1", "Firefox", 30, 100)])
        let manifest = patchDir.appendingPathComponent("manifest.json")
        try Data("{\"kind\":\"manifest\"}".utf8).write(to: manifest)

        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertEqual(firefox.series.count, 1, "manifest.json is not a data snapshot")
    }

    // MARK: - undecodable file skipped

    func testUndecodableFileSkipped() throws {
        try writeSnapshot(stamp: "20260101T100000", [("1", "Firefox", 30, 100)])
        let broken = patchDir.appendingPathComponent("patch-status_20260102T100000.json")
        try Data("not json at all".utf8).write(to: broken)

        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        XCTAssertEqual(result.count, 1)
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertEqual(firefox.series.count, 1, "the undecodable day is skipped, valid day kept")
    }

    // MARK: - daysTo50 crossing math

    func testDaysTo50CrossingMath() throws {
        // Release 2026-01-01; crosses 50% on the 2026-01-11 sample → 10 days.
        try writeSnapshot(stamp: "20260101T120000", [("1", "Firefox", 10, 100)])
        try writeSnapshot(stamp: "20260111T120000", [("1", "Firefox", 60, 100)])

        let release = releaseRow(id: "1", title: "Firefox", iso: "2026-01-01T12:00:00Z")
        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [release])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertEqual(firefox.daysTo50, 10)
        // 90% never reached → nil.
        XCTAssertNil(firefox.daysTo90)
    }

    // MARK: - nil when series starts above threshold

    func testDaysTo50NilWhenSeriesStartsAboveThreshold() throws {
        // First recorded sample already ≥ 50% → crossing predates recording → nil.
        try writeSnapshot(stamp: "20260105T120000", [("1", "Firefox", 70, 100)])
        try writeSnapshot(stamp: "20260110T120000", [("1", "Firefox", 80, 100)])

        let release = releaseRow(id: "1", title: "Firefox", iso: "2026-01-01T12:00:00Z")
        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [release])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertNil(firefox.daysTo50, "series starts above 50% — no observed crossing")
    }

    // MARK: - nil without a release date

    func testDaysToThresholdNilWithoutReleaseDate() throws {
        try writeSnapshot(stamp: "20260101T120000", [("1", "Firefox", 10, 100)])
        try writeSnapshot(stamp: "20260111T120000", [("1", "Firefox", 95, 100)])

        // No release rows at all.
        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        XCTAssertNil(firefox.releaseDate)
        XCTAssertNil(firefox.daysTo50)
        XCTAssertNil(firefox.daysTo90)
        XCTAssertNil(firefox.daysBehind, "no release date → no daysBehind")
    }

    // MARK: - daysBehind join by id, and name fallback

    func testDaysBehindJoinByIdAndNameFallback() throws {
        try writeSnapshot(stamp: "20260101T120000", [
            ("1", "Firefox", 20, 100),
            ("2", "Google Chrome", 20, 100),
        ])
        // id "1" matches by id; "Google Chrome" only matches by name (id mismatch "99").
        let byId = releaseRow(id: "1", title: "Firefox", iso: "2026-01-01T00:00:00Z")
        let byName = releaseRow(id: "99", title: "Google Chrome", iso: "2026-01-01T00:00:00Z")
        let now = ISO8601DateFormatter().date(from: "2026-01-11T00:00:00Z")!

        let result = PatchVelocityBuilder.compute(
            dataDir: tmpDir, releaseRows: [byId, byName], now: now
        )
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        let chrome = try XCTUnwrap(velocity(result, id: "2"))
        XCTAssertNotNil(firefox.releaseDate, "id join resolves release date")
        XCTAssertEqual(firefox.daysBehind, 10)
        XCTAssertNotNil(chrome.releaseDate, "name fallback resolves release date on id miss")
        XCTAssertEqual(chrome.daysBehind, 10)
    }

    // MARK: - sort order

    func testSortOrderDaysBehindDescendingNilLast() throws {
        try writeSnapshot(stamp: "20260101T120000", [
            ("1", "Alpha", 20, 100),   // release → daysBehind large
            ("2", "Bravo", 20, 100),   // release → daysBehind small
            ("3", "Charlie", 20, 100), // no release → nil (last)
        ])
        let now = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
        let releases = [
            releaseRow(id: "1", title: "Alpha", iso: "2026-01-01T00:00:00Z"),  // ~31 behind
            releaseRow(id: "2", title: "Bravo", iso: "2026-01-25T00:00:00Z"),  // ~7 behind
        ]

        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: releases, now: now)
        XCTAssertEqual(result.map(\.titleId), ["1", "2", "3"],
                       "daysBehind descending, nil last")
    }

    func testSortTieBreaksByTitle() throws {
        // Two titles with identical (nil) daysBehind sort by title ascending.
        try writeSnapshot(stamp: "20260101T120000", [
            ("1", "Zebra", 20, 100),
            ("2", "Apple", 20, 100),
        ])
        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        XCTAssertEqual(result.map(\.title), ["Apple", "Zebra"])
    }

    // MARK: - empty dir → empty result

    func testEmptyDirEmptyResult() {
        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingPatchStatusDirEmptyResult() {
        let noDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchVelocityMissing-\(UUID().uuidString)", isDirectory: true)
        let result = PatchVelocityBuilder.compute(dataDir: noDir, releaseRows: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - fully adopted → daysBehind nil

    func testFullyAdoptedDaysBehindNil() throws {
        try writeSnapshot(stamp: "20260101T120000", [("1", "Firefox", 100, 100)])
        let release = releaseRow(id: "1", title: "Firefox", iso: "2026-01-01T00:00:00Z")
        let now = ISO8601DateFormatter().date(from: "2026-01-11T00:00:00Z")!
        let result = PatchVelocityBuilder.compute(dataDir: tmpDir, releaseRows: [release], now: now)
        let firefox = try XCTUnwrap(velocity(result, id: "1"))
        let adoption = try XCTUnwrap(firefox.adoptionPct)
        XCTAssertEqual(adoption, 100.0, accuracy: 0.001)
        XCTAssertNil(firefox.daysBehind, "100% adoption → nothing to chase")
    }
}
