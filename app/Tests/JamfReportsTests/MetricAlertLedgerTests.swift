import XCTest
@testable import JamfReports

/// 2.6 "trust trio" #1 — per-day per-rule dedup for metric-alert cards. The
/// ledger is a plain on-disk struct; these tests exercise the same-day dedup,
/// new-day reset, first-trip-later-today passthrough, and the fail-toward-sending
/// behavior on an unreadable ledger file.
final class MetricAlertLedgerTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private var ledger: MetricAlertLedger { MetricAlertLedger(workspace: workspace) }

    func testFirstRunReturnsAllKeys() {
        let out = ledger.filterAndRecord(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertEqual(Set(out), ["a", "b"])
    }

    func testSameDayFullyDedups() {
        _ = ledger.filterAndRecord(day: "2026-07-08", keys: ["a", "b"])
        let out = ledger.filterAndRecord(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertTrue(out.isEmpty, "a second same-day run with the same hits re-cards nothing")
    }

    func testNewlyTrippedRuleLaterSameDayStillReturned() {
        _ = ledger.filterAndRecord(day: "2026-07-08", keys: ["a"])
        let out = ledger.filterAndRecord(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertEqual(out, ["b"], "only the key that trips for the first time today returns")
    }

    func testNewDayResetsLedger() {
        _ = ledger.filterAndRecord(day: "2026-07-08", keys: ["a", "b"])
        let out = ledger.filterAndRecord(day: "2026-07-09", keys: ["a", "b"])
        XCTAssertEqual(Set(out), ["a", "b"], "a new day resets — yesterday's keys alert again")
    }

    func testEmptyKeysReturnsEmpty() {
        XCTAssertTrue(ledger.filterAndRecord(day: "2026-07-08", keys: []).isEmpty)
    }

    func testRecordPersistsAcrossInstances() {
        _ = MetricAlertLedger(workspace: workspace)
            .filterAndRecord(day: "2026-07-08", keys: ["a"])
        // A fresh instance (the next scheduled run's process) still dedups.
        let out = MetricAlertLedger(workspace: workspace)
            .filterAndRecord(day: "2026-07-08", keys: ["a"])
        XCTAssertTrue(out.isEmpty, "the ledger persists to disk, not just in memory")
    }

    func testUnreadableLedgerFilePassesThrough() throws {
        // A corrupt (non-JSON) ledger must never silence an alert — passthrough.
        let fileURL = workspace
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent(".metric-alerts-ledger.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not valid json".utf8).write(to: fileURL)
        let out = ledger.filterAndRecord(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertEqual(Set(out), ["a", "b"], "corrupt ledger → fail toward sending")
    }
}
