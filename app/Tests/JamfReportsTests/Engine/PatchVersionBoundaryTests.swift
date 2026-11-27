import XCTest
@testable import JamfReports

/// Window, percentile and version-date edges the 2.13 mutation sweep left unpinned.
final class PatchVersionBoundaryTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func day(_ offset: Double) -> Date { start.addingTimeInterval(offset * 86_400) }

    private func rows(
        _ points: [(Double, String, Int, Int)], title: String = "Title"
    ) -> [PatchVelocityBuilder.DayRows] {
        points.map { offset, latest, onLatest, total in
            PatchVelocityBuilder.DayRows(date: day(offset), rows: [PatchStatusRow(
                title: title, id: "1", onLatest: onLatest, onOther: 0, total: total,
                latest: latest, compliancePct: "")])
        }
    }

    private func released(_ version: String, on offset: Double) -> ReleaseDateLookup {
        ReleaseDateLookup(
            versionRows: [PatchVersionDate(
                titleId: "1", title: "Title", version: version,
                releaseDate: ISO8601DateFormatter().string(from: day(offset)))],
            releaseFilesNewestFirst: [])
    }

    private func window(_ points: [(Double, String, Int, Int)], release: Double? = 0)
        -> VersionWindow? {
        let lookup = release.map { released("A", on: $0) }
            ?? ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: [])
        return PatchVelocityBuilder.versions(days: rows(points), lookup: lookup)
            .first?.windows.first
    }

    // MARK: - Windows

    func testAShareIsCappedAtOneHundred() throws {
        let window = try XCTUnwrap(window([(0, "A", 120, 100)]))
        XCTAssertEqual(window.series.map(\.adoptionPct), [100])
    }

    func testFiftyAndNinetyAreTheirOwnCrossings() throws {
        let window = try XCTUnwrap(
            window([(0, "A", 10, 100), (1, "A", 60, 100), (3, "A", 95, 100)]))
        XCTAssertEqual(window.daysTo50, 1)
        XCTAssertEqual(window.daysTo90, 3)
    }

    func testExactlyNinetyIsAtNinety() throws {
        let already = try XCTUnwrap(window([(0, "A", 90, 100), (1, "A", 95, 100)]))
        XCTAssertEqual(already.outcome, .alreadyAt90)
        XCTAssertNil(already.crossedAt90)
        XCTAssertNil(already.daysTo90, "the crossing predates the first point")
        let crossed = try XCTUnwrap(window([(0, "A", 10, 100), (2, "A", 90, 100)]))
        XCTAssertEqual(crossed.outcome, .crossed)
        XCTAssertEqual(crossed.crossedAt90, day(2))
        XCTAssertEqual(crossed.daysTo90, 2)
    }

    func testAVersionTakesItsNewestTitle() {
        let versions = PatchVelocityBuilder.versions(
            days: rows([(0, "A", 10, 100)], title: "Old") + rows([(1, "A", 20, 100)], title: "New"),
            lookup: ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: []))
        XCTAssertEqual(versions.first?.title, "New")
    }

    // MARK: - The fleet figure

    private func crossed(on offset: Double, days: Int) -> VersionVelocity {
        VersionVelocity(titleId: "\(offset)-\(days)", title: "T", version: "A", releaseDate: day(0),
                        windows: [VersionWindow(
                            start: day(offset - 1), end: nil,
                            series: [(day(offset - 1), 10), (day(offset), 95)],
                            releaseDate: day(0), daysTo50: nil, daysTo90: days)])
    }

    func testThePeriodIncludesBothEnds() {
        let now = day(100)
        let since = now.addingTimeInterval(-90 * 86_400)
        let atSince = crossed(on: 10, days: 1)
        XCTAssertEqual(atSince.windows[0].crossedAt90, since)
        XCTAssertEqual(PatchVelocityBuilder.summary([atSince], now: now).crossed, 1)
        func count(_ offset: Double) -> Int {
            PatchVelocityBuilder.summary([crossed(on: offset, days: 1)], now: now).crossed
        }
        XCTAssertEqual(count(100), 1)
        XCTAssertEqual(count(101), 0,
                       "a crossing after now is outside the period")
    }

    func testAnAlreadyAtNinetyWindowBeforeThePeriodIsNotCounted() {
        let old = VersionVelocity(titleId: "1", title: "T", version: "A", releaseDate: nil,
                                  windows: [VersionWindow(start: day(0), end: nil,
                                                          series: [(day(0), 95)], releaseDate: nil,
                                                          daysTo50: nil, daysTo90: nil)])
        XCTAssertEqual(PatchVelocityBuilder.summary([old], now: day(200)).alreadyAt90, 0)
        XCTAssertEqual(PatchVelocityBuilder.summary([old], now: day(10)).alreadyAt90, 1)
    }

    private func summary(_ days: [Int]) -> FleetVersionSummary {
        PatchVelocityBuilder.summary(days.map { crossed(on: 50, days: $0) }, now: day(60))
    }

    func testTheMedianAndNinetiethPercentileAreNearestRankOverSortedDays() {
        XCTAssertEqual(summary([10, 1, 2, 3, 4]).median, 3, "sorted first")
        XCTAssertEqual(summary(Array(1...6)).median, 3, "rank ceil(0.5 × 6) = 3")
        XCTAssertEqual(summary(Array(1...19)).p90, 18, "rank ceil(0.9 × 19) = 18")
    }

    func testNearestRankRoundsUpAndClamps() {
        XCTAssertEqual(PatchVelocityBuilder.nearestRank(90, of: Array(1...6)), 6, "5.4 rounds up")
        XCTAssertEqual(PatchVelocityBuilder.nearestRank(0, of: [5, 6]), 5)
        XCTAssertEqual(PatchVelocityBuilder.nearestRank(150, of: [5, 6]), 6)
    }

    // MARK: - Version dates

    private func dataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(PatchReleaseDateService.versionDatesKind),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private let stampFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    @discardableResult
    private func sidecar(_ text: String, at date: Date, in dir: URL) throws -> String {
        let stamp = stampFormat.string(from: date)
        let kind = PatchReleaseDateService.versionDatesKind
        try text.write(to: dir.appendingPathComponent("\(kind)/\(kind)_\(stamp).json"),
                       atomically: true, encoding: .utf8)
        return stamp
    }

    func testASidecarStampedInsideTheClockSkewIsRead() throws {
        let dir = try dataDir()
        let date = stampFormat.date(from: "20261125T120000")!
        try sidecar("[]", at: date, in: dir)
        XCTAssertEqual(PatchReleaseDateService.versionDateFiles(
            dataDir: dir, now: date.addingTimeInterval(-60)).count, 1)
    }

    func testAnUnreadableNewestCarriesFromTheNewestReadable() throws {
        let dir = try dataDir()
        let base = stampFormat.date(from: "20261120T120000")!
        try sidecar(#"[{"title_id":"1","version":"old"}]"#, at: base, in: dir)
        let mid = try sidecar(#"[{"title_id":"1","version":"mid"}]"#,
                              at: base.addingTimeInterval(86_400), in: dir)
        try sidecar("not json", at: base.addingTimeInterval(2 * 86_400), in: dir)
        let read = PatchReleaseDateService.newestAndCarryable(
            dataDir: dir, now: base.addingTimeInterval(3 * 86_400))
        guard case .rows(let rows, let stamp, _) = read.carryable else {
            return XCTFail("carryable rows expected")
        }
        XCTAssertEqual(stamp, mid)
        XCTAssertEqual(rows.map(\.version), ["mid"])
    }

    func testAFileWithNoStampIsUnreadable() throws {
        let dir = try dataDir()
        let url = dir.appendingPathComponent(PatchReleaseDateService.versionDatesKind)
            .appendingPathComponent("x_garbage.json")
        try "[]".write(to: url, atomically: true, encoding: .utf8)
        guard case .unreadable = PatchReleaseDateService.versionDates(at: url) else {
            return XCTFail("a file with no stamp is not read")
        }
    }

    func testASidecarExactlyAtTheRefreshIntervalIsNotRewritten() throws {
        let rows = [PatchVersionDate(titleId: "1", title: "T", version: "1.0")]
        let first = PatchReleaseDateService.patchVersionDatesUpdate(
            answered: ["1": rows], currentTitles: ["1": "T"], previous: .absent,
            now: Date(), refreshAfter: 86_400)
        let stamp = "20261125T120000"
        let written = try XCTUnwrap(PatchReleaseDateService.stampDate(stamp))
        let again = PatchReleaseDateService.patchVersionDatesUpdate(
            answered: ["1": rows], currentTitles: ["1": "T"],
            previous: .rows(first.rows, stamp: stamp, bytes: first.data),
            now: written.addingTimeInterval(86_400), refreshAfter: 86_400)
        XCTAssertFalse(again.changed)
    }

    func testRowsAreOrderedByTitleThenVersion() {
        let update = PatchReleaseDateService.patchVersionDatesUpdate(
            answered: ["2": [PatchVersionDate(titleId: "2", title: "B", version: "a")],
                       "1": [PatchVersionDate(titleId: "1", title: "A", version: "b"),
                             PatchVersionDate(titleId: "1", title: "A", version: "a")]],
            currentTitles: ["1": "A", "2": "B"], previous: .absent, now: Date(),
            refreshAfter: 86_400)
        XCTAssertEqual(update.rows.map { "\($0.titleId) \($0.version ?? "")" },
                       ["1 a", "1 b", "2 a"])
    }

    // MARK: - Release-date lookup

    private func iso(_ offset: Double) -> String {
        ISO8601DateFormatter().string(from: day(offset))
    }

    private func sofa(_ offset: Double) -> Date? { SOFAFeedService.parseSOFADate(iso(offset)) }

    func testAnAnsweredSidecarDateWinsAndTheFirstRowOfAKeyWins() {
        let lookup = ReleaseDateLookup(
            versionRows: [
                PatchVersionDate(titleId: "1", title: "T", version: "1.0", releaseDate: iso(1)),
                PatchVersionDate(titleId: "1", title: "T", version: "1.0", releaseDate: iso(2)),
            ],
            releaseFilesNewestFirst: [[.init(titleId: "1", title: "T", latestVersion: "1.0",
                                             releaseDate: iso(3))]])
        XCTAssertEqual(lookup.date(titleId: "1", title: "T", version: "1.0"), sofa(1))
    }

    func testTheNewestReleaseFileDatesTheTitle() {
        let lookup = ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: [
            [.init(titleId: "1", title: "T", latestVersion: "2.0", releaseDate: iso(5))],
            [.init(titleId: "1", title: "T", latestVersion: "1.0", releaseDate: iso(1))],
        ])
        XCTAssertEqual(lookup.latestReleaseDate(titleId: "1", title: "T"), sofa(5))
    }

    func testABlankTitleIsNoNameKey() {
        let lookup = ReleaseDateLookup(
            versionRows: [
                PatchVersionDate(titleId: "1", title: "", version: "1.0", releaseDate: iso(1)),
            ],
            releaseFilesNewestFirst: [])
        XCTAssertNil(lookup.date(titleId: "2", title: "", version: "1.0"))
    }
}
