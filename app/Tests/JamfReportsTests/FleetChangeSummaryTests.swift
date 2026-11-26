import XCTest
@testable import JamfReports

/// The change parts of the daily summary (wave B2): schema, checks, merging and builders.
final class FleetChangeSummaryTests: XCTestCase {

    private func summary(_ extra: String = "") throws -> DailySummary {
        let json = #"{"date":"2026-11-02","totalDevices":3,"source":"jamf-cli""#
            + extra + "}"
        return try SummaryJSONParser.decode(Data(json.utf8))
    }

    private let counts = ComputerChanges(
        currentStamp: "20261102T060000", baselineStamp: "20261101T060000",
        currentCount: 3, priorCount: 2, staleDays: 30, staleBasis: ["check_in"],
        fileVaultRule: "abcd1234", joined: 1, left: 0, osChanged: 0, becameStale: 0,
        noLongerStale: 0, fileVaultOff: 1, fileVaultStoppedReporting: 0,
        unidentified: 0, ambiguous: 0)

    func testCodableRoundTrip() throws {
        var day = try summary()
        day.changes = FleetChangeSummary(
            computers: counts,
            benchmarks: BenchmarkChanges(newlyFailing: 2, notCompared: 1))
        let data = try JSONEncoder().encode(day)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"filevault_off\":1"))
        XCTAssertTrue(text.contains("\"newly_failing\":2"))
        XCTAssertEqual(try SummaryJSONParser.decode(data).changes, day.changes)
    }

    func testPatchPartWithoutComputersStampStillDecodes() throws {
        let day = try summary(#","changes":{"patch":{"started_failing":2}}"#)
        XCTAssertEqual(day.changes?.patch?.startedFailing, 2)
        XCTAssertNil(day.changes?.patch?.computersStamp)
        let stamped = try summary(#","changes":{"patch":{"computers_stamp":"20261102T060000"}}"#)
        XCTAssertEqual(stamped.changes?.patch?.computersStamp, "20261102T060000")
    }

    func testMalformedPartIsDroppedAlone() throws {
        let day = try summary(#","changes":{"computers":{"joined":"many"},"#
            + #""benchmarks":{"newly_failing":3}}"#)
        XCTAssertNil(day.changes?.computers)
        XCTAssertEqual(day.changes?.benchmarks?.newlyFailing, 3)
        XCTAssertEqual(day.totalDevices, 3, "the day survives")
        XCTAssertNil(try summary(#","changes":"nonsense""#).changes)
    }

    func testPatchPartRoundTripAndChecks() throws {
        var day = try summary()
        day.changes = FleetChangeSummary(patch: PatchChanges(
            currentStamp: "a", baselineStamp: "b", startedFailing: 1, stoppedFailing: 2,
            leftOut: 0, notInComputers: 1))
        let data = try JSONEncoder().encode(day)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"stopped_failing\":2"))
        XCTAssertEqual(try SummaryJSONParser.decode(data).changes, day.changes)
        let malformed = try summary(#","changes":{"patch":{"started_failing":"x"},"#
            + #""benchmarks":{"newly_failing":1}}"#)
        XCTAssertNil(malformed.changes?.patch)
        XCTAssertNotNil(malformed.changes?.benchmarks)
        XCTAssertNil(FleetChangeSummary(patch: PatchChanges(startedFailing: -1)).validated())
        var older = try summary()
        older.changes = day.changes
        XCTAssertEqual(try summary().filling(from: older).changes?.patch, day.changes?.patch)
        var fresh = try summary()
        fresh.changes = FleetChangeSummary(patch: PatchChanges(startedFailing: 0))
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: try summary(), fresh: fresh))
    }

    // MARK: - patchComputerIndex

    func testPatchComputerIndex() throws {
        let landedIndex = try XCTUnwrap(ReportEngine.patchComputerIndex(
            landed: landed(), dataDir: try dataDir(baseline: nil), scanDate: at(0)))
        XCTAssertTrue(landedIndex.index.contains(jamfID: "1", serial: nil))
        XCTAssertEqual(landedIndex.stamp, "x", "a landed snapshot gives its own stamp")

        let rows: [[String: Any]] = [["id": "7"]]
        let dir = try dataDir(baseline: JSONSerialization.data(withJSONObject: rows))
        let fromFile = try XCTUnwrap(ReportEngine.patchComputerIndex(
            landed: nil, dataDir: dir, scanDate: at(0)))
        XCTAssertTrue(fromFile.index.contains(jamfID: "7", serial: nil))
        XCTAssertEqual(fromFile.stamp, GoldenFleetClock.stamp(at(-1)), "the fallback file's stamp")
        XCTAssertNil(ReportEngine.patchComputerIndex(landed: nil, dataDir: dir, scanDate: at(-2)),
                     "a file stamped after the scan is not used")
        XCTAssertNil(ReportEngine.patchComputerIndex(
            landed: nil, dataDir: try dataDir(baseline: Data("{bad".utf8)), scanDate: at(0)))
        XCTAssertNil(ReportEngine.patchComputerIndex(
            landed: nil, dataDir: try dataDir(baseline: nil), scanDate: at(0)))
    }

    func testValidatedRule() {
        var unreadable = ComputerChanges(baselineUnreadable: true)
        XCTAssertTrue(unreadable.isValid)
        unreadable.joined = 1
        XCTAssertFalse(unreadable.isValid, "an unreadable baseline carries no counts")

        XCTAssertFalse(ComputerChanges(currentCount: 3, joined: 1).isValid,
                       "joined needs both totals")
        XCTAssertFalse(ComputerChanges(currentCount: 3, priorCount: 2, joined: 4).isValid)
        XCTAssertTrue(ComputerChanges(currentCount: 3, priorCount: 2, joined: 3).isValid)
        XCTAssertTrue(ComputerChanges(becameStale: 2).isValid, "no joined or left, no bound")
        XCTAssertFalse(ComputerChanges(becameStale: -1).isValid)
        XCTAssertFalse(ComputerChanges(
            osChanged: SummaryJSONParser.maxSummaryNumber + 1).isValid)
        XCTAssertFalse(BenchmarkChanges(newlyFailing: -2).isValid)
        XCTAssertNil(FleetChangeSummary(computers: ComputerChanges(left: -1)).validated())
    }

    func testFillingKeepsEachPartWhole() throws {
        var older = try summary()
        older.changes = FleetChangeSummary(
            computers: counts, benchmarks: BenchmarkChanges(newlyFailing: 5))
        var newer = try summary()
        newer.changes = FleetChangeSummary(benchmarks: BenchmarkChanges(newlyFailing: 1))
        let filled = newer.filling(from: older)
        XCTAssertEqual(filled.changes?.computers, counts)
        XCTAssertEqual(filled.changes?.benchmarks?.newlyFailing, 1)
        let plain = try summary()
        XCTAssertEqual(plain.filling(from: older).changes, older.changes,
                       "a rebuild without a part keeps the morning's")
    }

    func testFreshSummaryWithAPartIsBetter() throws {
        let existing = try summary()
        var fresh = try summary()
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh))
        fresh.changes = FleetChangeSummary(computers: counts)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh))
    }

    /// A run that read no Macs never replaces a day that counted them, even with a part.
    func testAPartDoesNotReplaceADayThatCountedMacs() throws {
        let existing = try summary()
        var fresh = try SummaryJSONParser.decode(Data(
            #"{"date":"2026-11-02","totalDevices":0,"source":"jamf-cli"}"#.utf8))
        fresh.changes = FleetChangeSummary(benchmarks: BenchmarkChanges(newlyFailing: 1))
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh))
    }

    func testFileVaultFingerprint() {
        let base = SecurityControlPolicy()
        XCTAssertEqual(base.fileVaultFingerprint, SecurityControlPolicy().fileVaultFingerprint)
        XCTAssertEqual(base.fileVaultFingerprint.count, 8)
        XCTAssertNotEqual(base.fileVaultFingerprint,
                          SecurityControlPolicy(onValues: [.fileVault: ["Pass"]])
                            .fileVaultFingerprint)
        XCTAssertNotEqual(base.fileVaultFingerprint,
                          SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
                            .fileVaultFingerprint)
        XCTAssertEqual(base.fileVaultFingerprint,
                       SecurityControlPolicy(sip: .ignore).fileVaultFingerprint)
    }

    // MARK: - computerChanges

    private let anchor = GoldenFleetClock.anchorNoon()
    private func at(_ day: Int) -> Date {
        GoldenFleetClock.timestamp(dayOffset: day, hour: 12, minute: 0, relativeTo: anchor)
    }

    private func landed() -> LandedSources.LandedComputers {
        LandedSources.LandedComputers(
            stamp: "x", date: at(0),
            snapshot: ComputerSnapshot(rows: [
                ComputerDates(jamfID: "1", fileVault: "UNENCRYPTED"),
                ComputerDates(jamfID: "2", fileVault: "ENCRYPTED")]))
    }

    private func dataDir(baseline: Data?) throws -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("data", isDirectory: true)
        if let baseline {
            let url = dir.appendingPathComponent("computers", isDirectory: true)
                .appendingPathComponent("computers_\(GoldenFleetClock.stamp(at(-1))).json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try baseline.write(to: url)
        }
        return dir
    }

    func testComputerChangesWithNoBaselineIsNil() throws {
        XCTAssertNil(ReportEngine.computerChanges(
            landed: landed(), dataDir: try dataDir(baseline: nil),
            rule: StaleRule(days: 30), policy: SecurityControlPolicy()))
    }

    func testComputerChangesCounts() throws {
        let rows: [[String: Any]] = [
            ["id": "1", "diskEncryption": ["fileVault2Enabled": true]],
            ["id": "3", "diskEncryption": ["fileVault2Enabled": true]],
        ]
        let changes = try XCTUnwrap(ReportEngine.computerChanges(
            landed: landed(),
            dataDir: try dataDir(baseline: JSONSerialization.data(withJSONObject: rows)),
            rule: StaleRule(days: 30), policy: SecurityControlPolicy()))
        XCTAssertEqual(changes.joined, 1)
        XCTAssertEqual(changes.left, 1)
        XCTAssertEqual(changes.fileVaultOff, 1)
        XCTAssertEqual(changes.currentCount, 2)
        XCTAssertEqual(changes.priorCount, 2)
        XCTAssertNil(changes.becameStale, "no dates: stale not compared")
        XCTAssertEqual(changes.staleBasis, ["check_in"])
        XCTAssertEqual(changes.fileVaultRule, SecurityControlPolicy().fileVaultFingerprint)
        XCTAssertEqual(changes.baselineStamp, GoldenFleetClock.stamp(at(-1)))
        XCTAssertTrue(changes.isValid)
    }

    func testOverLimitBaselineIsUnreadable() throws {
        let rows: [[String: Any]] = [["id": "1"]]
        let changes = try XCTUnwrap(ReportEngine.computerChanges(
            landed: landed(),
            dataDir: try dataDir(baseline: JSONSerialization.data(withJSONObject: rows)),
            rule: StaleRule(days: 30), policy: SecurityControlPolicy(), readLimit: 4))
        XCTAssertEqual(changes.baselineUnreadable, true)
        XCTAssertEqual(changes.baselineUnreadableReason, .tooLarge)
        XCTAssertNil(changes.joined)
        XCTAssertTrue(changes.isValid)
    }

    func testUndecodableBaselineIsUnreadable() throws {
        let changes = try XCTUnwrap(ReportEngine.computerChanges(
            landed: landed(), dataDir: try dataDir(baseline: Data("{not json".utf8)),
            rule: StaleRule(days: 30), policy: SecurityControlPolicy()))
        XCTAssertEqual(changes.baselineUnreadableReason, .undecodable)
    }
}
