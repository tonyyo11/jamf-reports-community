import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 E1: summaries written before 2.6.0 never recorded
/// `mobileDeviceCount`, so the Managed Devices trend's mobile series started at the
/// upgrade even though dated `mobile-devices-list` snapshots were on disk.
/// `TrendStore.backfillMobileCounts` replays the summary writer's pick for each
/// such day; these pin that it picks the same file the writer would have.
final class TrendStoreMobileBackfillTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-MobileBackfill-\(UUID().uuidString)", isDirectory: true)
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Selection

    func testNilDayIsFilledFromASameDaySnapshot() throws {
        try writeMobileSnapshot(count: 7, at: instant("2026-05-10", hour: 14))

        XCTAssertEqual(backfill([summary("2026-05-10")]), ["2026-05-10": 7])
    }

    /// A day is never filled from a snapshot taken after it ended.
    func testLaterSnapshotNeverFillsAnEarlierDay() throws {
        try writeMobileSnapshot(count: 7, at: instant("2026-05-11", hour: 0.5))

        XCTAssertEqual(backfill([summary("2026-05-10")]), [:])
    }

    /// A day that recorded its own count is never backfilled, and the chart keeps
    /// the recorded value even when a backfill entry exists for that day.
    func testRecordedCountWins() throws {
        try writeMobileSnapshot(count: 7, at: instant("2026-05-10", hour: 14))
        XCTAssertEqual(backfill([summary("2026-05-10", mobile: 12)]), [:])

        let store = TrendStore()
        let snap = TrendStore.TrendSnapshot(
            summaries: [summary("2026-05-09"), summary("2026-05-10", mobile: 12)],
            latestSnapshotDate: nil, hasEverFetchedLive: true,
            bandSeries: [:], baselineNames: [],
            mobileCountBackfill: ["2026-05-09": 5, "2026-05-10": 99]
        )
        store.apply(snap, profile: "prod", range: .all, generation: store.beginLoading())

        let mobile = store.managedDeviceSeries().first { $0.label == "Mobile devices" }
        XCTAssertEqual(mobile?.points.map(\.value), [5, 12])
    }

    /// The writer's `max_cache_age_hours` rule: a snapshot older than the limit at the
    /// day's end is absent, and `<= 0` lifts the limit.
    func testSnapshotOlderThanTheMaxAgeGivesNoPoint() throws {
        try writeMobileSnapshot(count: 7, at: instant("2026-05-10", hour: 12))
        let day = [summary("2026-05-20")]  // 252 h after the snapshot at the day's end

        XCTAssertEqual(backfill(day, maxCacheAgeHours: 168), [:])
        XCTAssertEqual(backfill(day, maxCacheAgeHours: 300), ["2026-05-20": 7])
        XCTAssertEqual(backfill(day, maxCacheAgeHours: 0), ["2026-05-20": 7],
                       "0 keeps cache forever, as it does for the summary writer")
    }

    /// Both files would be the newest that day without the snapshot pickers'
    /// exclusions — unstamped, they order by an mtime later than the real stamp —
    /// and both decode as device lists.
    func testManifestAndSyncConflictCopyAreIgnored() throws {
        try writeMobileSnapshot(count: 7, at: instant("2026-05-10", hour: 8))
        let evening = try instant("2026-05-10", hour: 20)
        try writeMobileSnapshot(count: 50, at: evening, name: "manifest.json", mtime: evening)
        try writeMobileSnapshot(
            count: 99, at: evening, name: "mobile-devices-list_20260510T200000 2.json",
            mtime: evening
        )

        XCTAssertEqual(backfill([summary("2026-05-10")]), ["2026-05-10": 7])
    }

    /// An undecodable file is skipped for the next-newest eligible snapshot, on
    /// every day that selects it.
    func testUndecodableFileIsSkippedForTheNextNewest() throws {
        try writeMobileSnapshot(count: 5, at: instant("2026-05-09", hour: 10))
        try writeUndecodableSnapshot(at: instant("2026-05-10", hour: 9))

        XCTAssertEqual(
            backfill([summary("2026-05-10"), summary("2026-05-11")]),
            ["2026-05-10": 5, "2026-05-11": 5]
        )
    }

    func testDayWhoseOnlySnapshotIsUndecodableGetsNoPoint() throws {
        try writeUndecodableSnapshot(at: instant("2026-05-10", hour: 9))

        XCTAssertEqual(backfill([summary("2026-05-10")]), [:])
    }

    func testNoMobileDirectoryMeansNoBackfill() {
        XCTAssertEqual(backfill([summary("2026-05-10")]), [:])
    }

    // MARK: - Wiring

    /// End to end through `computeSnapshot`: a summary without a mobile count gets
    /// its point from the workspace's own `mobile-devices-list` snapshots.
    func testComputeSnapshotBackfillsTheManagedDevicesMobileSeries() throws {
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "backfilltest"
        let workspace = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
        let summariesDir = workspace
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(
            at: summariesDir, withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "date": "2026-05-10", "totalDevices": 100, "source": "jamf-cli",
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: summariesDir.appendingPathComponent("summary_2026-05-10.json"))
        dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try writeMobileSnapshot(count: 4, at: instant("2026-05-10", hour: 8))

        let snapshot = TrendStore.computeSnapshot(profile: profile)
        XCTAssertEqual(snapshot.mobileCountBackfill, ["2026-05-10": 4])

        let store = TrendStore()
        store.apply(snapshot, profile: profile, range: .all, generation: store.beginLoading())
        let mobile = store.managedDeviceSeries().first { $0.label == "Mobile devices" }
        XCTAssertEqual(mobile?.points.map(\.value), [4])
    }

    // MARK: - Fixtures

    private func backfill(
        _ summaries: [DailySummary], maxCacheAgeHours: Int = 168
    ) -> [String: Int] {
        TrendStore.backfillMobileCounts(
            dataDir: dataDir, summaries: summaries, maxCacheAgeHours: maxCacheAgeHours
        )
    }

    private func summary(_ date: String, mobile: Int? = nil) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            mobileDeviceCount: mobile
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

    private func mobileDir() throws -> URL {
        let dir = dataDir.appendingPathComponent("mobile-devices-list", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `mobile-devices-list` snapshot of `count` devices, stamped for `date` unless
    /// `name` overrides the filename. `mtime` pins the modification date, which is
    /// what an unstamped file is ordered by.
    private func writeMobileSnapshot(
        count: Int, at date: Date, name: String? = nil, mtime: Date? = nil
    ) throws {
        let rows: [[String: Any]] = (0..<count).map { i in
            ["id": "\(i)", "name": "iPad-\(i)", "model": "iPad", "type": "iPad"]
        }
        let url = try mobileDir()
            .appendingPathComponent(name ?? "mobile-devices-list_\(stamp(date)).json")
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: url.path
            )
        }
    }

    private func writeUndecodableSnapshot(at date: Date) throws {
        let url = try mobileDir()
            .appendingPathComponent("mobile-devices-list_\(stamp(date)).json")
        try Data("not json {".utf8).write(to: url)
    }
}
