import Foundation
import XCTest
@testable import JamfReports

/// Failure-branch coverage for `CLIBridge.generateAll`.
///
/// `CLIBridge` is `final` and its generator methods are intentionally not
/// behind the `CLICommand`/`CLIExecutor` protocol (ADR-W21 Hybrid scope).
/// `generateAll`'s orchestration was therefore extracted into
/// `CLIBridge.runGenerateAll`, which injects `collect` / the XLSX+HTML
/// generators / the permission sweep as closures (Epic #102, item #3). This
/// file covers three layers:
///
/// 1. **`GenerateAllResult` struct semantics** — pure unit tests on the result
///    type callers rely on (`allSucceeded`, `anySucceeded`, accumulation order).
/// 2. **`runGenerateAll` branch coverage** — stub closures return synthetic
///    exit codes to exercise the collect-fallback (exit 3/5/6), partial-success,
///    and permission-sweep branches without a live jamf-cli.
/// 3. **Unauthorized short-circuit (live)** — an integration check that the
///    real `generateAll` short-circuits when the auth guard fails with exit 3.
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

        XCTAssertEqual(result.failed.count, 2,
                       "Unauthorized short-circuit must register a failure for every requested type")
        XCTAssertTrue(result.failed.map(\.type).contains(.xlsx))
        XCTAssertTrue(result.failed.map(\.type).contains(.html))
        XCTAssertTrue(result.failed.allSatisfy { $0.exitCode == CLIBridge.exitCodeUnauthorized },
                      "All failure entries must carry exit code 3 (HTTP 401)")
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

    // MARK: - runGenerateAll branch coverage (stubbed exit codes)

    /// Counts how many times each injected operation ran. MainActor-confined —
    /// every closure runs inside `runGenerateAll`, which is `@MainActor`.
    private final class StubCalls {
        var collect = 0
        var xlsx = 0
        var html = 0
        var pdf = 0
        var csv = 0
        var tighten = 0
    }

    /// Drive `runGenerateAll` with stub closures returning the given synthetic
    /// exit codes, and report the result plus per-operation call counts.
    private func runStubbed(
        types: Set<GenerateOutputType> = [.xlsx, .html],
        collectFresh: Bool,
        collectExit: Int32 = 0,
        xlsxExit: Int32 = 0,
        htmlExit: Int32 = 0,
        cacheAge: String = "2 hours old"
    ) async -> (result: GenerateAllResult, calls: StubCalls, lines: [String]) {
        let calls = StubCalls()
        let collector = LogLineCollector()
        let result = await CLIBridge.runGenerateAll(
            types: types,
            collectFresh: collectFresh,
            profile: "test-profile",
            onLine: { collector.append($0) },
            collect: { calls.collect += 1; return collectExit },
            generateXLSX: { calls.xlsx += 1; return xlsxExit },
            generateHTML: { calls.html += 1; return htmlExit },
            generatePDF: { calls.pdf += 1; return 0 },
            generateCSV: { calls.csv += 1; return 0 },
            tighten: { calls.tighten += 1 },
            cacheAge: { cacheAge }
        )
        return (result, calls, collector.snapshot().map(\.text))
    }

    func testRunGenerateAllAbortsOnUnauthorizedCollect() async {
        // runStubbed requests [.xlsx, .html]; both must appear in failed after exit 3.
        let (result, calls, _) = await runStubbed(
            collectFresh: true, collectExit: CLIBridge.exitCodeUnauthorized
        )
        XCTAssertEqual(result.failed.count, 2,
                       "exit 3 must record a failure entry for every requested type")
        XCTAssertTrue(result.failed.map(\.type).contains(.xlsx))
        XCTAssertTrue(result.failed.map(\.type).contains(.html))
        XCTAssertEqual(result.failed.first?.exitCode, CLIBridge.exitCodeUnauthorized)
        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(calls.collect, 1)
        XCTAssertEqual(calls.xlsx, 0, "no generator may run after the exit-3 short-circuit")
        XCTAssertEqual(calls.html, 0)
        XCTAssertEqual(calls.tighten, 0, "nothing was written — the permission sweep must not run")
    }

    func testRunGenerateAllWarnsAndProceedsOnPermissionDenied() async {
        let (result, calls, lines) = await runStubbed(
            collectFresh: true, collectExit: CLIBridge.exitCodePermissionDenied
        )
        XCTAssertEqual(calls.xlsx, 1, "exit 5 must warn and proceed to the generators")
        XCTAssertEqual(calls.html, 1)
        XCTAssertTrue(lines.contains { $0.contains("permission denied (exit 5)") },
                      "exit 5 must emit a specific warn line; got \(lines)")
        XCTAssertTrue(result.allSucceeded)
    }

    func testRunGenerateAllWarnsAndProceedsOnRateLimited() async {
        let (_, calls, lines) = await runStubbed(
            collectFresh: true, collectExit: CLIBridge.exitCodeRateLimited
        )
        XCTAssertEqual(calls.xlsx, 1, "exit 6 is transient — it must warn and proceed")
        XCTAssertTrue(lines.contains { $0.contains("rate-limited (exit 6)") },
                      "exit 6 must emit a specific warn line; got \(lines)")
    }

    func testRunGenerateAllWarnsOnGenericCollectFailure() async {
        let (_, calls, lines) = await runStubbed(collectFresh: true, collectExit: 1)
        XCTAssertEqual(calls.xlsx, 1, "a generic non-zero collect must still proceed with cached data")
        XCTAssertTrue(lines.contains { $0.contains("collect exited 1") }, "got \(lines)")
    }

    func testRunGenerateAllFailsOnCollectFailureWithNoCache() async {
        // When collect fails AND no cached data exists, the run must fail
        // loudly instead of producing an empty report.
        let (result, calls, lines) = await runStubbed(
            collectFresh: true, collectExit: CLIBridge.exitCodePermissionDenied, cacheAge: ""
        )
        XCTAssertEqual(calls.xlsx, 0, "no generator may run when there is no data at all")
        XCTAssertEqual(calls.html, 0)
        XCTAssertEqual(result.failed.first?.exitCode, CLIBridge.exitCodePermissionDenied)
        XCTAssertTrue(lines.contains { $0.contains("no cached data available") },
                      "the no-cache fatal must be explicit; got \(lines)")
        XCTAssertEqual(calls.tighten, 0, "nothing was written — the permission sweep must not run")
    }

    func testRunGenerateAllPartialSuccessTightens() async {
        let (result, calls, _) = await runStubbed(collectFresh: false, xlsxExit: 0, htmlExit: 1)
        XCTAssertEqual(result.succeeded, [.xlsx])
        XCTAssertEqual(result.failed.map(\.type), [.html])
        XCTAssertEqual(result.failed.first?.exitCode, 1)
        XCTAssertFalse(result.allSucceeded)
        XCTAssertTrue(result.anySucceeded)
        XCTAssertEqual(calls.tighten, 1, "a partial success must still run the permission sweep")
        XCTAssertEqual(calls.collect, 0, "collectFresh: false must skip collect entirely")
    }

    func testRunGenerateAllAllFailuresSkipTighten() async {
        let (result, calls, _) = await runStubbed(collectFresh: false, xlsxExit: 1, htmlExit: 1)
        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(calls.tighten, 0, "the permission sweep must not run when nothing was written")
    }

    func testRunGenerateAllAllSuccessTightens() async {
        let (result, calls, _) = await runStubbed(collectFresh: false, xlsxExit: 0, htmlExit: 0)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertEqual(calls.tighten, 1)
    }

    func testRunGenerateAllOnlyRunsRequestedTypes() async {
        let (_, calls, _) = await runStubbed(types: [.xlsx], collectFresh: false)
        XCTAssertEqual(calls.xlsx, 1)
        XCTAssertEqual(calls.html, 0, "the HTML generator must not run when .html is not requested")
    }

    // MARK: - Fix 5: collect failure records all requested types

    func testCollectFailureRecordsAllRequestedTypes() async {
        // When collect hard-fails (exit 3), every requested type must appear in failed.
        let calls = StubCalls()
        let collector = LogLineCollector()
        let result = await CLIBridge.runGenerateAll(
            types: [.xlsx, .html, .pdf],
            collectFresh: true,
            profile: "test-profile",
            onLine: { collector.append($0) },
            collect: { calls.collect += 1; return CLIBridge.exitCodeUnauthorized },
            generateXLSX: { calls.xlsx += 1; return 0 },
            generateHTML: { calls.html += 1; return 0 },
            generatePDF: { calls.pdf += 1; return 0 },
            generateCSV: { calls.csv += 1; return 0 },
            tighten: { calls.tighten += 1 },
            cacheAge: { "" }
        )
        XCTAssertEqual(result.failed.count, 3, "all 3 requested types must be recorded as failed")
        XCTAssertTrue(result.failed.map(\.type).contains(.xlsx))
        XCTAssertTrue(result.failed.map(\.type).contains(.html))
        XCTAssertTrue(result.failed.map(\.type).contains(.pdf))
        XCTAssertEqual(calls.xlsx, 0, "no generator may run after unauthorized short-circuit")
        XCTAssertEqual(calls.html, 0)
        XCTAssertEqual(calls.pdf, 0)
    }

    // MARK: - Fix 6: generator throw continues to next format

    func testXlsxThrowContinuesToHtml() async {
        // When the XLSX generator throws (pre-spawn), the HTML generator must still run.
        let calls = StubCalls()
        let collector = LogLineCollector()
        let result = await CLIBridge.runGenerateAll(
            types: [.xlsx, .html],
            collectFresh: false,
            profile: "test-profile",
            onLine: { collector.append($0) },
            collect: { calls.collect += 1; return 0 },
            generateXLSX: { throw CLIBridgeError.executableNotFound },
            generateHTML: { calls.html += 1; return 0 },
            generatePDF: { calls.pdf += 1; return 0 },
            generateCSV: { calls.csv += 1; return 0 },
            tighten: { calls.tighten += 1 },
            cacheAge: { "1 day old" }
        )
        XCTAssertEqual(calls.html, 1, "HTML generator must still run after XLSX throw")
        XCTAssertTrue(result.failed.map(\.type).contains(.xlsx),
                      "XLSX must be recorded as failed")
        XCTAssertTrue(result.succeeded.contains(.html),
                      "HTML must be recorded as succeeded")
        XCTAssertEqual(result.failed.first(where: { $0.type == .xlsx })?.exitCode, -1,
                       "pre-spawn failure must record exit code -1")
        XCTAssertEqual(calls.tighten, 1, "permission sweep must run because HTML succeeded")
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
