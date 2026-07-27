import XCTest
@testable import JamfReports

/// 2.6 "trust trio" #1 — per-day per-rule dedup for metric-alert cards. The
/// ledger is a plain on-disk struct; these tests exercise the same-day dedup,
/// new-day reset, first-trip-later-today passthrough, and the fail-toward-sending
/// behavior on an unreadable ledger file.
///
/// The read (`pendingKeys`) and the write (`record`) are deliberately separate:
/// the caller sends between them, so a failed send leaves the ledger untouched
/// and the rule retries. `sendSucceeded` below models that ordering.
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

    /// Peek, then claim — the caller's ordering when the webhook post succeeds.
    @discardableResult
    private func sendSucceeded(day: String, keys: [String]) -> [String] {
        let pending = ledger.pendingKeys(day: day, keys: keys)
        ledger.record(day: day, keys: pending)
        return pending
    }

    func testFirstRunReturnsAllKeys() {
        XCTAssertEqual(Set(sendSucceeded(day: "2026-07-08", keys: ["a", "b"])), ["a", "b"])
    }

    func testSameDayFullyDedups() {
        sendSucceeded(day: "2026-07-08", keys: ["a", "b"])
        let out = sendSucceeded(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertTrue(out.isEmpty, "a second same-day run with the same hits re-cards nothing")
    }

    func testNewlyTrippedRuleLaterSameDayStillReturned() {
        sendSucceeded(day: "2026-07-08", keys: ["a"])
        let out = sendSucceeded(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertEqual(out, ["b"], "only the key that trips for the first time today returns")
    }

    func testNewDayResetsLedger() {
        sendSucceeded(day: "2026-07-08", keys: ["a", "b"])
        let out = sendSucceeded(day: "2026-07-09", keys: ["a", "b"])
        XCTAssertEqual(Set(out), ["a", "b"], "a new day resets — yesterday's keys alert again")
    }

    func testEmptyKeysReturnsEmpty() {
        XCTAssertTrue(ledger.pendingKeys(day: "2026-07-08", keys: []).isEmpty)
    }

    func testRecordPersistsAcrossInstances() {
        let first = MetricAlertLedger(workspace: workspace)
        first.record(day: "2026-07-08", keys: first.pendingKeys(day: "2026-07-08", keys: ["a"]))
        // A fresh instance (the next scheduled run's process) still dedups.
        let out = MetricAlertLedger(workspace: workspace)
            .pendingKeys(day: "2026-07-08", keys: ["a"])
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
        let out = ledger.pendingKeys(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertEqual(Set(out), ["a", "b"], "corrupt ledger → fail toward sending")
    }

    // MARK: - Send ordering (the 2.6.1 fix)

    func testPeekAloneDoesNotClaimTheDay() {
        // A failed send calls pendingKeys but never record: the rule must still
        // be pending on the next run rather than being silenced for the day.
        _ = ledger.pendingKeys(day: "2026-07-08", keys: ["a", "b"])
        let retry = ledger.pendingKeys(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertEqual(Set(retry), ["a", "b"], "a failed send must leave the ledger untouched")
    }

    func testRetryAfterFailedSendThenSucceedsAndDedupsAfterwards() {
        _ = ledger.pendingKeys(day: "2026-07-08", keys: ["a"])   // send failed, nothing claimed
        let second = sendSucceeded(day: "2026-07-08", keys: ["a"])
        XCTAssertEqual(second, ["a"], "the retry re-alerts")
        XCTAssertTrue(
            ledger.pendingKeys(day: "2026-07-08", keys: ["a"]).isEmpty,
            "once sent, the same day dedups"
        )
    }

    func testRecordWithEmptyKeysLeavesLedgerUntouched() {
        sendSucceeded(day: "2026-07-08", keys: ["a"])
        ledger.record(day: "2026-07-08", keys: [])
        XCTAssertTrue(
            ledger.pendingKeys(day: "2026-07-08", keys: ["a"]).isEmpty,
            "an empty record must not clobber the day's existing keys"
        )
    }
}
