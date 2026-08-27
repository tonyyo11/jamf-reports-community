import XCTest
@testable import JamfReports

/// Per-kind data-freshness health: the twin of `AutomationHealthTests`.
///
/// The field defect these pin: on a production tenant, `Managed Freshness`
/// runs recorded OK on consecutive days while `security` sat 35 days stale and
/// `computers` 99 days stale. `ReportEngine.collect` warns and falls back to
/// cache when one kind fails, and that warning never reached the run's exit
/// code — so a green run and a months-broken data source were indistinguishable.
///
/// The rules pinned here are the ones that decide whether an operator is told:
/// - a repeatedly-failing kind reports the CAUSE, not the symptom,
/// - one missed cycle is not an alert (cadence boundaries and slow nights),
/// - a never-collected kind alarms only on a workspace that has collected,
/// - remediation targets only the tiers that are actually broken.
final class DataFreshnessHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        _ kind: String,
        successAgo: TimeInterval? = nil,
        failures: Int = 0
    ) -> KindCollectionState {
        KindCollectionState(
            kind: kind,
            lastSuccess: successAgo.map { now.addingTimeInterval(-$0) },
            consecutiveFailures: failures,
            lastFailure: failures > 0 ? now.addingTimeInterval(-3600) : nil
        )
    }

    // MARK: - Stale threshold

    func testKindOneCadenceBehindIsNotStale() {
        // 13h on a 12h cadence: one boundary miss is normal operation.
        let issues = DataFreshnessHealth.evaluate(
            states: [state("security", successAgo: 13 * 3600)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testKindThreeCadencesBehindIsStale() {
        // 37h on a 12h cadence crosses the 3× budget.
        let issues = DataFreshnessHealth.evaluate(
            states: [state("security", successAgo: 37 * 3600)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(issues.map(\.snapshotKind), ["security"])
        XCTAssertEqual(issues.first?.kind, .stale)
    }

    func testProductionAgesAllReportStale() {
        // The exact prod state from the 2026-08-25 screenshots.
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("overview", successAgo: 600),                    // fresh
                state("patch-status", successAgo: 600),                // fresh
                state("security", successAgo: 35 * 86_400),            // 35d, 12h cadence
                state("computers", successAgo: 99 * 86_400),           // 99d, 2d cadence
                state("patch-device-failures", successAgo: 80 * 86_400) // 80d, 7d cadence
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(
            Set(issues.map(\.snapshotKind)),
            ["security", "computers", "patch-device-failures"]
        )
    }

    // MARK: - Failing beats stale

    func testRepeatedFailuresReportAsFailingNotStale() {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("computers", successAgo: 99 * 86_400, failures: 4)],
            hasCollectedBefore: true, now: now
        )
        // Both conditions hold; the operator needs the cause, not the symptom.
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .failing)
        XCTAssertEqual(issues.first?.consecutiveFailures, 4)
    }

    func testSingleFailureIsNotAnAlert() {
        // One blip is what the in-run retry exists to absorb.
        let issues = DataFreshnessHealth.evaluate(
            states: [state("overview", successAgo: 600, failures: 1)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testFailingSortsAboveStale() {
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("security", successAgo: 40 * 86_400),
                state("computers", failures: 3)
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(issues.map(\.kind), [.failing, .stale])
    }

    // MARK: - Never-collected

    func testNeverCollectedKindAlarmsOnAnEstablishedWorkspace() {
        // prod's `update-device-failures: never` — a real gap, not a new install.
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("overview", successAgo: 600),
                state("update-device-failures")
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(issues.map(\.snapshotKind), ["update-device-failures"])
        XCTAssertNil(issues.first?.lastSuccess)
    }

    func testFreshWorkspaceDoesNotAlarmOnEveryKind() {
        let states = ReportEngine.knownCollectKinds.map { state($0) }
        let issues = DataFreshnessHealth.evaluate(
            states: states, hasCollectedBefore: false, now: now
        )
        XCTAssertTrue(issues.isEmpty, "A workspace that has never collected must not emit 30 alarms")
    }

    // MARK: - Unmapped kinds

    func testUnmappedKindIsIgnored() {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("not-a-real-kind", successAgo: 400 * 86_400)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertTrue(issues.isEmpty, "A kind with no tier has no cadence policy to violate")
    }

    // MARK: - Remediation targeting

    func testRemediationCollectsOnlyAffectedTiers() {
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("security", successAgo: 40 * 86_400),   // refresh tier
                state("computers", successAgo: 99 * 86_400)   // inventory tier
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(DataFreshnessHealth.tiersToRemediate(issues), [.refresh, .inventory])
    }

    func testRemediationOfHealthyFleetIsEmpty() {
        XCTAssertTrue(DataFreshnessHealth.tiersToRemediate([]).isEmpty)
    }

    // MARK: - In-run retry policy

    func testRetryNeverRepeatsAnAuthOrUsageFailure() {
        // Retrying 401/403 cannot succeed (credential state does not change in
        // three seconds) and risks tripping server-side lockout; 2 is a caller
        // bug; 4 means the resource does not exist. Only transient classes retry.
        for deterministic in [CLIBridge.exitCodeUsage,
                              CLIBridge.exitCodeUnauthorized,
                              CLIBridge.exitCodeNotFound,
                              CLIBridge.exitCodePermissionDenied,
                              CLIBridge.exitCodePartialFailure] {
            XCTAssertFalse(
                ReportEngine.retryableExitCodes.contains(deterministic),
                "exit \(deterministic) must not be retried"
            )
        }
    }

    func testRetryCoversTheTransientClasses() {
        XCTAssertTrue(ReportEngine.retryableExitCodes.contains(1),
                      "generic failure is the on-prem request timeout")
        XCTAssertTrue(ReportEngine.retryableExitCodes.contains(CLIBridge.exitCodeRateLimited),
                      "429 is a retry instruction by definition")
    }

    // MARK: - Degraded-run detection

    private func outcome(_ kind: String, _ code: Int32) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: code)
    }

    func testDegradedKindsNamesOnlySourcesThatServedStaleCache() {
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("overview", 0), outcome("security", 1), outcome("computers", 5)],
            savedKinds: ["overview"]
        )
        XCTAssertEqual(degraded, ["computers", "security"])
    }

    func testExitSevenThatSavedIsNotDegraded() {
        // Exit 7 normally carries valid JSON for the successful subset, which
        // `collect` saves. Flagging it would put a Partial pill on a run whose
        // data landed — a pill that cries wolf is worse than no pill at all.
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("patch-status", CLIBridge.exitCodePartialFailure)],
            savedKinds: ["patch-status"]
        )
        XCTAssertTrue(degraded.isEmpty)
    }

    func testExitSevenThatSavedNothingIsDegraded() {
        // The case an exit-code-based rule gets wrong: exit 7 whose output was
        // empty or non-JSON writes no snapshot, so the operator IS being served
        // stale cache and must be told.
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("patch-status", CLIBridge.exitCodePartialFailure)],
            savedKinds: []
        )
        XCTAssertEqual(degraded, ["patch-status"])
    }

    func testExitZeroCarryingUnusableOutputIsDegraded() {
        // Cobra prints parent help and exits 0 for a renamed command; nothing is
        // saved. A rule keyed on the exit code would call that run healthy.
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("classic-macos-profiles", 0)], savedKinds: []
        )
        XCTAssertEqual(degraded, ["classic-macos-profiles"])
    }

    func testAKindThatSavedDespiteAFailingExitIsNotDegraded() {
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("security", 1)], savedKinds: ["security"]
        )
        XCTAssertTrue(degraded.isEmpty, "The snapshot on disk is what the operator cares about")
    }

    func testHealthyRunReportsNothingDegraded() {
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("overview", 0), outcome("security", 0)],
            savedKinds: ["overview", "security"]
        )
        XCTAssertTrue(degraded.isEmpty)
    }

    // MARK: - Remediation rate limit

    func testRemediationRateLimitIsHourlyNotDaily() {
        let f = WorkspaceStore.hourKeyFormatter
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Two attempts in the same hour collapse to one key (the second no-ops);
        // an hour later the key changes, so a source broken at 10:00 is retried
        // when the operator opens the app at 14:00 rather than waiting a day.
        XCTAssertEqual(f.string(from: base), f.string(from: base.addingTimeInterval(59 * 60)))
        XCTAssertNotEqual(f.string(from: base), f.string(from: base.addingTimeInterval(3600)))
        XCTAssertNotEqual(f.string(from: base), f.string(from: base.addingTimeInterval(86_400)))
    }

    // MARK: - Copy

    func testCadenceLabelDerivesFromTheTierNotAHardcodedString() {
        XCTAssertEqual(CollectionTier.refresh.cadenceLabel, "12h")
        XCTAssertEqual(CollectionTier.inventory.cadenceLabel, "2 days")
        XCTAssertEqual(CollectionTier.scan.cadenceLabel, "7 days")
    }

    func testNeverCollectedSummaryDoesNotClaimAnAge() {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("overview", successAgo: 600), state("update-device-failures")],
            hasCollectedBefore: true, now: now
        )
        let summary = try? XCTUnwrap(issues.first).summary
        XCTAssertEqual(summary, "update-device-failures has never been collected successfully")
    }
}
