import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 C1: a summary without `patchPctBasis` recorded the unweighted per-title mean.
/// `TrendStore.recomputePatchPct` replaces that figure, for the Trends screen only, with the
/// device-weighted one from the newest `patch-status` snapshot stamped the same local day.
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
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "patchrecompute"
        let workspace = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
        let summariesDir = workspace
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(
            at: summariesDir, withIntermediateDirectories: true)
        for day in ["2026-05-10", "2026-05-11"] {
            let payload: [String: Any] = [
                "date": day, "totalDevices": 100, "patchPct": 70.0, "source": "jamf-cli",
            ]
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: summariesDir.appendingPathComponent("summary_\(day).json"))
        }
        dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try writePatchSnapshot(at: instant("2026-05-10", hour: 8))

        let snapshot = TrendStore.computeSnapshot(profile: profile)
        XCTAssertEqual(Array(snapshot.patchPctRecompute.keys), ["2026-05-10"])

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

    func testStoreWithoutARecomputeShowsTheRecordedFigure() {
        let store = TrendStore(summaries: [summary("2026-05-10")], range: .all)
        XCTAssertEqual(store.points(metric: .patch).map(\.value), [70.0])
    }

    func testProfileSwitchDropsTheRecompute() throws {
        let store = TrendStore()
        let snap = TrendStore.TrendSnapshot(
            summaries: [summary("2026-05-10")], latestSnapshotDate: nil,
            hasEverFetchedLive: true, bandSeries: [:], baselineNames: [],
            patchPctRecompute: ["2026-05-10": 78.0])
        store.apply(snap, profile: "a", range: .all, generation: store.beginLoading())
        XCTAssertEqual(store.points(metric: .patch).map(\.value), [78.0])

        store.clearForProfileSwitch(to: "b")
        let other = TrendStore.TrendSnapshot(
            summaries: [summary("2026-05-10")], latestSnapshotDate: nil,
            hasEverFetchedLive: true, bandSeries: [:], baselineNames: [])
        store.apply(other, profile: "b", range: .all, generation: store.beginLoading())
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
