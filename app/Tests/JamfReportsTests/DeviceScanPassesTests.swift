import XCTest
@testable import JamfReports

/// The pure rules of the per-device scan passes: order, merge, row dates, the round file as
/// untrusted input, round planning and the in-progress line.
final class DeviceScanPassesTests: XCTestCase {

    /// Local noon on a fixed day, so no rule here depends on when the suite runs.
    private let now = Date.testNoon

    private func iso(daysAgo: Double) -> String {
        ISO8601Time.string(now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func targetJSON(_ id: String, ddm: Bool = false, site: String? = nil) -> String {
        let siteJSON = site.map { #","site":{"id":"\#($0)","name":"S"}"# } ?? ""
        return #"{"id":"\#(id)","general":{"name":"Mac-\#(id)","managementId":"m\#(id)","#
            + #""declarativeDeviceManagementEnabled":\#(ddm)\#(siteJSON)}}"#
    }

    private func target(
        _ id: String, ddm: Bool = false, site: String? = nil
    ) throws -> ReportEngine.DeviceScanTarget {
        try JSONDecoder().decode(ReportEngine.DeviceScanTarget.self,
                                 from: Data(targetJSON(id, ddm: ddm, site: site).utf8))
    }

    private func health(_ id: String, _ scannedAt: String?) -> MDMCommandHealthRecord {
        MDMCommandHealthRecord(deviceId: id, name: "Mac-\(id)", failedCount: 0, pendingCount: 0,
                               failedCommands: [], oldestPendingDays: nil, scannedAt: scannedAt)
    }

    private func ddm(_ id: String, _ scannedAt: String?) -> DDMDeviceStatusRecord {
        DDMDeviceStatusRecord(deviceId: id, name: "Mac-\(id)", managementId: "m\(id)",
                              osVersion: nil, reportDate: nil, ddmReported: true,
                              declarations: [], softwareUpdate: .empty, scannedAt: scannedAt)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanPasses-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Order

    func testPassOrderTakesNeverScannedFirstThenOldest() throws {
        let targets = try ["1", "2", "3", "4", "5"].map { try target($0, ddm: $0 == "5") }
        let order = DeviceScanPasses.passOrder(
            targets,
            health: [health("1", iso(daysAgo: 2)), health("2", iso(daysAgo: 9)),
                     health("4", iso(daysAgo: 5)), health("5", iso(daysAgo: 20))],
            ddm: [])
        // 3 has no row and 5 lacks the DDM row it should have: both never scanned, in
        // `computers` order; then 2 (9 days), 4 (5 days), 1 (2 days).
        XCTAssertEqual(order.map(\.id), ["3", "5", "2", "4", "1"])
    }

    func testPassOrderUsesTheOlderOfAMacsTwoRows() throws {
        let targets = try [target("1", ddm: true), target("2", ddm: true)]
        let order = DeviceScanPasses.passOrder(
            targets,
            health: [health("1", iso(daysAgo: 1)), health("2", iso(daysAgo: 3))],
            ddm: [ddm("1", iso(daysAgo: 6)), ddm("2", iso(daysAgo: 3))])
        XCTAssertEqual(order.map(\.id), ["1", "2"])
    }

    func testPassOrderTakesOneSiteBeforeTheNextThenOldestWithinIt() throws {
        let targets = try [
            target("1", site: "10"), target("2"), target("3", site: "2"),
            target("4", site: "10"), target("5", site: "-1"), target("6", site: "2"),
        ]
        let order = DeviceScanPasses.passOrder(
            targets,
            health: [health("1", iso(daysAgo: 1)), health("2", iso(daysAgo: 20)),
                     health("3", iso(daysAgo: 2)), health("4", iso(daysAgo: 8)),
                     health("5", iso(daysAgo: 30)), health("6", iso(daysAgo: 4))],
            ddm: [])
        // Site 2 before 10 (numbers, not text), then no site ("-1" or absent) last.
        XCTAssertEqual(order.map(\.id), ["6", "3", "4", "1", "5", "2"])
        XCTAssertNil(try target("7", site: "-1").siteId)
        XCTAssertEqual(try target("8", site: "10").siteId, "10")
    }

    // MARK: - Merge

    func testMergeCarriesRecentRowsAndDropsOldOrGoneMacs() {
        let rows = DeviceScanPasses.merged(
            scanned: [health("2", iso(daysAgo: 0))],
            earlier: [health("1", iso(daysAgo: 20)), health("2", iso(daysAgo: 3)),
                      health("3", iso(daysAgo: 22)), health("4", iso(daysAgo: 1)),
                      health("5", nil)],
            carry: ["1", "2", "3", "5"], now: now)
        // 2 was scanned this pass; 3 is past 21 days; 4 left `computers`; 5 has no date.
        XCTAssertEqual(rows.map(\.deviceId), ["1", "2"])
        XCTAssertEqual(rows.first { $0.deviceId == "2" }?.scannedAt, iso(daysAgo: 0))
        XCTAssertEqual(DeviceScanPasses.rowAgeLimit, 21 * 86_400)
    }

    func testARowWithoutScannedAtTakesItsFileStamp() throws {
        let dir = tempDir()
        let kindDir = dir.appendingPathComponent("mdm-command-health", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let old = #"[{"deviceId":"1","name":"A","failedCount":0,"pendingCount":0,"#
            + #""failedCommands":[]},{"deviceId":"2","name":"B","failedCount":0,"#
            + #""pendingCount":0,"failedCommands":[],"scannedAt":"2026-11-01T08:00:00Z"}]"#
        let file = kindDir.appendingPathComponent("mdm-command-health_20261110T090000.json")
        try old.write(to: file, atomically: true, encoding: .utf8)
        let rows = try XCTUnwrap(DeviceScanPasses.earlierRows(
            kind: "mdm-command-health", dataDir: dir, as: MDMCommandHealthRecord.self))
        let stamp = try XCTUnwrap(CloudStorage.snapshotTimestamp(of: file))
        XCTAssertEqual(rows.first { $0.deviceId == "1" }?.scannedAt, ISO8601Time.string(stamp))
        XCTAssertEqual(rows.first { $0.deviceId == "2" }?.scannedAt, "2026-11-01T08:00:00Z")
    }

    func testAnUnreadableEarlierSnapshotIsNotNoSnapshot() throws {
        let dir = tempDir()
        XCTAssertEqual(DeviceScanPasses.earlierRows(
            kind: "mdm-command-health", dataDir: dir, as: MDMCommandHealthRecord.self)?.count, 0)
        let kindDir = dir.appendingPathComponent("mdm-command-health", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try "{not json".write(
            to: kindDir.appendingPathComponent("mdm-command-health_20261110T090000.json"),
            atomically: true, encoding: .utf8)
        XCTAssertNil(DeviceScanPasses.earlierRows(
            kind: "mdm-command-health", dataDir: dir, as: MDMCommandHealthRecord.self))
    }

    // MARK: - The round file

    private func store(round: DeviceScanRound?) throws -> StateFileStore {
        let store = StateFileStore(directory: tempDir())
        if let round { try store.recordDeviceScanRound(round) }
        return store
    }

    private func round(started: Double, lastPass: Double, remaining: Int = 3) -> DeviceScanRound {
        DeviceScanRound(started: now.addingTimeInterval(-started * 86_400),
                        lastPass: now.addingTimeInterval(-lastPass * 86_400),
                        attempted: ["1"], remaining: remaining)
    }

    func testARoundWhoseTallyExceedsItsMacsIsAbsent() throws {
        var planted = round(started: 1, lastPass: 0)
        planted.history = DeviceScanTally(attempted: Int.max, failed: 0)
        XCTAssertNil(DeviceScanPasses.round(in: try store(round: planted), now: now),
                     "a planted count would overflow the next pass's sum")
        planted.history = DeviceScanTally(attempted: 1, failed: 2)
        XCTAssertNil(DeviceScanPasses.round(in: try store(round: planted), now: now))
        planted.history = DeviceScanTally(attempted: 1, failed: 1)
        XCTAssertNotNil(DeviceScanPasses.round(in: try store(round: planted), now: now))
    }

    func testAFutureDatedOrOverAgeRoundIsAbsent() throws {
        XCTAssertNotNil(DeviceScanPasses.round(
            in: try store(round: round(started: 3, lastPass: 1)), now: now))
        let skew = SharedWorkspace.clockSkewTolerance / 86_400
        XCTAssertNotNil(DeviceScanPasses.round(
            in: try store(round: round(started: 1, lastPass: -skew / 2)), now: now),
            "within the clock-skew tolerance")
        XCTAssertNil(DeviceScanPasses.round(
            in: try store(round: round(started: 1, lastPass: -skew * 2)), now: now))
        XCTAssertNil(DeviceScanPasses.round(
            in: try store(round: round(started: -skew * 2, lastPass: 0)), now: now))
        XCTAssertNil(DeviceScanPasses.round(
            in: try store(round: round(started: 22, lastPass: 1)), now: now),
            "a start older than the row-age limit")
        XCTAssertNil(DeviceScanPasses.round(
            in: try store(round: round(started: 3, lastPass: 1, remaining: 0)), now: now))
    }

    func testAnOpenRoundTakesOnePassADayOnAnyUnforcedRun() throws {
        let yesterday = now.addingTimeInterval(-86_400)
        let open = DeviceScanRound(started: yesterday, lastPass: yesterday, attempted: ["1"],
                                   remaining: 3)
        let s = try store(round: open)
        func plan(_ tiers: Set<CollectionTier>, force: Bool = false, skip: Bool = false,
                  store: StateFileStore) -> DeviceScanPlan {
            ReportEngine.planDeviceScan(tiers: tiers, skipExpensive: skip, force: force,
                                        stateStore: store, now: now)
        }
        XCTAssertEqual(plan([.refresh], store: s), .due, "a non-scan tier takes the next pass")
        XCTAssertEqual(plan([.refresh], skip: true, store: s), .turnedOff)
        XCTAssertEqual(plan([.refresh], force: true, store: s), .tierNotSelected)
        XCTAssertEqual(plan([.scan], force: true, store: s), .due)

        var passedToday = open
        passedToday.lastPass = now.addingTimeInterval(-3_600)
        let t = try store(round: passedToday)
        XCTAssertEqual(plan([.refresh], store: t), .notDue(lastAttempt: passedToday.lastPass))
        XCTAssertEqual(plan([.scan], store: t), .notDue(lastAttempt: passedToday.lastPass),
                       "not a second pass the same day, though no .last holds the cadence")

        var finished = open
        finished.remaining = 0
        XCTAssertEqual(plan([.refresh], store: try store(round: finished)), .tierNotSelected)
        XCTAssertEqual(plan([.refresh], store: try store(round: nil)), .tierNotSelected)
    }

    func testScanInProgressOnlyWhileTheLastPassIsRecent() throws {
        XCTAssertTrue(DeviceScanPasses.scanInProgress(
            try store(round: round(started: 5, lastPass: 1.5)), now: now))
        XCTAssertFalse(DeviceScanPasses.scanInProgress(
            try store(round: round(started: 5, lastPass: 2.5)), now: now))
        XCTAssertFalse(DeviceScanPasses.scanInProgress(try store(round: nil), now: now))
    }

    func testBudgetAndManualRefreshStopAPass() {
        XCTAssertFalse(ReportEngine.passShouldStop(
            passStart: now, now: now.addingTimeInterval(59), budget: 60, runStop: nil))
        XCTAssertTrue(ReportEngine.passShouldStop(
            passStart: now, now: now.addingTimeInterval(60), budget: 60, runStop: nil))
        XCTAssertTrue(ReportEngine.passShouldStop(
            passStart: now, now: now, budget: 60, runStop: { .manualRefresh }))
    }

    // MARK: - The in-progress line

    func testRoundProgressCountsCurrentSafeTargetsOnce() throws {
        let dataDir = tempDir()
        let stateDir = dataDir.appendingPathComponent("state", isDirectory: true)
        let computers = dataDir.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: computers, withIntermediateDirectories: true)
        let rows = [targetJSON("1", ddm: true), targetJSON("1", ddm: true), targetJSON("2"),
                    targetJSON("3", ddm: true), targetJSON("4"), targetJSON("-x")]
        try ("[" + rows.joined(separator: ",") + "]").write(
            to: computers.appendingPathComponent("computers_20260614T120000.json"),
            atomically: true, encoding: .utf8)
        XCTAssertNil(DeviceScanPasses.roundProgress(
            dataDir: dataDir, stateDir: stateDir, now: now), "no round, no line")
        try StateFileStore(directory: stateDir).recordDeviceScanRound(DeviceScanRound(
            started: now.addingTimeInterval(-86_400), lastPass: now.addingTimeInterval(-86_400),
            attempted: ["1", "2", "gone", "-x"], remaining: 2))
        let progress = try XCTUnwrap(DeviceScanPasses.roundProgress(
            dataDir: dataDir, stateDir: stateDir, now: now))
        XCTAssertEqual(progress.macs.scanned, 2)
        XCTAssertEqual(progress.macs.total, 4, "the duplicate once, the unsafe id left out")
        XCTAssertEqual(progress.ddm.scanned, 1)
        XCTAssertEqual(progress.ddm.total, 2)
    }

    func testTheInProgressLine() {
        XCTAssertNil(DeviceScanCoverage.line(nil))
        XCTAssertEqual(DeviceScanCoverage.line((4, 12)),
                       "Scan in progress: 4 of 12 Macs scanned this round")
        XCTAssertEqual(DeviceScanCoverage.line((0, 1)),
                       "Scan in progress: 0 of 1 Mac scanned this round")
    }

    func testOldestScannedAtTakesTheFileStampForAnUnstampedRow() {
        let snapshot = MDMCommandHealthService.Snapshot(
            records: [health("1", iso(daysAgo: 1)), health("2", nil)],
            isDetected: true, readFailed: false, snapshotDate: now.addingTimeInterval(-9 * 86_400),
            sourceDates: [:])
        XCTAssertEqual(snapshot.oldestScannedAt, now.addingTimeInterval(-9 * 86_400))
        let unknown = DDMDeviceStatusService.Snapshot(
            records: [ddm("1", nil)], isDetected: true, readFailed: false, snapshotDate: nil,
            sourceDates: [:])
        XCTAssertNil(unknown.oldestScannedAt, "absent is not zero")
    }
}
