import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 C1/C2: a summary without `patchPctBasis` recorded the unweighted per-title mean.
/// `TrendStore.recomputePatchPct` finds the device-weighted figure from the newest
/// `patch-status` snapshot stamped the same local day, and `TrendStore.readSummaries` hands
/// every screen, report and alert the summaries already carrying it.
///
/// Fixture, worked by hand: Chrome 450 of 500, Zoom 20 of 100, Slack 10 of 10.
/// Device-weighted (450 + 20 + 10) / (500 + 100 + 10) = 78.689%, which the summary writer
/// records as 78.7; the old mean was 70.0%.
final class TrendStorePatchRecomputeTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!

    /// 480 / 610, rounded to a tenth the way the summary writer records it, so a day
    /// recomputed here reads the same as one written after the upgrade.
    private static let weighted = 78.7

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-PatchRecompute-\(UUID().uuidString)", isDirectory: true)
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Selection

    func testOldBasisDayTakesTheFigureFromThatDaysSnapshot() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 14))

        let recomputed = try XCTUnwrap(recompute([summary("2026-05-10")])["2026-05-10"])
        XCTAssertEqual(recomputed, Self.weighted, accuracy: 0.0001)
        XCTAssertNotEqual(recomputed, 70.0, accuracy: 1.0, "the recorded per-title mean")
    }

    /// The workbook's Charts tab resolves its summaries the way the screens do, so its Patch %
    /// line does not step at the upgrade either.
    func testResolvingMovesOnlyTheRecomputedDayToTheDeviceBasis() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 14))
        let resolved = TrendStore.resolvingPatch([
            summary("2026-05-10"),
            summary("2026-05-11", patchPct: 80, basis: DailySummary.deviceWeightedPatchBasis),
            summary("2026-05-12", patchPct: nil),
            summary("2026-05-13"),
        ], dataDir: dataDir)
        XCTAssertEqual(resolved.map(\.patchPct), [Self.weighted, 80, nil, 70])
        XCTAssertEqual(resolved.map(\.patchPctBasis), [
            DailySummary.deviceWeightedPatchBasis, DailySummary.deviceWeightedPatchBasis,
            nil, nil,
        ])
    }

    func testResolvingKeepsTheOtherFieldsOfTheDay() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 14))
        let before = DailySummary(
            date: "2026-05-10", totalDevices: 100, fileVaultPct: 91.5, compliancePct: 60,
            staleCount: 7, osCurrentPct: 40, crowdstrikePct: nil, patchPct: 70.0)
        let after = try XCTUnwrap(
            TrendStore.resolvingPatch([before], dataDir: dataDir).first)
        XCTAssertEqual(after.patchPct, Self.weighted)
        XCTAssertEqual(
            [after.fileVaultPct, after.compliancePct, after.osCurrentPct], [91.5, 60, 40])
        XCTAssertEqual(after.staleCount, 7)
        // 0.2 x 93 (stale) + 0.4 x 60 (compliance) + 0.4 x 78.7 (patch)
        XCTAssertEqual(try XCTUnwrap(after.stabilityIndex), 74.08, accuracy: 0.0001)
    }

    func testDayWithoutASnapshotKeepsItsRecordedValue() throws {
        try writePatchSnapshot(at: instant("2026-05-09", hour: 14))

        XCTAssertEqual(recompute([summary("2026-05-10")]), [:])
    }

    func testNoPatchStatusDirectoryMeansNoRecompute() {
        XCTAssertEqual(recompute([summary("2026-05-10")]), [:])
    }

    func testDayRecordedUnderTheDeviceBasisIsNotRecomputed() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 14), rows: [("Solo", 1, 2)])

        XCTAssertEqual(recompute([summary("2026-05-10", patchPct: 78.7, basis: "device")]), [:])
    }

    func testDayThatRecordedNoPatchFigureIsLeftAlone() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 14))

        XCTAssertEqual(recompute([summary("2026-05-10", patchPct: nil)]), [:])
    }

    /// The newest snapshot stamped that day, not the newest before the day ended.
    func testNewestSnapshotOfTheDayWins() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 8), rows: [("Solo", 1, 2)])
        try writePatchSnapshot(at: instant("2026-05-10", hour: 20), rows: [("Solo", 3, 4)])

        XCTAssertEqual(recompute([summary("2026-05-10")]), ["2026-05-10": 75.0])
    }

    func testSnapshotsStampedOnNeighbouringDaysDoNotFillTheDay() throws {
        try writePatchSnapshot(at: instant("2026-05-09", hour: 23.5))
        try writePatchSnapshot(at: instant("2026-05-11", hour: 0.5))

        XCTAssertEqual(recompute([summary("2026-05-10")]), [:])
    }

    func testManifestAndSyncConflictCopyAreIgnored() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 8), rows: [("Solo", 1, 2)])
        let evening = try instant("2026-05-10", hour: 20)
        try writePatchSnapshot(at: evening, rows: [("Solo", 4, 4)], name: "manifest.json",
                               mtime: evening)
        try writePatchSnapshot(
            at: evening, rows: [("Solo", 4, 4)],
            name: "patch-status_20260510T200000 2.json", mtime: evening)

        XCTAssertEqual(recompute([summary("2026-05-10")]), ["2026-05-10": 50.0])
    }

    func testUndecodableNewestFileFallsBackToTheNextNewestOfThatDay() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 8), rows: [("Solo", 1, 4)])
        try writeUndecodableSnapshot(at: instant("2026-05-10", hour: 20))

        XCTAssertEqual(recompute([summary("2026-05-10")]), ["2026-05-10": 25.0])
    }

    func testSnapshotWhoseTitlesHaveNoDevicesLeavesTheRecordedValue() throws {
        try writePatchSnapshot(at: instant("2026-05-10", hour: 14), rows: [("Empty", 0, 0)])

        XCTAssertEqual(recompute([summary("2026-05-10")]), [:])
    }

    // MARK: - Wiring

    /// End to end through `computeSnapshot`: the Patch series and the Stability series
    /// (patch is 40% of it) read the recomputed figure, and a day with no snapshot keeps
    /// the recorded one.
    func testComputeSnapshotRecomputesThePatchAndStabilitySeries() throws {
        let profile = try writeWorkspaceWithOneRecomputableDay()

        let snapshot = TrendStore.computeSnapshot(profile: profile)
        XCTAssertEqual(snapshot.summaries.map(\.patchPct), [Self.weighted, 70.0])

        let store = TrendStore()
        store.apply(snapshot, profile: profile, range: .all, generation: store.beginLoading())
        let patch = store.points(metric: .patch).map(\.value)
        XCTAssertEqual(patch.count, 2)
        XCTAssertEqual(patch[0], Self.weighted, accuracy: 0.0001)
        XCTAssertEqual(patch[1], 70.0, accuracy: 0.0001)
        // Compliance and stale are unmeasured, so the index is the patch figure alone.
        let stability = store.points(metric: .stability).map(\.value)
        XCTAssertEqual(stability[0], Self.weighted, accuracy: 0.0001)
        XCTAssertEqual(stability[1], 70.0, accuracy: 0.0001)
    }

    /// Visual review 2026-10-04: Overview and Trends read 35.4% while Fleet Overview, its
    /// drill-in and the Overview insight read the recorded 31.3%. Every one of them now loads
    /// through `readSummaries`, so each gets the same figure, the same Stability index and the
    /// same insight fact for the same day.
    func testEveryReaderOfASummaryGetsTheSameResolvedPatchFigure() throws {
        let profile = try writeWorkspaceWithOneRecomputableDay()

        let trends = try XCTUnwrap(TrendStore.computeSnapshot(profile: profile).summaries.first)
        let fleetOverview = try XCTUnwrap(TrendStore.readSummaries(profile: profile).first)
        let rollup = try XCTUnwrap(FleetReportEmitter.defaultSummaries(profile).first)

        for summary in [trends, fleetOverview, rollup] {
            XCTAssertEqual(summary.patchPct, Self.weighted)
            XCTAssertEqual(summary.patchPctBasis, DailySummary.deviceWeightedPatchBasis)
            XCTAssertEqual(summary.stabilityIndex, Self.weighted)
        }
        let insight = FleetInsightInput.fleet(current: fleetOverview, previous: nil)
        let fact = try XCTUnwrap(insight.facts.first { $0.label == "Patch compliance" })
        XCTAssertEqual(fact.value.text, "78.7%")
    }

    func testResolvedPriorStaysComparableForTheInsight() throws {
        let profile = try writeWorkspaceWithOneRecomputableDay(
            days: ["2026-05-09", "2026-05-10"])
        try writePatchSnapshot(at: instant("2026-05-09", hour: 8), rows: [("Solo", 3, 4)])

        let summaries = TrendStore.readSummaries(profile: profile)
        let insight = FleetInsightInput.fleet(
            current: try XCTUnwrap(summaries.last), previous: summaries.first)
        let fact = try XCTUnwrap(insight.facts.first { $0.label == "Patch compliance" })
        XCTAssertEqual(fact.prior?.text, "75.0%")
    }

    /// A workspace whose `days` hold summaries recorded under the per-title mean (70.0),
    /// where only `2026-05-10` has a `patch-status` snapshot. Sets `dataDir` to its data dir.
    private func writeWorkspaceWithOneRecomputableDay(
        days: [String] = ["2026-05-10", "2026-05-11"]
    ) throws -> String {
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "patchrecompute"
        let workspace = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
        let summariesDir = workspace
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(
            at: summariesDir, withIntermediateDirectories: true)
        for day in days {
            let payload: [String: Any] = [
                "date": day, "totalDevices": 100, "patchPct": 70.0, "source": "jamf-cli",
            ]
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: summariesDir.appendingPathComponent("summary_\(day).json"))
        }
        dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try writePatchSnapshot(at: instant("2026-05-10", hour: 8))
        return profile
    }

    func testStoreWithoutARecomputeShowsTheRecordedFigure() {
        let store = TrendStore(summaries: [summary("2026-05-10")], range: .all)
        XCTAssertEqual(store.points(metric: .patch).map(\.value), [70.0])
    }

    // MARK: - Fixtures

    private func recompute(_ summaries: [DailySummary]) -> [String: Double] {
        TrendStore.recomputePatchPct(dataDir: dataDir, summaries: summaries)
    }

    private func summary(
        _ date: String, patchPct: Double? = 70.0, basis: String? = nil
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: patchPct,
            patchPctBasis: basis
        )
    }

    /// `hour` hours into `day` (`yyyy-MM-dd`), in local time — the zone summary dates
    /// and snapshot stamps are both read in.
    private func instant(_ day: String, hour: Double) throws -> Date {
        let midnight = try XCTUnwrap(SummaryJSONParser.dateFormatter.date(from: day))
        return midnight.addingTimeInterval(hour * 3600)
    }

    /// The canonical `saveSnapshot` filename stamp for `date`.
    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        return formatter.string(from: date)
    }

    private func patchDir() throws -> URL {
        let dir = dataDir.appendingPathComponent("patch-status", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `patch-status` snapshot stamped for `date` unless `name` overrides the filename.
    /// `rows` are (title, on_latest, total); the default is the three-title fixture.
    private func writePatchSnapshot(
        at date: Date,
        rows: [(String, Int, Int)] = [("Chrome", 450, 500), ("Zoom", 20, 100), ("Slack", 10, 10)],
        name: String? = nil,
        mtime: Date? = nil
    ) throws {
        let objects: [[String: Any]] = rows.enumerated().map { index, row in
            GoldenFleetWorkspace.patchRow(
                id: "\(index)", title: row.0, onLatest: row.1, total: row.2)
        }
        let url = try patchDir()
            .appendingPathComponent(name ?? "patch-status_\(stamp(date)).json")
        try JSONSerialization.data(withJSONObject: objects).write(to: url)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    private func writeUndecodableSnapshot(at date: Date) throws {
        let url = try patchDir().appendingPathComponent("patch-status_\(stamp(date)).json")
        try Data("not json {".utf8).write(to: url)
    }
}
