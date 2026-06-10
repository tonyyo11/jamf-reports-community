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
}
