import XCTest
@testable import JamfReports

/// Per-version adoption windows and the fleet's days to 90%.
final class PatchVersionWindowTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func day(_ offset: Int) -> Date { start.addingTimeInterval(Double(offset) * 86_400) }

    /// One title per call: `(day offset, latest, onLatest of 100)`; total 0 when `onLatest` is nil.
    private func days(_ points: [(Int, String, Int?)], id: String = "1") -> [PatchVelocityBuilder.DayRows] {
        points.map { offset, latest, onLatest in
            PatchVelocityBuilder.DayRows(date: day(offset), rows: [PatchStatusRow(
                title: "Title \(id)", id: id, onLatest: onLatest ?? 0, onOther: 0,
                total: onLatest == nil ? 0 : 100, latest: latest, compliancePct: "")])
        }
    }

    private func lookup(_ dates: [String: Int]) -> ReleaseDateLookup {
        let formatter = ISO8601DateFormatter()
        return ReleaseDateLookup(
            versionRows: dates.map { version, offset in
                PatchVersionDate(titleId: "1", title: "Title 1", version: version,
                                 releaseDate: formatter.string(from: day(offset)))
            },
            releaseFilesNewestFirst: [])
    }

    private func windows(_ versions: [VersionVelocity], _ version: String) -> [VersionWindow] {
        versions.first { $0.version == version }?.windows ?? []
    }

    func testWindowsFollowLatestAndAReturningVersionOpensANewOne() {
        let versions = PatchVelocityBuilder.versions(
            days: days([(0, "A", 10), (1, "A", 95), (2, "B", 5), (3, "B", 40), (4, "A", 50)]),
            lookup: lookup(["A": 0, "B": 2]))
        let a = windows(versions, "A")
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0].end, day(2))
        XCTAssertEqual(a[0].outcome, .crossed)
        XCTAssertEqual(a[0].daysTo90, 1)
        XCTAssertNil(a[1].end)
        XCTAssertEqual(windows(versions, "B").first?.outcome, .superseded)
        XCTAssertEqual(windows(versions, "B").first?.end, day(4))
    }

    func testABlankLatestAMissingDayAndAZeroTotalAddNoPointAndCloseNothing() {
        let versions = PatchVelocityBuilder.versions(
            days: days([(0, "A", 10), (1, " ", 99), (2, "A", nil), (4, "A", 30)]),
            lookup: lookup([:]))
        let a = windows(versions, "A")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].series.map(\.adoptionPct), [10, 30])
        XCTAssertEqual(a[0].outcome, .open)
    }

    func testAWindowWithNoPointsIsDropped() {
        let versions = PatchVelocityBuilder.versions(
            days: days([(0, "A", nil), (1, "B", 20)]), lookup: lookup([:]))
        XCTAssertTrue(windows(versions, "A").isEmpty)
        XCTAssertEqual(windows(versions, "B").count, 1)
    }

    func testOutcomesComeFromTheSeriesAlone() {
        let already = PatchVelocityBuilder.versions(
            days: days([(0, "A", 92), (1, "A", 97)]), lookup: lookup(["A": 0]))
        XCTAssertEqual(windows(already, "A").first?.outcome, .alreadyAt90)
        XCTAssertNil(windows(already, "A").first?.daysTo90)
        let noDate = PatchVelocityBuilder.versions(
            days: days([(0, "A", 10), (3, "A", 91)]), lookup: lookup([:]))
        XCTAssertEqual(windows(noDate, "A").first?.outcome, .crossed)
        XCTAssertNil(windows(noDate, "A").first?.daysTo90)
    }

    func testDaysToFiftyFollowsTheSameRules() {
        let versions = PatchVelocityBuilder.versions(
            days: days([(2, "A", 60), (3, "A", 70)]), lookup: lookup(["A": 0]))
        XCTAssertNil(windows(versions, "A").first?.daysTo50, "first point already above 50%")
        let early = PatchVelocityBuilder.versions(
            days: days([(0, "A", 10), (1, "A", 55)]), lookup: lookup(["A": 5]))
        XCTAssertEqual(windows(early, "A").first?.daysTo50, 0, "clamped at 0")
    }

    func testTheFleetFigureCountsWindowsAndNeedsFiveForAMedian() {
        var all: [VersionVelocity] = []
        for (index, crossOn) in [1, 2, 3, 4, 10].enumerated() {
            let id = "\(index)"
            let rows = days([(0, "A", 10), (crossOn, "A", 95)], id: id)
            let release = ReleaseDateLookup(
                versionRows: [PatchVersionDate(titleId: id, title: "Title \(id)", version: "A",
                                               releaseDate: ISO8601DateFormatter().string(from: day(0)))],
                releaseFilesNewestFirst: [])
            all += PatchVelocityBuilder.versions(days: rows, lookup: release)
        }
        let summary = PatchVelocityBuilder.summary(all, now: day(20))
        XCTAssertEqual(summary.crossed, 5)
        XCTAssertEqual(summary.median, 3)
        XCTAssertEqual(summary.p90, 10)
        let four = PatchVelocityBuilder.summary(Array(all.prefix(4)), now: day(20))
        XCTAssertNil(four.median)
        XCTAssertEqual(four.crossed, 4)
    }

    func testOtherOutcomesAreCountedApartAndPlacedInThePeriod() {
        let versions = PatchVelocityBuilder.versions(
            days: days([(0, "A", 10), (5, "B", 92), (6, "C", 10)])
                + days([(0, "X", 10), (2, "X", 95)], id: "2"),
            lookup: lookup([:]))
        let summary = PatchVelocityBuilder.summary(versions, now: day(30))
        XCTAssertEqual(summary.superseded, 1, "A closed below 90%")
        XCTAssertEqual(summary.alreadyAt90, 1, "B started at 92%")
        XCTAssertEqual(summary.notYet, 1, "C is open below 90%")
        XCTAssertEqual(summary.noReleaseDate, 1, "X crossed with no release date")
        XCTAssertEqual(summary.crossed, 0)
        let later = PatchVelocityBuilder.summary(versions, now: day(200))
        XCTAssertEqual(later.superseded, 0, "closed before the 90-day period")
        XCTAssertEqual(later.notYet, 1, "an open window always counts")
    }

    func testNearestRank() {
        XCTAssertEqual(PatchVelocityBuilder.nearestRank(50, of: [1, 2, 3, 4]), 2)
        XCTAssertEqual(PatchVelocityBuilder.nearestRank(90, of: [1, 2, 3, 4]), 4)
        XCTAssertNil(PatchVelocityBuilder.nearestRank(50, of: []))
    }

    func testTheLatestWindowIsTheOneOpenedLast() {
        let versions = PatchVelocityBuilder.versions(
            days: days([(0, "A", 10), (1, "B", 20), (2, "A", 30), (3, " ", 40)]),
            lookup: lookup([:]))
        let latest = PatchVelocityBuilder.latestWindowByTitle(versions)["1"]
        XCTAssertEqual(latest?.window.start, day(2))
    }

    /// When the newest named version has no measured day, its window is dropped and Patch
    /// Velocity falls back to the whole series rather than reporting the older version's.
    func testComputeIgnoresAnOlderVersionsWindowWhenTheNewestHasNoPoints() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("patch-status")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for (offset, latest, on, total) in [(0, "A", 10, 100), (1, "A", 95, 100), (2, "B", 0, 0)] {
            let json = #"[{"title":"T","id":"1","on_latest":\#(on),"on_other":0,"#
                + #""total":\#(total),"latest":"\#(latest)","compliance_pct":""}]"#
            try Data(json.utf8).write(to: folder.appendingPathComponent(
                "patch-status_\(formatter.string(from: day(offset))).json"))
        }
        let release = PatchReleaseDateService.Row(
            titleId: "1", title: "T", latestVersion: "A",
            releaseDate: ISO8601DateFormatter().string(from: day(0)))
        let velocity = try XCTUnwrap(PatchVelocityBuilder.computeWithVersions(
            dataDir: dir, releaseRows: [release], now: day(5)).velocities.first)
        // The whole series (A's two days) against the title's newest release row: 1 day to 90%.
        XCTAssertEqual(velocity.daysTo90, 1)
        XCTAssertEqual(velocity.releaseDate, day(0))
    }

    /// Patch Velocity reads its days-to figures from the latest window, so the velocity card
    /// and Version History agree.
    func testComputeMatchesTheLatestWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("patch-status")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let points = [(0, "A", 10), (1, "A", 96), (2, "B", 5), (3, "B", 50), (6, "B", 92),
                      (7, "A", 20), (8, "A", 60), (9, " ", 70)]
        for (offset, latest, on) in points {
            let json = #"[{"title":"T","id":"1","on_latest":\#(on),"on_other":0,"total":100,"#
                + #""latest":"\#(latest)","compliance_pct":""}]"#
            try Data(json.utf8).write(to: folder.appendingPathComponent(
                "patch-status_\(formatter.string(from: day(offset))).json"))
        }
        // A came back on day 7, released then; day 9's `latest` is blank, so A stays current.
        let release = PatchReleaseDateService.Row(
            titleId: "1", title: "T", latestVersion: "A",
            releaseDate: ISO8601DateFormatter().string(from: day(7)))
        let built = PatchVelocityBuilder.computeWithVersions(
            dataDir: dir, releaseRows: [release], now: day(10))
        let velocity = try XCTUnwrap(built.velocities.first)
        let latest = try XCTUnwrap(PatchVelocityBuilder.latestWindowByTitle(built.versions)["1"])
        XCTAssertEqual(latest.window.start, day(7), "A's second window")
        XCTAssertEqual(velocity.daysTo50, latest.window.daysTo50)
        XCTAssertEqual(velocity.daysTo50, 1)
        XCTAssertNil(velocity.daysTo90, "A has not reached 90% in its second window")
        XCTAssertEqual(velocity.daysBehind, 3)
        XCTAssertEqual(velocity.series.count, 8, "the chart keeps every day, blank `latest` included")
    }

    /// Inside one report run the history is read once per data folder and measured against
    /// the run's first "now"; outside a run every call reads again.
    func testOneReportRunReadsTheHistoryOnceWithOneNow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvshare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("patch-status")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let runNow = Date(timeIntervalSince1970: 1_790_000_000)
        for offset in [2, 1] {
            let json = #"[{"title":"T","id":"1","on_latest":50,"on_other":0,"total":100,"#
                + #""latest":"A","compliance_pct":""}]"#
            try Data(json.utf8).write(to: folder.appendingPathComponent(
                "patch-status_\(formatter.string(from: runNow.addingTimeInterval(Double(-offset) * 86_400))).json"))
        }
        let share = PatchHistoryShare()
        share.adopt(now: runNow)
        let (first, second) = PatchVelocityBuilder.$runShare.withValue(share) { () -> (PatchHistory, PatchHistory) in
            let first = PatchVelocityBuilder.computeWithVersions(dataDir: dir, releaseRows: [])
            try? FileManager.default.removeItem(at: folder)
            let second = PatchVelocityBuilder.computeWithVersions(
                dataDir: dir, releaseRows: [], now: Date())
            return (first, second)
        }
        XCTAssertEqual(first.now, runNow, "the run's now, not the call's")
        XCTAssertEqual(second.now, runNow)
        XCTAssertEqual(second.versions.count, first.versions.count, "read once: the folder is gone")
        XCTAssertFalse(first.versions.isEmpty)
        let outside = PatchVelocityBuilder.computeWithVersions(dataDir: dir, releaseRows: [])
        XCTAssertTrue(outside.versions.isEmpty, "no run bound: read again")

        let summary = PatchVelocityBuilder.summary(first.versions, now: runNow)
        XCTAssertEqual(summary.since, runNow.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(summary.now, runNow)
    }
}
