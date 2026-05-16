import Foundation
import XCTest
@testable import JamfReports

/// Failure-branch coverage for `CLIBridge.generateAll` (BACKLOG: PR-2 Codex review).
///
/// `CLIBridge` is `final` and its `collect`/`generate`/`schoolGenerate`/`generateHTML`
/// methods aren't routed through a protocol seam, so this file covers only what's
/// reachable without introducing a new architectural seam:
///
/// 1. **`GenerateAllResult` struct semantics** — pure unit tests on the result type
///    that callers rely on (`allSucceeded`, `anySucceeded`, accumulation order).
/// 2. **Unauthorized short-circuit** — when `collect` returns
///    `CLIBridge.exitCodeUnauthorized` (3) via the auth guard, `generateAll`
///    must return immediately with a single `.xlsx` failure entry and NOT
///    proceed to invoke the per-type generators.
///
/// The exit-5 (permission denied) and exit-6 (rate-limited) collect-fallback
/// branches, and the partial-success path (one type succeeds, another fails
/// with a non-3 exit code), require synthetic exit codes from `collect` /
/// `generate` / `generateHTML` to exercise. Adding a `CLIExecutor`-style
/// protocol seam over those methods is real architectural scope on a
/// test-infrastructure PR and is logged to BACKLOG as PR-5 in-flight
/// discovery.
@MainActor
final class CLIBridgeGenerationTests: XCTestCase {

    // MARK: - GenerateAllResult struct semantics

    func testEmptyResultIsAllSucceededTrue() {
        let result = GenerateAllResult()
        XCTAssertTrue(result.allSucceeded,
                      "Empty result has no failures, so allSucceeded must be true")
        XCTAssertFalse(result.anySucceeded,
                       "Empty result has no successes, so anySucceeded must be false")
    }

    func testResultWithOnlySuccessesReportsAllSucceeded() {
        var result = GenerateAllResult()
        result.succeeded.append(.xlsx)
        result.succeeded.append(.html)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertTrue(result.anySucceeded)
    }

    func testResultWithAnyFailureReportsNotAllSucceeded() {
        var result = GenerateAllResult()
        result.succeeded.append(.xlsx)
        result.failed.append((.html, 5))
        XCTAssertFalse(result.allSucceeded,
                       "A single failure must flip allSucceeded to false")
        XCTAssertTrue(result.anySucceeded,
                      "An XLSX success keeps anySucceeded true even with HTML failure")
    }

    func testResultWithOnlyFailuresReportsAllSucceededFalse() {
        var result = GenerateAllResult()
        result.failed.append((.xlsx, 3))
        result.failed.append((.html, 1))
        XCTAssertFalse(result.allSucceeded)
        XCTAssertFalse(result.anySucceeded,
                       "All-failures result must not claim any success")
    }

    func testFailedAccumulationPreservesExitCodes() {
        // The UI surfaces exit codes per-type so callers can colour the
        // EXIT n pill. The struct must not collapse / dedupe.
        var result = GenerateAllResult()
        result.failed.append((.xlsx, 3))
        result.failed.append((.html, 5))
        result.failed.append((.pdf, 1))
        XCTAssertEqual(result.failed.count, 3)
        XCTAssertEqual(result.failed[0].exitCode, 3, "xlsx must preserve exit 3 (unauthorized)")
        XCTAssertEqual(result.failed[1].exitCode, 5, "html must preserve exit 5 (permission denied)")
        XCTAssertEqual(result.failed[2].exitCode, 1, "pdf must preserve exit 1 (general error)")
    }

    // MARK: - Unauthorized short-circuit (live test, gated on jamf-cli)

    /// When `collectFresh: true` and `collect` returns
    /// `exitCodeUnauthorized` (3), `generateAll` must abort immediately with a
    /// single `.xlsx` failure and not run any generator. The bogus profile slug
    /// makes the auth guard fail with exit 3 — same probe pattern as
    /// CLIBridgeAuthGuardTests.test_collect_blocksAndEmitsAuthError_forUnknownProfile.
    func testGenerateAllShortCircuitsOnUnauthorizedCollect() async throws {
        guard ExecutableLocator.locate("jamf-cli") != nil else {
            throw XCTSkip("jamf-cli not installed — auth probe not exercisable")
        }

        let bridge = CLIBridge()
        let collector = LogLineCollector()
        let result = await bridge.generateAll(
            types: [.xlsx, .html],
            collectFresh: true,
            outputDir: nil,
            profile: "jrc-test-no-such-profile-xyzzy",
            onLine: { line in collector.append(line) }
        )

        XCTAssertEqual(result.failed.count, 1,
                       "Unauthorized short-circuit must register exactly one failure (the .xlsx entry)")
        XCTAssertEqual(result.failed.first?.type, .xlsx,
                       "Short-circuit records .xlsx as the failed type — that's the documented contract")
        XCTAssertEqual(result.failed.first?.exitCode, CLIBridge.exitCodeUnauthorized,
                       "Failure exit code must be 3 (HTTP 401)")
        XCTAssertTrue(result.succeeded.isEmpty,
                      "No type may be reported as succeeded when collect short-circuits")
        XCTAssertFalse(result.allSucceeded)
        XCTAssertFalse(result.anySucceeded)

        // Diagnostic line must mention the auth failure so the Runs feed surfaces it.
        let lines = collector.snapshot().map(\.text)
        XCTAssertTrue(
            lines.contains(where: { $0.contains("auth check failed") }),
            "expected an [error] auth check failed line; got: \(lines)"
        )
        // And the per-type generators must not have started.
        XCTAssertFalse(
            lines.contains(where: { $0.contains("school-generate") || $0.contains("generating report") }),
            "no generator step may run after the unauthorized short-circuit; got: \(lines)"
        )
    }

    /// When `collectFresh: false`, the unauthorized short-circuit logic is
    /// skipped entirely — `generateAll` invokes the per-type generators
    /// directly. With a bogus profile and no live data, the generators will
    /// fail with their own exit codes (not 3), but they DO run. This locks
    /// in the documented contract that `collectFresh: false` skips the
    /// auth-guard short-circuit.
    func testGenerateAllSkipsCollectWhenCollectFreshFalse() async throws {
        guard ExecutableLocator.locate("jamf-cli") != nil else {
            throw XCTSkip("jamf-cli not installed — auth probe not exercisable")
        }

        let bridge = CLIBridge()
        let collector = LogLineCollector()
        _ = await bridge.generateAll(
            types: [.xlsx],
            collectFresh: false,
            outputDir: nil,
            profile: "jrc-test-no-such-profile-xyzzy",
            onLine: { line in collector.append(line) }
        )

        let lines = collector.snapshot().map(\.text)
        // collect-related log lines must not appear (the collect step was skipped).
        XCTAssertFalse(
            lines.contains(where: { $0.contains("auth check failed") }),
            "collect (and its auth guard) must not run when collectFresh: false; got: \(lines)"
        )
    }
}

/// Thread-safe collector for onLine callbacks. Same pattern as the existing
/// LineCollector / LogLineCollector helpers across the CLIBridge test files.
private final class LogLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [CLIBridge.LogLine] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
