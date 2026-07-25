import Foundation
import XCTest
@testable import JamfReports

/// Spec for `ReportEngine.isCollectAuthDead` — the pure verdict that decides
/// whether a collect's per-command outcomes mean the profile's credentials are
/// dead (surface as non-success, write no summary) vs a partial/flaky failure
/// that falls back to cache.
///
/// Exit-code semantics confirmed against production logs:
/// - exit 3 = HTTP 401 (auth-required core endpoint, credentials expired/revoked)
/// - exit 1 = general / Platform-API 404 (chronic on on-prem, NOT auth)
/// - exit 0 + non-empty data = success
final class CollectAuthDeadVerdictTests: XCTestCase {

    private func outcome(_ kind: String, _ exit: Int32) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: exit)
    }

    /// Every auth-required call 401s and nothing succeeds → auth-dead.
    func testAllUnauthorized_isAuthDead() {
        let outcomes = [
            outcome("security", 3),
            outcome("patch-status", 3),
            outcome("inventory-summary", 3),
            outcome("policy-status", 3),
        ]
        XCTAssertTrue(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// The real prod shape: core endpoints 401 (exit 3), chronic Platform-API
    /// 404s (exit 1), no successes → auth-dead. The exit-1 noise must not mask it.
    func testCoreUnauthorizedPlusChronic404_isAuthDead() {
        let outcomes = [
            outcome("security", 3),
            outcome("patch-status", 3),
            outcome("compliance-devices", 1),
            outcome("ddm-status", 1),
            outcome("blueprint-status", 1),
        ]
        XCTAssertTrue(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// A single 401 among successful calls is a transient/per-endpoint failure,
    /// not dead credentials — fall back to cache, do NOT fail the run.
    func testOneUnauthorizedAmongSuccesses_isNotAuthDead() {
        let outcomes = [
            outcome("overview", 0),
            outcome("computers", 0),
            outcome("security", 3),
            outcome("policy-status", 0),
        ]
        XCTAssertFalse(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// Only chronic non-auth 404s (no 401 anywhere) → never auth-dead, even with
    /// zero successes. This is the steady-state on-prem-without-Platform-API case.
    func testChronic404OnlyNoUnauthorized_isNotAuthDead() {
        let outcomes = [
            outcome("compliance-devices", 1),
            outcome("compliance-rules", 1),
            outcome("ddm-status", 1),
        ]
        XCTAssertFalse(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// All calls succeed → not auth-dead.
    func testAllSuccess_isNotAuthDead() {
        let outcomes = [outcome("overview", 0), outcome("security", 0)]
        XCTAssertFalse(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// An empty outcome set (no auth-bearing command ran, e.g. a tier of only
    /// skipped kinds) is never auth-dead — there is no evidence either way.
    func testEmpty_isNotAuthDead() {
        XCTAssertFalse(ReportEngine.isCollectAuthDead([]))
    }

    /// exit 0 proves auth was accepted even with an empty body, so a 401
    /// alongside it is transient (not auth-dead) — mirrors the Python tally,
    /// which counts any non-raising call as a success.
    func testExitZeroCountsAsSuccessEvenEmpty_isNotAuthDead() {
        let outcomes = [
            outcome("ea-results", 0),
            outcome("security", 3),
        ]
        XCTAssertFalse(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// exit 7 (partial failure, v1.19.0+) also proves auth was accepted, so a
    /// co-occurring 401 is transient — not auth-dead.
    func testExit7CountsAsSuccess_isNotAuthDead() {
        let outcomes = [
            outcome("ea-results", 7),
            outcome("security", 3),
        ]
        XCTAssertFalse(ReportEngine.isCollectAuthDead(outcomes))
    }
}

// MARK: - AuthConfirmationProbe / evaluateAuthDead
//
// Field defect (production, jamf-cli 1.21.1, 2026-07): a scan-tier run made
// exactly ONE live call — patch-device-failures — which 401'd, while the same
// morning's freshness run had already collected six other kinds successfully
// and a direct `jamf-cli doctor` HEAD probe passed. `isCollectAuthDead`
// correctly read the run's own outcomes as auth-dead, but that single
// endpoint's 401 was not proof the credentials themselves were dead.
// `evaluateAuthDead` composes the verdict with a one-shot confirmation probe
// so a still-valid credential is never mistaken for a dead one — and, on a
// weekly schedule, a week-long false Failing banner.
final class AuthDeadConfirmationProbeTests: XCTestCase {

    private func outcome(_ kind: String, _ exit: Int32) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: exit)
    }

    private let testBin = URL(fileURLWithPath: "/usr/local/bin/jamf-cli")

    /// Thread-safe spy recording confirmation-probe invocations without ever
    /// spawning a process — the whole point of threading the probe as an
    /// injectable closure/parameter.
    private final class AuthProbeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        private var _lastProfile: String?
        private var _lastBin: URL?
        let result: Bool

        init(result: Bool) { self.result = result }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _callCount
        }

        var lastProfile: String? {
            lock.lock(); defer { lock.unlock() }
            return _lastProfile
        }

        var lastBin: URL? {
            lock.lock(); defer { lock.unlock() }
            return _lastBin
        }

        // Sync recorder: NSLock.lock/unlock are unavailable directly in async
        // contexts; the async probe delegates here.
        private func record(profile: String, bin: URL) {
            lock.lock()
            _callCount += 1
            _lastProfile = profile
            _lastBin = bin
            lock.unlock()
        }

        func probe(profile: String, bin: URL) async -> Bool {
            record(profile: profile, bin: bin)
            return result
        }
    }

    /// Auth-dead outcomes + a probe that confirms credentials are alive →
    /// `.confirmedAlive`, naming exactly the 401'd kinds, probe invoked once.
    func testProbeConfirmsAlive_returnsConfirmedAliveWithUnauthorizedKinds() async {
        let outcomes = [
            outcome("patch-device-failures", 3),
        ]
        let spy = AuthProbeSpy(result: true)
        let decision = await ReportEngine.evaluateAuthDead(
            outcomes: outcomes, profile: "dummy", bin: testBin,
            probe: { profile, bin in await spy.probe(profile: profile, bin: bin) }
        )
        XCTAssertEqual(decision, .confirmedAlive(warnedKinds: ["patch-device-failures"]))
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(spy.lastProfile, "dummy")
        XCTAssertEqual(spy.lastBin, testBin)
    }

    /// Auth-dead outcomes + a probe that CANNOT confirm (still fails/unreachable)
    /// → `.confirmedDead`, preserving today's abort behavior.
    func testProbeFails_returnsConfirmedDead() async {
        let outcomes = [
            outcome("security", 3),
            outcome("patch-status", 3),
        ]
        let spy = AuthProbeSpy(result: false)
        let decision = await ReportEngine.evaluateAuthDead(
            outcomes: outcomes, profile: "dummy", bin: testBin,
            probe: { profile, bin in await spy.probe(profile: profile, bin: bin) }
        )
        XCTAssertEqual(decision, .confirmedDead(failedCount: 2))
        XCTAssertEqual(spy.callCount, 1)
    }

    /// A healthy run (at least one success) is never auth-dead — the probe must
    /// not fire at all.
    func testProbeNotInvokedWhenOutcomesContainSuccess() async {
        let outcomes = [
            outcome("overview", 0),
            outcome("security", 3),
        ]
        let spy = AuthProbeSpy(result: true)
        let decision = await ReportEngine.evaluateAuthDead(
            outcomes: outcomes, profile: "dummy", bin: testBin,
            probe: { profile, bin in await spy.probe(profile: profile, bin: bin) }
        )
        XCTAssertNil(decision)
        XCTAssertEqual(spy.callCount, 0, "Probe must not run for a healthy outcome set")
    }

    /// Chronic non-auth failures with no 401 at all are never auth-dead — the
    /// probe must not fire (mirrors `isCollectAuthDead`'s own contract).
    func testProbeNotInvokedWhenNoUnauthorizedSignal() async {
        let outcomes = [
            outcome("compliance-devices", 1),
            outcome("ddm-status", 1),
        ]
        let spy = AuthProbeSpy(result: true)
        let decision = await ReportEngine.evaluateAuthDead(
            outcomes: outcomes, profile: "dummy", bin: testBin,
            probe: { profile, bin in await spy.probe(profile: profile, bin: bin) }
        )
        XCTAssertNil(decision)
        XCTAssertEqual(spy.callCount, 0, "Probe must not run when there is no 401 evidence")
    }

    /// An empty outcome set is never auth-dead — the probe must not fire.
    func testProbeNotInvokedForEmptyOutcomes() async {
        let spy = AuthProbeSpy(result: true)
        let decision = await ReportEngine.evaluateAuthDead(
            outcomes: [], profile: "dummy", bin: testBin,
            probe: { profile, bin in await spy.probe(profile: profile, bin: bin) }
        )
        XCTAssertNil(decision)
        XCTAssertEqual(spy.callCount, 0)
    }
}

// MARK: - isCollectDead verdict

/// Spec for `ReportEngine.isCollectDead` — the total-outage guard that catches
/// all-fail runs with no 401 signals (server unreachable, jamf-cli broken, etc.)
/// and prevents them from falling through to SOFA + `emitSummaryJSON` with stale data.
final class CollectDeadVerdictTests: XCTestCase {

    private func outcome(_ kind: String, _ exit: Int32) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: exit)
    }

    /// Every live call fails non-zero with no 401 at all → total outage, collect-dead.
    func testAllFailNoAuth_isCollectDead() {
        let outcomes = [
            outcome("overview", 1),
            outcome("security", 1),
            outcome("patch-status", 4),
            outcome("policy-status", 5),
        ]
        XCTAssertTrue(ReportEngine.isCollectDead(outcomes))
    }

    /// All non-zero exits, some are exit 6 (rate-limited) → still collect-dead.
    func testAllFailRateLimited_isCollectDead() {
        let outcomes = [
            outcome("overview", 6),
            outcome("security", 6),
        ]
        XCTAssertTrue(ReportEngine.isCollectDead(outcomes))
    }

    /// All calls fail with 401 included — auth-dead wins at the call site; isCollectDead
    /// would also be true for its own criterion (no exit-0). Both verdicts fire but
    /// auth-dead is checked FIRST at the call site, so this test documents the
    /// relationship: when auth-dead is true, collect-dead is also true.
    func testAllFailWithOne401_collectDeadIsAlsoTrue() {
        let outcomes = [
            outcome("security", 3),
            outcome("patch-status", 3),
            outcome("inventory-summary", 1),
        ]
        // Auth-dead wins at call site — but isCollectDead is also true.
        XCTAssertTrue(ReportEngine.isCollectAuthDead(outcomes))
        XCTAssertTrue(ReportEngine.isCollectDead(outcomes))
    }

    /// One success + failures → partial failure, cache is warmed; neither verdict fires.
    func testOneSuccessPlusFailures_isNotCollectDead() {
        let outcomes = [
            outcome("overview", 0),
            outcome("security", 1),
            outcome("patch-status", 4),
        ]
        XCTAssertFalse(ReportEngine.isCollectDead(outcomes))
    }

    /// exit 7 (partial failure, v1.19.0+) counts as a success for the outage
    /// verdict — partial data was returned and saved, so the run is not dead.
    func testExit7IsNotCollectDead() {
        XCTAssertFalse(ReportEngine.isCollectDead([outcome("security", 7)]))
    }

    /// All calls succeed → not collect-dead.
    func testAllSuccess_isNotCollectDead() {
        let outcomes = [
            outcome("overview", 0),
            outcome("security", 0),
            outcome("computers", 0),
        ]
        XCTAssertFalse(ReportEngine.isCollectDead(outcomes))
    }

    /// An empty outcome set (no live calls attempted, e.g. tier skipped everything)
    /// is never collect-dead — there is no evidence of a failure.
    func testEmpty_isNotCollectDead() {
        XCTAssertFalse(ReportEngine.isCollectDead([]))
    }

    /// A single exit-0 among otherwise-all-failures → cache is warmed; not collect-dead.
    func testSingleSuccessAmongManyFailures_isNotCollectDead() {
        let outcomes = [
            outcome("overview", 0),
            outcome("security", 1),
            outcome("patch-status", 1),
            outcome("policy-status", 1),
            outcome("inventory-summary", 1),
        ]
        XCTAssertFalse(ReportEngine.isCollectDead(outcomes))
    }

    // MARK: - skippedNotDueCount veto (field defect, jamf-cli 1.21.1, 2026-07)
    //
    // A freshness collect that skipped every healthy kind as "not due" (fresh cache
    // from a prior run) and then only attempted the chronically-failing residue —
    // Platform-API 404s (exit 1) plus duplicate-serials on a pre-1.23 binary (exit 2)
    // — must not read as a total outage; a cadence skip is recent proof the server
    // and jamf-cli both work.

    /// Failures only, but at least one kind was skipped as not-due this run →
    /// NOT dead. The fresh-cache skip is proof the server is reachable.
    func testFailuresOnlyWithSkipsPresent_isNotCollectDead() {
        let outcomes = [
            outcome("compliance-devices", 1),
            outcome("ddm-status", 1),
            outcome("duplicate-serials", 2),
        ]
        XCTAssertFalse(ReportEngine.isCollectDead(outcomes, skippedNotDueCount: 4))
    }

    /// All failures are exit 2 (usage — bad flags / unrecognized subcommand), no
    /// skips → NOT dead. Exit 2 says nothing about server reachability; this is a
    /// broken invocation (e.g. duplicate-serials on a pre-1.23 binary), not an outage.
    func testAllExitTwoNoSkips_isNotCollectDead() {
        let outcomes = [
            outcome("duplicate-serials", 2),
            outcome("some-new-command", 2),
        ]
        XCTAssertFalse(ReportEngine.isCollectDead(outcomes, skippedNotDueCount: 0))
    }

    /// Zero successes, zero skips, and at least one non-exit-2 failure → still dead.
    /// The true outage case must keep firing once the exit-2 and skip noise is
    /// excluded from the evidence.
    func testNoSkipsWithNonUsageFailure_isCollectDead() {
        let outcomes = [
            outcome("duplicate-serials", 2),
            outcome("compliance-devices", 1),
        ]
        XCTAssertTrue(ReportEngine.isCollectDead(outcomes, skippedNotDueCount: 0))
    }

    /// exit 7 (partial failure) still counts as success evidence even when the
    /// skippedNotDueCount veto isn't in play — a saved partial result is not an outage.
    func testExit7CountsAsSuccessRegardlessOfSkips_isNotCollectDead() {
        let outcomes = [outcome("ea-results", 7), outcome("compliance-devices", 1)]
        XCTAssertFalse(ReportEngine.isCollectDead(outcomes, skippedNotDueCount: 0))
    }
}
