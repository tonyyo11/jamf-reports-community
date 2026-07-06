import Foundation
import XCTest
@testable import JamfReports

final class TrendStoreTests: XCTestCase {
    func testOptionalMetricPointsKeepDatesAlignedWhenValuesAreMissing() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01", compliancePct: 91),
                summary(date: "2026-04-08", compliancePct: nil),
                summary(date: "2026-04-15", compliancePct: 84),
            ],
            range: .all
        )

        let points = store.points(metric: .compliance)

        XCTAssertEqual(points.map { dateString($0.date) }, ["2026-04-01", "2026-04-15"])
        XCTAssertEqual(points.map(\.value), [91, 84])
        XCTAssertEqual(store.dates().map(dateString), ["2026-04-01", "2026-04-08", "2026-04-15"])
    }

    func testActiveDevicePointsIncludeEverySummary() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01", totalDevices: 100),
                summary(date: "2026-04-08", totalDevices: 125),
            ],
            range: .all
        )

        let points = store.points(metric: .activeDevices)

        XCTAssertEqual(points.map { dateString($0.date) }, ["2026-04-01", "2026-04-08"])
        XCTAssertEqual(points.map(\.value), [100, 125])
    }

    func testActiveDevicesDemoSeriesUsesTotalDevicesTrend() {
        let points = TrendDemoSeries.points(for: .activeDevices, range: .all)

        XCTAssertEqual(points.count, min(TrendDemoSeries.dates.count, DemoData.totalDevicesTrend.count))
        XCTAssertEqual(points.map(\.value), DemoData.totalDevicesTrend)
    }

    func testDemoPointsClampMismatchedDateAndValueArrays() {
        let dates = ["2026-04-01", "2026-04-08", "2026-04-15"]
            .compactMap(SummaryJSONParser.dateFormatter.date)
        let values = [10.0, 20.0]

        let points = TrendDemoSeries.points(dates: dates, values: values, range: .all)

        XCTAssertEqual(points.map { dateString($0.date) }, ["2026-04-01", "2026-04-08"])
        XCTAssertEqual(points.map(\.value), values)
    }

    private func summary(
        date: String,
        totalDevices: Int = 500,
        compliancePct: Double? = 90,
        crowdstrikePct: Double? = 95
    ) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: 98,
            compliancePct: compliancePct,
            staleCount: 12,
            osCurrentPct: 80,
            crowdstrikePct: crowdstrikePct,
            patchPct: 88
        )
    }

    private func dateString(_ date: Date) -> String {
        SummaryJSONParser.dateFormatter.string(from: date)
    }

    /// A same-profile reload (tab re-entry) keeps data on screen; switching to a
    /// different profile drops the previous tenant's data so the loading overlay
    /// shows (not the wrong tenant's numbers under the new header).
    func testClearForProfileSwitchDropsOnlyPreviousTenant() {
        let store = TrendStore()
        let snap = TrendStore.TrendSnapshot(
            summaries: [summary(date: "2026-07-01")],
            latestSnapshotDate: nil, hasEverFetchedLive: true,
            bandSeries: [:], baselineNames: [])
        store.apply(snap, profile: "prod", range: .all, generation: store.beginLoading())
        XCTAssertEqual(store.currentProfile, "prod")
        XCTAssertFalse(store.filteredSummaries.isEmpty)

        // Same profile → no-op (data retained).
        store.clearForProfileSwitch(to: "prod")
        XCTAssertFalse(store.filteredSummaries.isEmpty)
        XCTAssertEqual(store.currentProfile, "prod")

        // Different profile → cleared.
        store.clearForProfileSwitch(to: "dev")
        XCTAssertTrue(store.filteredSummaries.isEmpty)
        XCTAssertNil(store.currentProfile)
    }

    // MARK: - stabilityIndex sourcing tests

    /// Regression guard for the prod observation (2026-06-06) where the Overview
    /// Stability Index tile displayed a prior-day value.
    ///
    /// Root cause: TrendStore had not been reloaded after a same-day proxy→real mSCP
    /// summary upgrade, so `filteredSummaries.last` still held the pre-upgrade summary.
    /// The stability tile and every other score-card tile share the identical TrendStore
    /// path — all tiles were equally stale.
    ///
    /// This test proves the sourcing is correct: `values(metric: .stability).last` is
    /// computed live from the most-recent summary's stored fields (not a separate persisted
    /// value), so a TrendStore loaded from the updated summary yields the correct index.
    func testStabilityTileReflectsMostRecentSummaryInputs() throws {
        // Day 1: proxy compliance = 96.8% (before mSCP config typo fix)
        let day1 = DailySummary(
            date: "2026-06-05",
            totalDevices: 659,
            fileVaultPct: 98.8,
            compliancePct: 96.8,
            staleCount: 166,
            osCurrentPct: 36.3,
            crowdstrikePct: nil,
            patchPct: 36.3,
            complianceIsProxy: true
        )
        // Day 2: real compliance = 66.9% (after mSCP config typo fix + summary upgrade)
        let day2 = DailySummary(
            date: "2026-06-06",
            totalDevices: 659,
            fileVaultPct: 98.8,
            compliancePct: 66.9,
            staleCount: 166,
            osCurrentPct: 36.3,
            crowdstrikePct: nil,
            patchPct: 36.3,
            complianceIsProxy: false
        )

        // A TrendStore loaded with both summaries must show day2's stability as the
        // current (last) value, not day1's.
        let store = TrendStore(summaries: [day1, day2], range: .all)

        let stabilityValues = store.values(metric: .stability)
        XCTAssertEqual(stabilityValues.count, 2, "both days must have stability data")

        let current = try XCTUnwrap(stabilityValues.last)
        let expectedCurrent = try XCTUnwrap(
            TrendSeries.stabilityIndex(
                compliancePct: day2.compliancePct,
                patchPct: day2.patchPct,
                staleCount: day2.staleCount,
                totalDevices: day2.totalDevices
            )
        )
        XCTAssertEqual(current, expectedCurrent, accuracy: 0.01,
            "tile must reflect today's summary inputs; got \(current), want \(expectedCurrent)")

        // Confirm it is NOT the prior-day value.
        let staleValue = try XCTUnwrap(
            TrendSeries.stabilityIndex(
                compliancePct: day1.compliancePct,
                patchPct: day1.patchPct,
                staleCount: day1.staleCount,
                totalDevices: day1.totalDevices
            )
        )
        XCTAssertGreaterThan(abs(current - staleValue), 1.0,
            "tile must not reflect yesterday's proxy-compliance inputs")
    }

    // MARK: - stabilityIndex tests

    func testStabilityIndexCalculation() throws {
        // Normal case: compliance=90, patch=80, stale=10/100
        let idx1 = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: 80, staleCount: 10, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx1), 86.0, accuracy: 0.1)

        // staleCount = 0, staleInverse = 100
        let idx3 = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: 80, staleCount: 0, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx3), 88.0, accuracy: 0.1)

        // All stale, staleInverse = 0
        let idx4 = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: 80, staleCount: 100, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx4), 68.0, accuracy: 0.1)

        // All perfect -> 100
        let idx5 = TrendSeries.stabilityIndex(compliancePct: 100, patchPct: 100, staleCount: 0, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx5), 100.0, accuracy: 0.1)

        // All terrible -> 0
        let idx6 = TrendSeries.stabilityIndex(compliancePct: 0, patchPct: 0, staleCount: 100, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx6), 0.0, accuracy: 0.1)
    }

    /// Production bug: jamf-cli-only tenants never have compliancePct, so the
    /// old `guard let compliancePct, let patchPct` returned nil forever and the
    /// Stability Index tile showed "—" with "0 summaries". Missing components
    /// now drop out and the remaining weights renormalize.
    func testStabilityIndexRenormalizesWhenComplianceMissing() throws {
        // patch=80 (weight 0.4→2/3), staleInverse=90 (weight 0.2→1/3)
        let idx = TrendSeries.stabilityIndex(compliancePct: nil, patchPct: 80, staleCount: 10, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx), 80.0 * 2 / 3 + 90.0 / 3, accuracy: 0.1)
    }

    func testStabilityIndexRenormalizesWhenPatchMissing() throws {
        // compliance=90 (2/3), staleInverse=100 (1/3)
        let idx = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: nil, staleCount: 0, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx), 90.0 * 2 / 3 + 100.0 / 3, accuracy: 0.1)
    }

    func testStabilityIndexNilWhenBothHealthSignalsMissing() {
        // Stale pressure alone is not a stability signal.
        let idx = TrendSeries.stabilityIndex(compliancePct: nil, patchPct: nil, staleCount: 0, totalDevices: 100)
        XCTAssertNil(idx)
    }

    func testStabilityBasisDescribesAvailableComponents() {
        XCTAssertEqual(
            TrendSeries.stabilityBasis(compliancePct: 90, patchPct: 80),
            "Composite of compliance, patch posture, and stale-device pressure."
        )
        XCTAssertEqual(
            TrendSeries.stabilityBasis(compliancePct: nil, patchPct: 80),
            "Composite of patch posture and stale-device pressure (compliance not collected)."
        )
        XCTAssertNil(TrendSeries.stabilityBasis(compliancePct: nil, patchPct: nil))
    }

    // MARK: - stabilityBasis proxy propagation

    /// When the compliance component is present and proxy-backed (4-control
    /// proxy from the security report), the stability basis must append a note
    /// so operators understand the index is partially estimated.
    func testStabilityBasisAppendProxyNoteWhenComplianceIsProxy() {
        let basis = TrendSeries.stabilityBasis(
            compliancePct: 75,
            patchPct: 80,
            complianceIsProxy: true
        )
        XCTAssertNotNil(basis)
        XCTAssertTrue(
            basis!.contains("4-control proxy"),
            "proxy note must mention '4-control proxy'; got: \(basis!)"
        )
    }

    /// When compliance is real mSCP data (proxy == false), no proxy note.
    func testStabilityBasisNoProxyNoteWhenComplianceIsReal() {
        let basis = TrendSeries.stabilityBasis(
            compliancePct: 88,
            patchPct: 92,
            complianceIsProxy: false
        )
        XCTAssertEqual(
            basis,
            "Composite of compliance, patch posture, and stale-device pressure."
        )
    }

    /// When compliance is missing entirely, proxy flag is irrelevant and must
    /// not produce a proxy note (there is no compliance component to qualify).
    func testStabilityBasisNoProxyNoteWhenComplianceMissing() {
        let basis = TrendSeries.stabilityBasis(
            compliancePct: nil,
            patchPct: 80,
            complianceIsProxy: true
        )
        XCTAssertFalse(
            basis?.contains("4-control proxy") == true,
            "proxy note must be omitted when compliance is not feeding the index"
        )
    }

    // MARK: - chartDomain tests

    func testChartDomainReturnsNilWhenEmpty() {
        let store = TrendStore(summaries: [], range: .w26)
        XCTAssertNil(store.chartDomain)
    }

    func testChartDomainForFourWeekRange() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01"),
                summary(date: "2026-04-15"),
                summary(date: "2026-05-01"),
            ],
            range: .w4
        )
        guard let domain = store.chartDomain else {
            XCTFail("chartDomain should not be nil")
            return
        }
        let endDateStr = dateString(domain.upperBound)
        XCTAssertEqual(endDateStr, "2026-05-01")
        // startDate should be ~4 weeks before 2026-05-01
        let startDateStr = dateString(domain.lowerBound)
        XCTAssertTrue(startDateStr <= "2026-04-03" && startDateStr >= "2026-03-31",
                    "startDate \(startDateStr) not in expected range")
    }

    func testChartDomainForAllRange() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-01-01"),
                summary(date: "2026-05-01"),
            ],
            range: .all
        )
        guard let domain = store.chartDomain else {
            XCTFail("chartDomain should not be nil")
            return
        }
        let startDateStr = dateString(domain.lowerBound)
        let endDateStr = dateString(domain.upperBound)
        XCTAssertEqual(startDateStr, "2026-01-01")
        XCTAssertEqual(endDateStr, "2026-05-01")
    }

    func testChartDomainSingleSummary() {
        let store = TrendStore(
            summaries: [summary(date: "2026-05-01")],
            range: .w4
        )
        guard let domain = store.chartDomain else {
            XCTFail("chartDomain should not be nil")
            return
        }
        let startDateStr = dateString(domain.lowerBound)
        let endDateStr = dateString(domain.upperBound)
        XCTAssertEqual(startDateStr, "2026-04-03")
        XCTAssertEqual(endDateStr, "2026-05-01")
    }

    // MARK: - PR-13: CacheSource plumbing

    func testCacheSourceIsNeverFetchedLiveWithDemoOnlySummaries() {
        // Default `summary(...)` helper uses `source = "demo"` — no live runs
        // exist in the corpus, so cacheSource must report .neverFetchedLive
        // even though summaries are present.
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01"),
                summary(date: "2026-05-01"),
            ],
            range: .all
        )
        XCTAssertEqual(store.cacheSource, .neverFetchedLive,
                       "Demo-only summaries must not register as live data — closes PR-7 first-install false-stale")
    }

    func testCacheSourceIsNeverFetchedLiveWhenEmpty() {
        let store = TrendStore(summaries: [], range: .all)
        XCTAssertEqual(store.cacheSource, .neverFetchedLive)
    }

    // MARK: - PR-18: cache invalidation via computeSnapshot + apply

    /// Every `apply(computeSnapshot(...))` composition re-scans the filesystem
    /// for the given profile — there is no cached short-circuit left in
    /// `TrendStore` (the old `load`/`reload` methods, which had zero production
    /// callers, were removed). When a sibling write (Generate, Refresh) lands,
    /// a fresh `computeSnapshot` + `apply` immediately picks up the new
    /// `summary_*.json` mtime, so `cacheSource` and `StaleDataBanner` reflect
    /// the latest run.
    func testReloadPicksUpFreshSummaryAfterLoadCachedAnOlderMTime() throws {
        let env = try TrendStoreTestEnv.make()
        defer { env.tearDown() }

        // First snapshot: oldish mtime — simulates the workspace state when
        // the user opens Overview a week after the last Generate.
        let weekAgo = Date(timeIntervalSinceNow: -7 * 86_400)
        try env.writeSummary(date: "2026-05-11", mtime: weekAgo, source: "jamf-cli")
        let store = TrendStore()
        store.apply(
            TrendStore.computeSnapshot(profile: env.profile),
            profile: env.profile, range: .w4, generation: store.beginLoading()
        )
        XCTAssertEqual(
            store.latestSnapshotDate.map { round($0.timeIntervalSince1970) },
            weekAgo.timeIntervalSince1970.rounded()
        )

        // Sibling write: a fresh summary lands while the same TrendStore
        // instance is alive (simulates Overview's Generate Report flow).
        let now = Date()
        try env.writeSummary(date: "2026-05-18", mtime: now, source: "jamf-cli")

        // Every apply re-scans the filesystem (there is no short-circuit path
        // left in TrendStore), so a fresh generation immediately picks up the
        // new file's mtime.
        store.apply(
            TrendStore.computeSnapshot(profile: env.profile),
            profile: env.profile, range: .w4, generation: store.beginLoading()
        )
        XCTAssertEqual(
            store.latestSnapshotDate.map { round($0.timeIntervalSince1970) },
            now.timeIntervalSince1970.rounded(),
            "apply(computeSnapshot(...)) must re-scan the filesystem — this is what the Refresh button and Generate completion call"
        )
    }

    func testCacheSourceTreatsJamfCliSourceAsLive() {
        // A summary with `source == "jamf-cli"` flips hasEverFetchedLive=true.
        // Without an mtime (no on-disk file in this constructor path), the
        // freshness helper returns .neverFetchedLive — but only because the
        // date is nil. The hasEverFetchedLive guard short-circuits to the
        // same state. Verify by constructing a live summary and confirming
        // the guard isn't tripped by source detection alone.
        let liveSummary = DailySummary(
            date: "2026-05-01",
            totalDevices: 500,
            fileVaultPct: 98,
            compliancePct: 90,
            staleCount: 12,
            osCurrentPct: 80,
            crowdstrikePct: 95,
            patchPct: 88,
            source: "jamf-cli"
        )
        let store = TrendStore(summaries: [liveSummary], range: .all)
        XCTAssertTrue(store.hasEverFetchedLive,
                      "TrendStore must detect jamf-cli-sourced summaries as live")
        // latestSnapshotDate is nil for the in-memory init path (no filesystem
        // scan happens), so cacheSource folds back to .neverFetchedLive via
        // the date-nil branch of CacheSource.from. That's the right behavior:
        // we treat "no mtime evidence" as "never live", not "stale forever".
        XCTAssertEqual(store.cacheSource, .neverFetchedLive)
    }

    // MARK: - staleCount nil renormalization

    /// staleCount nil must drop the stale component; index renormalizes over
    /// compliance + patch only. Moved from TrendStoreTestEnv where XCTest
    /// could not discover it (struct scope).
    func testStabilityIndexDropsStaleComponentWhenUnknown() {
        let withUnknownStale = TrendSeries.stabilityIndex(
            compliancePct: 80, patchPct: 60, staleCount: nil, totalDevices: 100)
        // weights: compliance 0.4, patch 0.4, total 0.8 → each 50% → 70
        let expectedNil: Double = 70.0
        XCTAssertEqual(withUnknownStale ?? -1, expectedNil, accuracy: 0.01)

        let withMeasuredZero = TrendSeries.stabilityIndex(
            compliancePct: 80, patchPct: 60, staleCount: 0, totalDevices: 100)
        // staleInverse=100 (weight 0.2), compliance 80 (0.4), patch 60 (0.4) → 76
        let expectedZero: Double = 76.0
        XCTAssertEqual(withMeasuredZero ?? -1, expectedZero, accuracy: 0.01,
                       "a measured zero still earns the stale component")
    }
}

// MARK: - PR-18 test scaffolding

/// Temp workspace + profile setup for tests that need TrendStore to actually
/// scan the filesystem. Uses `JRC_TEST_WORKSPACES_ROOT` env override.
private struct TrendStoreTestEnv {
    let workspacesRoot: URL
    let profile: String

    static func make() throws -> TrendStoreTestEnv {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("trendStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)

        // Profile slug must satisfy ProfileService.isValid: lowercase alnum
        // starting with alnum, then [a-z0-9._-]. The UUID suffix is uppercase
        // hex; lowercase it.
        let profile = "test-\(UUID().uuidString.prefix(8).lowercased())"
        let summariesDir = root
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        return TrendStoreTestEnv(workspacesRoot: root, profile: profile)
    }

    func tearDown() {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: workspacesRoot)
    }

    func writeSummary(date: String, mtime: Date, source: String) throws {
        let summariesDir = workspacesRoot
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        let file = summariesDir.appendingPathComponent("summary_\(date).json")
        let payload: [String: Any] = [
            "date": date,
            "totalDevices": 100,
            "fileVaultPct": 95,
            "compliancePct": 90,
            "staleCount": 5,
            "osCurrentPct": 80,
            "crowdstrikePct": 92,
            "patchPct": 85,
            "source": source,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime],
            ofItemAtPath: file.path
        )
    }

}
