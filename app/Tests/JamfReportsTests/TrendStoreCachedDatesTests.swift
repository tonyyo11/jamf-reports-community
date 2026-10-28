import Foundation
import XCTest
@testable import JamfReports

/// A summary's day is parsed once, when the summary is built or decoded, and the mSCP band
/// trend finds a day's point by a lookup built when the series is stored (#305).
@MainActor
final class TrendStoreCachedDatesTests: XCTestCase {

    private func summary(_ date: String, bands: [String: MSCPBandCounts]? = nil) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: 90, compliancePct: 70, staleCount: 5,
            osCurrentPct: 80, crowdstrikePct: nil, patchPct: 60, source: "jamf-cli",
            mscpBands: bands)
    }

    func testParsedDateEqualsTheDayParsedFromTheString() {
        for text in ["2026-05-01", "2026-12-31", "2024-02-29"] {
            XCTAssertEqual(
                summary(text).parsedDate, SummaryJSONParser.dateFormatter.date(from: text), text)
        }
    }

    func testAStringThatIsNotADayIsDistantPast() {
        XCTAssertEqual(summary("not-a-day").parsedDate, .distantPast)
        XCTAssertEqual(summary("").parsedDate, .distantPast)
    }

    func testADecodedSummaryCarriesTheSameDate() throws {
        let json = #"{"date":"2026-06-15","totalDevices":3,"source":"jamf-cli"}"#
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.parsedDate, SummaryJSONParser.dateFormatter.date(from: "2026-06-15"))
        let reencoded = try JSONDecoder().decode(
            DailySummary.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(reencoded.parsedDate, decoded.parsedDate)
    }

    func testAResolvedCopyKeepsItsDate() {
        let resolved = summary("2026-05-01").withDeviceWeightedPatch(71.5)
        XCTAssertEqual(resolved.parsedDate, SummaryJSONParser.dateFormatter.date(from: "2026-05-01"))
    }

    func testPointsAndDatesCarryTheCachedDates() {
        let days = (1...40).map { String(format: "2026-05-%02d", min($0, 28)) }
        let store = TrendStore(summaries: Array(Set(days)).sorted().map { summary($0) }, range: .all)
        let expected = store.filteredSummaries.map(\.date)
            .compactMap { SummaryJSONParser.dateFormatter.date(from: $0) }
        XCTAssertEqual(store.dates(), expected)
        XCTAssertEqual(store.points(metric: .fileVault).map(\.date), expected)
    }

    func testTheBandTrendTakesTheFirstPointOfADayAndFallsBackToTheSummary() {
        let bands = ["NIST": MSCPBandCounts(pass: 50, low: 30, medLow: 15, medium: 4, high: 1, noData: 9)]
        let summaries = [summary("2026-05-01", bands: bands), summary("2026-05-02", bands: bands)]
        let day1 = SummaryJSONParser.dateFormatter.date(from: "2026-05-01")!
        func point(_ date: Date, pass: Int) -> MSCPChartDataBuilder.BandPoint {
            .init(
                date: date,
                counts: MSCPBandCounts(pass: pass, low: 3, medLow: 0, medium: 0, high: 0, noData: 0),
                isSalvaged: false)
        }
        let snapshot = TrendStore.TrendSnapshot(
            summaries: summaries, latestSnapshotDate: nil, hasEverFetchedLive: true,
            bandSeries: ["NIST": [
                point(day1.addingTimeInterval(6 * 3600), pass: 7),
                point(day1.addingTimeInterval(7 * 3600), pass: 40),
            ]],
            baselineNames: ["NIST"])
        let store = TrendStore()
        store.apply(snapshot, profile: "p", range: .all, generation: store.beginLoading())
        // Day 1: the first ea-results point (7 + 3), not the second (40 + 3) or the summary's 100.
        // Day 2 has no point, so the summary's counts less no-data (100).
        XCTAssertEqual(store.points(metric: .mscpBandTrend).map(\.value), [10, 100])
    }
}
