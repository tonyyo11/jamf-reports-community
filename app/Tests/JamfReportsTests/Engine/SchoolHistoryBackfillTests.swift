import XCTest
@testable import JamfReports

/// The one-time School history backfill (`ReportEngine.backfillSchoolHistoryOnce`).
final class SchoolHistoryBackfillTests: XCTestCase {
    private var root: URL!
    private var dataDir: URL!
    private var summariesDir: URL!
    private let kind = SchoolFleetService.devicesKind

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) {
            lock.lock(); defer { lock.unlock() }
            stored.append(line.text)
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("school-backfill-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        dataDir = root.appendingPathComponent("data", isDirectory: true)
        summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent(kind), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mac(_ name: String, checkin: String) -> [String: Any] {
        SchoolRows.device(1, [
            "name": name, "serialNumber": "SCHOOL-SERIAL-\(name)", "os": "macOS 15.1",
            "lastCheckin": checkin,
        ], omitting: ["isSupervised", "udid"])
    }

    private func ipad(_ name: String) -> [String: Any] {
        SchoolRows.device(1, [
            "name": name, "serialNumber": "SCHOOL-SERIAL-\(name)", "os": "iPadOS 18.1",
        ], omitting: ["isManaged", "isSupervised", "lastCheckin", "udid"])
    }

    private func snapshot(_ rows: [[String: Any]], file: String) throws {
        try snapshot(SchoolRows.json(rows), file: file)
    }

    private func snapshot(_ json: String, file: String) throws {
        try Data(json.utf8).write(
            to: dataDir.appendingPathComponent(kind).appendingPathComponent(file))
    }

    private func summary(_ day: String) throws -> DailySummary {
        try SummaryJSONParser.decode(Data(contentsOf:
            summariesDir.appendingPathComponent("summary_\(day).json")))
    }

    private func summaryExists(_ day: String) -> Bool {
        FileManager.default.fileExists(
            atPath: summariesDir.appendingPathComponent("summary_\(day).json").path)
    }

    @discardableResult
    private func backfill(staleDays: Int = 30, lines: Lines = Lines()) -> [String] {
        ReportEngine.backfillSchoolHistoryOnce(
            dataDir: dataDir, summariesDir: summariesDir, staleDays: { staleDays },
            onLine: lines.add)
        return lines.all
    }

    func testThreeDatedSnapshotsWriteThreeSummariesWithTheirOwnCounts() throws {
        try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                     file: "\(kind)_20261001T080000.json")
        try snapshot([mac("A", checkin: "2026-10-02 09:00:00"), ipad("P")],
                     file: "\(kind)_20261002T080000.json")
        try snapshot([mac("A", checkin: "2026-10-03 09:00:00"), ipad("P"), ipad("Q")],
                     file: "\(kind)_20261003T080000.json")

        let lines = backfill()

        let (a, b, c) = (try summary("2026-10-01"), try summary("2026-10-02"),
                         try summary("2026-10-03"))
        XCTAssertEqual([a.totalDevices, b.totalDevices, c.totalDevices], [1, 1, 1])
        XCTAssertEqual([a.mobileDeviceCount, b.mobileDeviceCount, c.mobileDeviceCount], [nil, 1, 2])
        XCTAssertEqual(a.source, "jamf-cli")
        XCTAssertNil(a.fileVaultPct)
        XCTAssertTrue(lines.contains("[info] backfilled 3 days of Jamf School history"), "\(lines)")
    }

    /// A backfilled day carries its mobile figures, but no OS currency for either type: the
    /// cached feed is today's, and an old version list judged against it would read as behind.
    func testABackfilledDayCarriesMobileFiguresAndNoOSCurrency() throws {
        let sofa = dataDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: sofa, withIntermediateDirectories: true)
        for name in ["macos_data_feed.json", "ios_data_feed.json"] {
            try FileManager.default.copyItem(
                at: TestFixtures.dir("sofa").appendingPathComponent(name),
                to: sofa.appendingPathComponent(name))
        }
        let managed = SchoolRows.device(2, [
            "name": "R", "os": "iPadOS 18.1", "lastCheckin": "2026-09-01 09:00:00",
        ], omitting: ["udid"])
        try snapshot([mac("A", checkin: "2026-10-02 09:00:00"), managed],
                     file: "\(kind)_20261002T080000.json")
        backfill()
        let s = try summary("2026-10-02")
        XCTAssertNil(s.osCurrentPct)
        let mobile = try XCTUnwrap(s.mobile)
        XCTAssertEqual(mobile.managed, 1)
        XCTAssertEqual(mobile.supervised, .init(met: 1, of: 1))
        XCTAssertEqual(mobile.stale, 0, "30 whole days is not more than 30, judged as of the stamp")
        XCTAssertNil(mobile.osCurrent)
    }

    func testTheDaysNewestSnapshotWins() throws {
        try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                     file: "\(kind)_20261001T060000.json")
        let checkin = "2026-10-01 09:00:00"
        try snapshot([mac("A", checkin: checkin),mac("B", checkin: checkin)],
                     file: "\(kind)_20261001T200000.json")
        backfill()
        XCTAssertEqual(try summary("2026-10-01").totalDevices, 2)
    }

    func testAnExistingSummaryIsNeverOverwritten() throws {
        try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                     file: "\(kind)_20261001T080000.json")
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        let existing = summariesDir.appendingPathComponent("summary_2026-10-01.json")
        try Data("keep".utf8).write(to: existing)
        backfill()
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
    }

    func testConflictCopyManifestAndUndecodableFileAreSkippedWithOneWarning() throws {
        try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                     file: "\(kind)_20261001T080000.json")
        try snapshot([mac("A", checkin: "2026-10-02 09:00:00")],
                     file: "\(kind)_20261002T080000 2.json")
        try snapshot("[]", file: "manifest.json")
        try snapshot("not json", file: "\(kind)_20261003T080000.json")
        try snapshot("{\"a\":1}", file: "\(kind)_20261004T080000.json")

        let lines = backfill()

        XCTAssertTrue(summaryExists("2026-10-01"))
        XCTAssertFalse(summaryExists("2026-10-02"))
        XCTAssertFalse(summaryExists("2026-10-03"))
        XCTAssertFalse(summaryExists("2026-10-04"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("[warn]") }.count, 1, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("skipped 2 school-devices") }, "\(lines)")
    }

    func testMarkerPreventsASecondPass() throws {
        try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                     file: "\(kind)_20261001T080000.json")
        backfill()
        try FileManager.default.removeItem(
            at: summariesDir.appendingPathComponent("summary_2026-10-01.json"))
        let lines = backfill()
        XCTAssertFalse(summaryExists("2026-10-01"))
        XCTAssertTrue(lines.isEmpty, "\(lines)")
    }

    func testRefusedStateFolderWritesNothingAndWarns() throws {
        try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                     file: "\(kind)_20261001T080000.json")
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dataDir.appendingPathComponent("state"), withDestinationURL: elsewhere)

        let lines = backfill()

        XCTAssertFalse(summaryExists("2026-10-01"))
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("[warn] state is not used") }.count, 1, "\(lines)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testStaleCutOffComesFromTheCaller() throws {
        // Snapshot stamped 2026-10-20; the Mac checked in 10 days earlier.
        try snapshot([mac("A", checkin: "2026-10-10 08:00:00")],
                     file: "\(kind)_20261020T080000.json")
        backfill(staleDays: 7)
        XCTAssertEqual(try summary("2026-10-20").staleCount, 1)

        try FileManager.default.removeItem(at: summariesDir)
        try FileManager.default.removeItem(
            at: dataDir.appendingPathComponent("state/\(ReportEngine.schoolBackfillMarker)"))
        backfill(staleDays: 30)
        XCTAssertEqual(try summary("2026-10-20").staleCount, 0)
    }

    func testAFutureDatedSnapshotIsSkippedWithOneWarningAndTodayAndPastLand() throws {
        for day in ["20261020", "20261021", "20261022"] {
            try snapshot([mac("A", checkin: "2026-10-01 09:00:00")],
                         file: "\(kind)_\(day)T080000.json")
        }
        let now = try XCTUnwrap(Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 21, hour: 12)))
        let lines = Lines()

        let result = ReportEngine.backfillSchoolSummaries(
            dataDir: dataDir, summariesDir: summariesDir, staleDays: 30, now: now,
            onLine: lines.add)

        XCTAssertEqual(result.written, 2)
        XCTAssertTrue(summaryExists("2026-10-20"))
        XCTAssertTrue(summaryExists("2026-10-21"))
        XCTAssertFalse(summaryExists("2026-10-22"))
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn]") }, [
            "[warn] skipped 1 future-dated school-devices snapshot(s)"
        ])
    }
}
