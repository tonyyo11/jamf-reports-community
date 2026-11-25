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

    // MARK: - Credential keys

    private func credentialHit(
        key: String = "ca", expires: String = "2026-08-01T00:00:00Z", state: String = "hit"
    ) -> MetricAlertHit {
        MetricAlertHit(
            metricLabel: "Server credential days left", ruleDescription: "below 45", current: 40,
            prior: nil, message: "m", credentialKey: key, expires: expires,
            credentialState: state)
    }

    private let now = Date.testNoon

    func testACredentialIsSentOnceAcrossDaysAndARenewalOrNewStateReArms() {
        let hit = credentialHit()
        XCTAssertEqual(ledger.pendingCredentialHits([hit]).count, 1)
        ledger.recordCredentials([hit], now: now)
        XCTAssertTrue(ledger.pendingCredentialHits([hit]).isEmpty)
        sendSucceeded(day: "2026-07-09", keys: ["a"])
        XCTAssertTrue(ledger.pendingCredentialHits([hit]).isEmpty, "a new day does not reset it")
        XCTAssertEqual(
            ledger.pendingCredentialHits([credentialHit(expires: "2027-08-01T00:00:00Z")]).count, 1)
        XCTAssertEqual(ledger.pendingCredentialHits([credentialHit(state: "expired")]).count, 1)
        XCTAssertEqual(ledger.pendingCredentialHits([credentialHit(key: "ade:1")]).count, 1)
    }

    func testRecordingMergesAndKeepsTheDayRecordBothWays() {
        sendSucceeded(day: "2026-07-08", keys: ["a"])
        ledger.recordCredentials([credentialHit()], now: now)
        ledger.recordCredentials([credentialHit(key: "ade:1")], now: now)
        sendSucceeded(day: "2026-07-08", keys: ["a", "b"])
        XCTAssertTrue(ledger.pendingCredentialHits(
            [credentialHit(), credentialHit(key: "ade:1")]).isEmpty)
        XCTAssertTrue(ledger.pendingKeys(day: "2026-07-08", keys: ["a", "b"]).isEmpty)
    }

    func testAnEntryIsPrunedSixtyDaysAfterItsExpiryOnly() {
        let day = 86_400.0
        func stamp(_ days: Double) -> String { ISO8601Time.string(now.addingTimeInterval(days * day)) }
        let recent = credentialHit(key: "ca", expires: stamp(-59), state: "expired")
        let old = credentialHit(key: "ade:1", expires: stamp(-61), state: "expired")
        ledger.recordCredentials([recent, old], now: now)
        XCTAssertTrue(ledger.pendingCredentialHits([recent]).isEmpty)
        XCTAssertEqual(ledger.pendingCredentialHits([old]).count, 1, "pruned, so it re-arms")
    }

    func testALedgerAn212BuildWroteHasNoCredentialKeysAndSendsOnce() throws {
        let url = AutomationStateFile.url(named: ".metric-alerts-ledger.json", in: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"day":"2026-07-08","keys":["a"]}"#.utf8).write(to: url)
        XCTAssertEqual(ledger.pendingCredentialHits([credentialHit()]).count, 1)
        ledger.recordCredentials([credentialHit()], now: now)
        XCTAssertTrue(ledger.pendingCredentialHits([credentialHit()]).isEmpty)
        XCTAssertTrue(ledger.pendingKeys(day: "2026-07-08", keys: ["a"]).isEmpty)
    }

    func testAnUnreadableLedgerFailsTowardSendingCredentialAlerts() throws {
        let url = AutomationStateFile.url(named: ".metric-alerts-ledger.json", in: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ledger.pendingCredentialHits([credentialHit()]).count, 1)
    }
}
