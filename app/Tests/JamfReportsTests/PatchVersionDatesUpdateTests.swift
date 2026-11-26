import XCTest
@testable import JamfReports

/// The `patch-version-dates` sidecar: what a walk keeps, when it writes, and how the release
/// dates are looked up.
final class PatchVersionDatesUpdateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let week: TimeInterval = 7 * 86_400

    private func row(_ title: String, _ version: String, order: String?, date: String? = nil)
        -> PatchVersionDate {
        PatchVersionDate(titleId: title, title: "Title \(title)", version: version,
                         releaseDate: date, absoluteOrderId: order)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func update(
        _ answered: [String: [PatchVersionDate]], titles: [String],
        previous: VersionDatesRead = .absent, refreshAfter: TimeInterval? = nil
    ) -> (rows: [PatchVersionDate], data: Data, changed: Bool) {
        PatchReleaseDateService.patchVersionDatesUpdate(
            answered: answered,
            currentTitles: Dictionary(uniqueKeysWithValues: titles.map { ($0, "Title \($0)") }),
            previous: previous, now: now, refreshAfter: refreshAfter ?? week)
    }

    // MARK: - Update

    func testAnUnchangedWalkIsNotChangedAndKeyOrderDoesNotMatter() {
        let first = update(["1": [row("1", "2.0", order: "0"), row("1", "1.0", order: "1")]],
                           titles: ["1"])
        XCTAssertTrue(first.changed, "no earlier file")
        let previous = VersionDatesRead.rows(first.rows, stamp: stamp(now), bytes: first.data)
        let again = update(["1": [row("1", "1.0", order: "1"), row("1", "2.0", order: "0")]],
                           titles: ["1"], previous: previous)
        XCTAssertFalse(again.changed)
        XCTAssertEqual(again.data, first.data)
    }

    func testANewVersionChangesTheFile() {
        let first = update(["1": [row("1", "1.0", order: "0")]], titles: ["1"])
        let previous = VersionDatesRead.rows(first.rows, stamp: stamp(now), bytes: first.data)
        let next = update(["1": [row("1", "2.0", order: "0"), row("1", "1.0", order: "1")]],
                          titles: ["1"], previous: previous)
        XCTAssertTrue(next.changed)
    }

    func testATitleThatDidNotAnswerCarriesItsRowsWithTheirFirstStamp() {
        let earlier = stamp(now.addingTimeInterval(-3_600))
        let first = update(["1": [row("1", "1.0", order: "0")], "2": [row("2", "5", order: "0")]],
                           titles: ["1", "2"])
        let carried = update(["2": [row("2", "5", order: "0")]], titles: ["1", "2"],
                             previous: .rows(first.rows, stamp: earlier, bytes: first.data))
        XCTAssertEqual(carried.rows.first { $0.titleId == "1" }?.staleSince, earlier)
        XCTAssertNil(carried.rows.first { $0.titleId == "2" }?.staleSince)
        let later = update(["2": [row("2", "5", order: "0")]], titles: ["1", "2"],
                           previous: .rows(carried.rows, stamp: stamp(now), bytes: carried.data))
        XCTAssertEqual(later.rows.first { $0.titleId == "1" }?.staleSince, earlier,
                       "the stamp is kept, so the file does not change on every walk")
        XCTAssertFalse(later.changed)
    }

    func testATitleGoneFromPatchStatusIsDropped() {
        let first = update(["1": [row("1", "1.0", order: "0")], "2": [row("2", "5", order: "0")]],
                           titles: ["1", "2"])
        let next = update(["1": [row("1", "1.0", order: "0")]], titles: ["1"],
                          previous: .rows(first.rows, stamp: stamp(now), bytes: first.data))
        XCTAssertEqual(Set(next.rows.map(\.titleId)), ["1"])
    }

    func testAnEmptyAnswerIsAMarkerRowWithNoVersionKey() throws {
        let result = update(["1": []], titles: ["1"])
        XCTAssertEqual(result.rows, [PatchVersionDate(titleId: "1", title: "Title 1", noVersions: true)])
        let text = String(decoding: result.data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"version\""), text)
        XCTAssertFalse(text.contains("null"), text)
    }

    func testAnUnreadableEarlierFileMeansAFullWrite() {
        let result = update(["1": [row("1", "1.0", order: "0")]], titles: ["1"],
                            previous: .unreadable("could not be decoded"))
        XCTAssertTrue(result.changed)
    }

    func testAnAgedFileIsWrittenAgainEvenWhenUnchanged() {
        let first = update(["1": [row("1", "1.0", order: "0")]], titles: ["1"])
        let old = VersionDatesRead.rows(
            first.rows, stamp: stamp(now.addingTimeInterval(-2 * 86_400)), bytes: first.data)
        XCTAssertTrue(update(["1": [row("1", "1.0", order: "0")]], titles: ["1"],
                             previous: old, refreshAfter: 1.5 * 86_400).changed)
        XCTAssertFalse(update(["1": [row("1", "1.0", order: "0")]], titles: ["1"],
                              previous: old, refreshAfter: week).changed)
    }

    func testRowsSortByTitleThenOrderAsANumberWithNonNumbersLast() {
        let result = update(["1": [row("1", "b", order: "10"), row("1", "z", order: nil),
                                   row("1", "a", order: "2")]], titles: ["1"])
        XCTAssertEqual(result.rows.map(\.version), ["a", "b", "z"])
    }

    func testDefinitionsAreTrimmedAndOneWithNoVersionIsDropped() {
        let rows = PatchReleaseDateService.versionRows(
            fromDefinitions: [["version": " 2.0 ", "releaseDate": " ", "absoluteOrderId": 0],
                              ["version": "  ", "releaseDate": "2026-01-01T00:00:00Z"]],
            titleId: "1", title: "T")
        XCTAssertEqual(rows, [PatchVersionDate(titleId: "1", title: "T", version: "2.0",
                                               releaseDate: nil, absoluteOrderId: "0")])
    }

    func testAHundredRowTitleIsKeptWhole() {
        let rows = (0..<100).map { row("1", "v\($0)", order: "\($0)") }
        XCTAssertEqual(update(["1": rows], titles: ["1"]).rows.count, 100)
        let model = PatchVersionHistoryModel(
            titleId: "1", versions: [], dates: .rows(rows, stamp: stamp(now), bytes: Data()))
        XCTAssertTrue(model.notes.contains(.newest100))
    }

    // MARK: - Refresh interval

    func testTheRefreshIntervalFollowsRetention() {
        let interval = PatchReleaseDateService.patchVersionRefreshInterval
        XCTAssertEqual(interval(nil), week)
        XCTAssertEqual(interval(RetentionConfig(enabled: false, snapshotKeepDays: 3)), week)
        XCTAssertEqual(interval(RetentionConfig(enabled: true, snapshotKeepDays: 0)), week)
        XCTAssertEqual(interval(RetentionConfig(enabled: true, snapshotKeepDays: 3)), 1.5 * 86_400)
        XCTAssertEqual(interval(RetentionConfig(enabled: true, snapshotKeepDays: 30)), week)
    }

    // MARK: - Reading and the lookup

    func testVersionDatesReadsAbsentUnreadableAndRows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(PatchReleaseDateService.versionDates(dataDir: dir), .absent)
        let folder = dir.appendingPathComponent(PatchReleaseDateService.versionDatesKind)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("patch-version-dates_20261125T060000.json")
        try Data("not json".utf8).write(to: file)
        guard case .unreadable = PatchReleaseDateService.versionDates(dataDir: dir) else {
            return XCTFail("a file that does not decode is unreadable, not absent")
        }
        let data = update(["1": [row("1", "1.0", order: "0")]], titles: ["1"]).data
        try data.write(to: file)
        guard case .rows(let rows, let stamp, _) = PatchReleaseDateService.versionDates(dataDir: dir)
        else { return XCTFail("expected rows") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(stamp, "20261125T060000")
    }

    func testTheLookupPrefersAnsweredThenReleasedThenCarried() throws {
        let answered = row("1", "2.0", order: "0", date: "2026-02-01T00:00:00Z")
        var carried = row("1", "1.0", order: "1", date: "2026-01-01T00:00:00Z")
        carried.staleSince = "20260101T000000"
        let undated = row("1", "3.0", order: "0")
        let released = PatchReleaseDateService.Row(
            titleId: "1", title: "Title 1", latestVersion: "1.0",
            releaseDate: "2026-01-15T00:00:00Z")
        let lookup = ReleaseDateLookup(versionRows: [answered, carried, undated],
                                       releaseFilesNewestFirst: [[released]])
        let day = { (iso: String) in SOFAFeedService.parseSOFADate(iso) }
        XCTAssertEqual(lookup.date(titleId: "1", title: "Title 1", version: "2.0"),
                       day("2026-02-01T00:00:00Z"))
        XCTAssertEqual(lookup.date(titleId: "1", title: "Title 1", version: "1.0"),
                       day("2026-01-15T00:00:00Z"), "a released row beats a carried one")
        XCTAssertNil(lookup.date(titleId: "1", title: "Title 1", version: "3.0"),
                     "an answered row with no date falls through to nothing here")
        XCTAssertEqual(lookup.date(titleId: "9", title: "title 1", version: "2.0"),
                       day("2026-02-01T00:00:00Z"), "the name matches when the ID does not")
    }

    /// The existing kind keeps its shape: the same four keys, pretty printed, now at 0600.
    func testThePatchReleaseDatesFileKeepsItsShape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ReportEngine.writePatchReleaseDates(
            [["title_id": "1", "title": "T", "latest_version": "1.0",
              "release_date": "2026-01-01T00:00:00Z"]],
            stamp: "20261125T060000", dataDir: dir)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: String]])
        XCTAssertEqual(object.first.map { Set($0.keys) },
                       ["title_id", "title", "latest_version", "release_date"])
        XCTAssertEqual(PatchReleaseDateService.load(from: url).first?.latestVersion, "1.0")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    /// Release-date files older than `releaseFileDays` are not read; the sidecar still dates
    /// an older version.
    func testReleaseFilesOlderThanTheCapAreNotRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = now.addingTimeInterval(-Double(PatchReleaseDateService.releaseFileDays + 10) * 86_400)
        try ReportEngine.writePatchReleaseDates(
            [["title_id": "1", "title": "T", "latest_version": "1.0",
              "release_date": "2025-01-01T00:00:00Z"]],
            stamp: stamp(old), dataDir: dir)
        // An empty `releaseRows` means no newest file was passed, so the cap applies to all.
        func lookup() -> ReleaseDateLookup {
            PatchReleaseDateService.releaseDateLookup(
                releaseRows: [], dataDir: dir,
                versionDates: PatchReleaseDateService.versionDates(dataDir: dir), now: now)
        }
        XCTAssertNil(lookup().date(titleId: "1", title: "T", version: "1.0"))
        let side = update(["1": [row("1", "1.0", order: "0", date: "2025-01-01T00:00:00Z")]],
                          titles: ["1"])
        try ReportEngine.writePatchVersionDates(side.data, stamp: stamp(now), dataDir: dir)
        XCTAssertNotNil(lookup().date(titleId: "1", title: "T", version: "1.0"))
    }

    /// The clock a caller passes reaches the cap: a file 200 days before today but 20 days
    /// before the given `now` is read.
    func testTheInjectedClockReachesTheCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let past = Date().addingTimeInterval(-180 * 86_400)
        let fileDay = past.addingTimeInterval(-20 * 86_400)
        try ReportEngine.writePatchReleaseDates(
            [["title_id": "1", "title": "T", "latest_version": "1.0",
              "release_date": "2025-03-01T00:00:00Z"]],
            stamp: stamp(fileDay), dataDir: dir)
        let status = dir.appendingPathComponent("patch-status")
        try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
        for offset in [0, 1] {
            let json = #"[{"title":"T","id":"1","on_latest":\#(offset == 0 ? 10 : 95),"#
                + #""on_other":0,"total":100,"latest":"1.0","compliance_pct":""}]"#
            try Data(json.utf8).write(to: status.appendingPathComponent(
                "patch-status_\(stamp(fileDay.addingTimeInterval(Double(offset) * 86_400))).json"))
        }
        let history = PatchVelocityBuilder.computeWithVersions(
            dataDir: dir, releaseRows: [], now: past)
        XCTAssertEqual(history.versions.first?.releaseDate,
                       SOFAFeedService.parseSOFADate("2025-03-01T00:00:00Z"))
        let today = PatchVelocityBuilder.computeWithVersions(dataDir: dir, releaseRows: [])
        XCTAssertNil(today.versions.first?.releaseDate, "past the cap from today")
    }

    /// One odd row costs that row; an unreadable newest file is carried over from the newest
    /// readable earlier one, never written back smaller.
    func testRowsDecodeAloneAndAnUnreadableNewestFileIsCarried() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lenient-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = now.addingTimeInterval(-2 * 86_400)
        try ReportEngine.writePatchVersionDates(
            Data(#"[{"title_id":"1","version":"2.0"},{"title_id":7},{"title_id":"2","version":"1.0"}]"#.utf8),
            stamp: stamp(older), dataDir: dir)
        guard case .rows(let rows, _, _) = PatchReleaseDateService.versionDates(dataDir: dir) else {
            return XCTFail("one bad row does not make the file unreadable")
        }
        XCTAssertEqual(rows.map(\.titleId), ["1", "2"])

        try ReportEngine.writePatchVersionDates(
            Data("{bad".utf8), stamp: stamp(now.addingTimeInterval(-86_400)), dataDir: dir)
        guard case .unreadable = PatchReleaseDateService.versionDates(dataDir: dir, now: now) else {
            return XCTFail("the newest file is the bad one")
        }
        guard case .rows(let carried, let carriedStamp, _) =
                PatchReleaseDateService.newestAndCarryable(dataDir: dir, now: now).carryable else {
            return XCTFail("carried from the newest readable file")
        }
        XCTAssertEqual(carried.count, 2)
        XCTAssertEqual(carriedStamp, stamp(older))

        let lines = VersionLines()
        ReportEngine.updatePatchVersionDates(
            answered: [:], currentTitles: ["1": "One", "2": "Two"], refreshAfter: week,
            dataDir: dir, now: now, onLine: lines.append)
        guard case .rows(let rewritten, _, _) = PatchReleaseDateService.versionDates(dataDir: dir)
        else { return XCTFail("the bad newest file is replaced") }
        XCTAssertEqual(rewritten.count, 2, "no title's rows are lost")

        // A file stamped in the future is never the newest, so it cannot force every walk to
        // write a new file.
        try ReportEngine.writePatchVersionDates(
            Data("{bad".utf8), stamp: stamp(now.addingTimeInterval(10 * 86_400)), dataDir: dir)
        guard case .rows(let present, _, _) =
                PatchReleaseDateService.versionDates(dataDir: dir, now: now) else {
            return XCTFail("the future-dated file is ignored")
        }
        XCTAssertEqual(present.count, 2)
    }

    /// Only the newest release-date file of each local day is read.
    func testOnlyTheNewestFileOfEachDayIsRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perday-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let morning = Calendar.current.startOfDay(for: now).addingTimeInterval(-86_400 + 3_600)
        try ReportEngine.writePatchReleaseDates(
            [["title_id": "1", "title": "T", "latest_version": "0.9",
              "release_date": "2026-01-01T00:00:00Z"]],
            stamp: stamp(morning), dataDir: dir)
        try ReportEngine.writePatchReleaseDates(
            [["title_id": "1", "title": "T", "latest_version": "1.0",
              "release_date": "2026-02-01T00:00:00Z"]],
            stamp: stamp(morning.addingTimeInterval(3_600)), dataDir: dir)
        let lookup = PatchReleaseDateService.releaseDateLookup(
            releaseRows: [], dataDir: dir, versionDates: .absent, now: now)
        XCTAssertNotNil(lookup.date(titleId: "1", title: "T", version: "1.0"))
        XCTAssertNil(lookup.date(titleId: "1", title: "T", version: "0.9"),
                     "the earlier file of the same day is not read")
    }

    func testACarriedRowIsUsedWhenNothingElseDatesTheVersion() {
        var carried = row("1", "1.0", order: "0", date: "2026-01-01T00:00:00Z")
        carried.staleSince = "20260101T000000"
        let lookup = ReleaseDateLookup(versionRows: [carried], releaseFilesNewestFirst: [])
        XCTAssertEqual(lookup.date(titleId: "1", title: "Title 1", version: "1.0"),
                       SOFAFeedService.parseSOFADate("2026-01-01T00:00:00Z"))
    }

    func testTheTitleLevelDateIsTheNewestFilesRowWhateverItsVersion() {
        let released = PatchReleaseDateService.Row(
            titleId: "1", title: "T", latestVersion: "1.0.0", releaseDate: "2026-03-01T00:00:00Z")
        let lookup = ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: [[released]])
        XCTAssertNil(lookup.date(titleId: "1", title: "T", version: "1.0"))
        XCTAssertEqual(lookup.latestReleaseDate(titleId: "1", title: "T"),
                       SOFAFeedService.parseSOFADate("2026-03-01T00:00:00Z"))
    }

    func testTheNewestReleaseFileWins() {
        let newer = PatchReleaseDateService.Row(titleId: "1", title: "T", latestVersion: "1.0",
                                                releaseDate: "2026-03-01T00:00:00Z")
        let older = PatchReleaseDateService.Row(titleId: "1", title: "T", latestVersion: "1.0",
                                                releaseDate: "2026-01-01T00:00:00Z")
        let lookup = ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: [[newer], [older]])
        XCTAssertEqual(lookup.date(titleId: "1", title: "T", version: "1.0"),
                       SOFAFeedService.parseSOFADate("2026-03-01T00:00:00Z"))
    }
}

private final class VersionLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
    }
}
