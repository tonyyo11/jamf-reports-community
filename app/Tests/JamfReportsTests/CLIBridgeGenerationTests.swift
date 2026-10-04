import Foundation
import XCTest
@testable import JamfReports

/// Failure-branch coverage for `CLIBridge.generateAll`.
///
/// `CLIBridge` is `final` and its generator methods are intentionally not
/// behind the `CLICommand`/`CLIExecutor` protocol (ADR-W21 Hybrid scope).
/// `generateAll`'s orchestration was therefore extracted into
/// `CLIBridge.runGenerateAll`, which injects the XLSX/HTML/PDF/CSV generators
/// and the permission sweep as closures (Epic #102, item #3). This file covers
/// two layers:
///
/// 1. **`GenerateAllResult` struct semantics** — pure unit tests on the result
///    type callers rely on (`allSucceeded`, `anySucceeded`, accumulation order).
/// 2. **`runGenerateAll` branch coverage** — stub closures return synthetic
///    exit codes to exercise the partial-success and permission-sweep branches
///    without a live jamf-cli.
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

    // MARK: - runGenerateAll branch coverage (stubbed exit codes)

    /// Counts how many times each injected operation ran. MainActor-confined —
    /// every closure runs inside `runGenerateAll`, which is `@MainActor`.
    private final class StubCalls {
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
        xlsxExit: Int32 = 0,
        htmlExit: Int32 = 0,
        pdfExit: Int32 = 0,
        csvExit: Int32 = 0
    ) async -> (result: GenerateAllResult, calls: StubCalls) {
        let calls = StubCalls()
        let result = await CLIBridge.runGenerateAll(
            types: types,
            onLine: CLIBridge.noOpOnLine,
            generateXLSX: { calls.xlsx += 1; return xlsxExit },
            generateHTML: { calls.html += 1; return htmlExit },
            generatePDF: { calls.pdf += 1; return pdfExit },
            generateCSV: { calls.csv += 1; return csvExit },
            tighten: { calls.tighten += 1 }
        )
        return (result, calls)
    }

    func testRunGenerateAllPartialSuccessTightens() async {
        let (result, calls) = await runStubbed(xlsxExit: 0, htmlExit: 1)
        XCTAssertEqual(result.succeeded, [.xlsx])
        XCTAssertEqual(result.failed.map(\.type), [.html])
        XCTAssertEqual(result.failed.first?.exitCode, 1)
        XCTAssertFalse(result.allSucceeded)
        XCTAssertTrue(result.anySucceeded)
        XCTAssertEqual(calls.tighten, 1, "a partial success must still run the permission sweep")
    }

    func testRunGenerateAllAllFailuresSkipTighten() async {
        let (result, calls) = await runStubbed(xlsxExit: 1, htmlExit: 1)
        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(calls.tighten, 0, "the permission sweep must not run when nothing was written")
    }

    func testRunGenerateAllAllSuccessTightens() async {
        let (result, calls) = await runStubbed(xlsxExit: 0, htmlExit: 0)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertEqual(calls.tighten, 1)
    }

    func testRunGenerateAllOnlyRunsRequestedTypes() async {
        let (_, calls) = await runStubbed(types: [.xlsx])
        XCTAssertEqual(calls.xlsx, 1)
        XCTAssertEqual(calls.html, 0, "the HTML generator must not run when .html is not requested")
    }

    // MARK: - Fix 6: generator throw continues to next format

    func testXlsxThrowContinuesToHtml() async {
        // When the XLSX generator throws (pre-spawn), the HTML generator must still run.
        let calls = StubCalls()
        let result = await CLIBridge.runGenerateAll(
            types: [.xlsx, .html],
            onLine: CLIBridge.noOpOnLine,
            generateXLSX: { throw CLIBridgeError.executableNotFound },
            generateHTML: { calls.html += 1; return 0 },
            generatePDF: { calls.pdf += 1; return 0 },
            generateCSV: { calls.csv += 1; return 0 },
            tighten: { calls.tighten += 1 }
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

    // MARK: - Item 2: PDF and CSV generator coverage

    func testPdfAndCsvBothSucceed() async {
        let (result, calls) = await runStubbed(types: [.pdf, .csv], pdfExit: 0, csvExit: 0)
        XCTAssertEqual(calls.pdf, 1, "PDF generator must fire once")
        XCTAssertEqual(calls.csv, 1, "CSV generator must fire once")
        XCTAssertTrue(result.succeeded.contains(.pdf), "PDF must land in succeeded")
        XCTAssertTrue(result.succeeded.contains(.csv), "CSV must land in succeeded")
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testPdfNonZeroExitLandsInFailedCsvStillRuns() async {
        let (result, calls) = await runStubbed(types: [.pdf, .csv], pdfExit: 1, csvExit: 0)
        XCTAssertEqual(calls.pdf, 1)
        XCTAssertEqual(calls.csv, 1, "CSV must still run even after PDF non-zero exit")
        XCTAssertTrue(result.failed.contains(where: { $0.type == .pdf && $0.exitCode == 1 }),
                      "PDF must land in failed with exit 1")
        XCTAssertTrue(result.succeeded.contains(.csv), "CSV must land in succeeded")
    }

    func testPdfThrowLandsInFailedWithMinusOneCsvStillRuns() async {
        // PDF throws (pre-spawn failure) → recorded as exit -1; CSV still runs.
        let calls = StubCalls()
        let result = await CLIBridge.runGenerateAll(
            types: [.pdf, .csv],
            onLine: CLIBridge.noOpOnLine,
            generateXLSX: { calls.xlsx += 1; return 0 },
            generateHTML: { calls.html += 1; return 0 },
            generatePDF: { throw CLIBridgeError.executableNotFound },
            generateCSV: { calls.csv += 1; return 0 },
            tighten: { calls.tighten += 1 }
        )
        XCTAssertEqual(calls.pdf, 0, "throw in closure means the generator ran but threw")
        XCTAssertTrue(result.failed.contains(where: { $0.type == .pdf && $0.exitCode == -1 }),
                      "PDF throw must record exit code -1")
        XCTAssertEqual(calls.csv, 1, "CSV must still run after PDF throw")
        XCTAssertTrue(result.succeeded.contains(.csv))
    }

    func testCsvThrowLandsInFailedOthersUnaffected() async {
        // CSV throws; no other type is affected.
        let calls = StubCalls()
        let result = await CLIBridge.runGenerateAll(
            types: [.pdf, .csv],
            onLine: CLIBridge.noOpOnLine,
            generateXLSX: { calls.xlsx += 1; return 0 },
            generateHTML: { calls.html += 1; return 0 },
            generatePDF: { calls.pdf += 1; return 0 },
            generateCSV: { throw CLIBridgeError.executableNotFound },
            tighten: { calls.tighten += 1 }
        )
        XCTAssertEqual(calls.pdf, 1, "PDF generator must run unaffected by CSV throw")
        XCTAssertTrue(result.succeeded.contains(.pdf))
        XCTAssertTrue(result.failed.contains(where: { $0.type == .csv && $0.exitCode == -1 }),
                      "CSV throw must record exit code -1")
        XCTAssertFalse(result.failed.contains(where: { $0.type == .pdf }),
                       "PDF must not appear in failed")
    }
}
