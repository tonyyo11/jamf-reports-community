import XCTest
@testable import JamfReports

/// The Overview tiles caption their delta with the date it compares against.
/// These pin why that date is per-metric and not a fixed cadence:
/// `points(metric:)` drops days where a metric was unmeasured, and collection
/// gaps make the interval irregular — so "week over week" would be a guess.
@MainActor
final class OverviewDeltaCaptionTests: XCTestCase {

    private func summary(
        date: String, fileVault: Double? = 98, staleCount: Int? = 12
    ) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: 100,
            fileVaultPct: fileVault,
            compliancePct: 90,
            staleCount: staleCount,
            osCurrentPct: 80,
            crowdstrikePct: 95,
            patchPct: 88
        )
    }

    private func store(_ summaries: [DailySummary]) -> TrendStore {
        let store = TrendStore()
        let snap = TrendStore.TrendSnapshot(
            summaries: summaries, latestSnapshotDate: nil, hasEverFetchedLive: true,
            bandSeries: [:], baselineNames: [])
        store.apply(snap, profile: "prod", range: .all, generation: store.beginLoading())
        return store
    }

    /// Active Devices is nil when staleness is unmeasured, so that day is
    /// dropped from its series but kept in FileVault's. Two tiles rendered
    /// together therefore compare against different days — which is why the
    /// caption is built per tile rather than once for the screen.
    func testMetricsWithGapsCompareAgainstTheirOwnPreviousSample() {
        let store = store([
            summary(date: "2026-08-01"),
            summary(date: "2026-08-10", staleCount: nil),
            summary(date: "2026-08-20"),
        ])

        let fileVaultDates = store.points(metric: .fileVault).map(\.date)
        let activeDates = store.points(metric: .activeDevices).map(\.date)

        XCTAssertEqual(fileVaultDates.count, 3)
        XCTAssertEqual(activeDates.count, 2, "the unmeasured day is dropped")
        XCTAssertNotEqual(
            fileVaultDates[fileVaultDates.count - 2],
            activeDates[activeDates.count - 2],
            "two tiles in one render legitimately compare against different days"
        )
    }

    /// One sample means no delta and therefore no caption.
    func testSingleSampleHasNoComparison() {
        let store = store([summary(date: "2026-08-20")])
        XCTAssertEqual(store.points(metric: .fileVault).count, 1)
    }

    /// The gap is whatever the collection cadence produced. Pinning that it can
    /// far exceed a week is the whole reason the tile names a date.
    func testIntervalBetweenSamplesIsNotWeekly() throws {
        let store = store([
            summary(date: "2026-07-01"),
            summary(date: "2026-08-20"),
        ])
        let dates = store.points(metric: .fileVault).map(\.date)
        let gap = try XCTUnwrap(
            Calendar.current.dateComponents([.day], from: dates[0], to: dates[1]).day
        )
        XCTAssertGreaterThan(gap, 7, "a 50-day gap must never be captioned as a week")
    }
}
