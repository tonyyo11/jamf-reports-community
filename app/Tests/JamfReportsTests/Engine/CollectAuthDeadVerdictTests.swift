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

    private func outcome(_ kind: String, _ exit: Int32, data: Bool = true) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: exit, hasData: data)
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

    /// exit 0 with EMPTY data is not a real success (404 can return `[]` at exit
    /// 0); paired with a 401 and no genuine success → auth-dead.
    func testExitZeroEmptyDataIsNotSuccess_isAuthDead() {
        let outcomes = [
            outcome("ea-results", 0, data: false),
            outcome("security", 3),
        ]
        XCTAssertTrue(ReportEngine.isCollectAuthDead(outcomes))
    }
}
