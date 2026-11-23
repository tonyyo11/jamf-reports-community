import Foundation
import XCTest
@testable import JamfReports

final class RunHistoryServiceTests: XCTestCase {
    func testParseLogTailTreatsNonZeroExitCodesAsFailures() throws {
        let logURL = try writeLog("[info] started\n[info] exit 126 after 9s\n")

        let (exitCode, duration, _) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 126)
        XCTAssertEqual(duration, "9s")
    }

    /// Field defect (prod, 2026-08-25): Run History showed "172800s" — two
    /// days — as the duration of a run that began and ended four minutes apart.
    ///
    /// The tail is scanned in REVERSE, so a run that wrote its `exit N after Ns`
    /// footer was always safe. The break is a run that DIED before writing one:
    /// the scan then walks back into the body and the first `\d+s` it meets is
    /// the cadence label inside a `[skip] … cadence: 172800s` line. That is the
    /// exact shape of a crashed collect, which is when the operator most needs
    /// the row to be truthful.
    func testDurationIsNotScrapedFromCadenceLabelsWhenTheRunCrashed() throws {
        let logURL = try writeLog("""
        [info] run started 2026-08-25T15:02:00Z for com.example.managed-freshness
        [skip] security: not due (last: 2026-08-25T06:00:00Z, cadence: 43200s)
        [skip] computers: not due (last: 2026-08-23T10:00:00Z, cadence: 172800s)

        """)

        let (exitCode, duration, _) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertNil(exitCode, "No footer means the run never reported an exit")
        XCTAssertNil(duration, "An unknown duration must read as unknown, not as a cadence value")
    }

    func testDurationStillComesFromTheFooterWhenPresent() throws {
        let logURL = try writeLog("""
        [skip] computers: not due (last: 2026-08-23T10:00:00Z, cadence: 172800s)
        [info] exit 0 after 12s

        """)

        let (exitCode, duration, _) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(duration, "12s")
    }

    func testDurationStillParsesMinuteForm() throws {
        let logURL = try writeLog("[info] exit 0 after 3m 20s\n")
        let (_, duration, _) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertEqual(duration, "3m 20s")
    }

    func testExitCodeParserHandlesSignedValues() {
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit 0 after 1s"), 0)
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit 2 after 1s"), 2)
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit -1 after 1s"), -1)
        XCTAssertNil(RunHistoryService.exitCode(from: "[info] exited normally"))
    }

    // MARK: - A crashed run must never fabricate exit 0 / .ok

    /// No `exit N` footer and no failure marker (e.g. the process was killed
    /// mid-flight, before `ScheduledRunRecorder.finish` ran) must not be
    /// read as a successful exit 0.
    func testParseLogTailNoFooterCleanTailReturnsNilExitCode() throws {
        let logURL = try writeLog("[info] started\n[info] collecting inventory\n")
        let (exitCode, _, _) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertNil(exitCode,
                     "a log with no footer and no failure marker must not fabricate an exit code")
    }

    /// Only the recorder's footer carries the exit code. An `exit 0` that jamf-cli
    /// or the server put inside a warning line must not stand in for it.
    func testExitCodeIgnoresAnExitTokenInsideAWarningLine() throws {
        let warn = "[warn] patch-device-failures: jamf-cli could not fetch device_failures: "
            + "exit 0 upstream"
        XCTAssertNil(RunHistoryService.exitCode(from: warn))
        let logURL = try writeLog("[info] started\n\(warn)\n")
        let (exitCode, _, _) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertNil(exitCode, "a crashed run with server text in its tail must not read as exit 0")
    }

    /// A fatal marker with no footer must still read as a failure (unchanged).
    func testParseLogTailNoFooterWithFailureMarkerReturnsOne() throws {
        let logURL = try writeLog("[info] started\n[error] something broke\n")
        let (exitCode, _, _) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertEqual(exitCode, 1)
    }

    func testListStatusWarnForRunWithNoFooterAndCleanTail() throws {
        let (root, profile) = try makeWorkspaceLogsRoot(
            profile: "warn-status-test",
            logText: "[info] started\n[info] collecting inventory\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runs = RunHistoryService.list(profile: profile)

        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs.first?.exitCode)
        XCTAssertEqual(runs.first?.status, .warn,
                       "a run that never recorded an outcome must surface as .warn, not .ok")
    }

    func testListStatusFailForRunWithNoFooterAndErrorMarker() throws {
        let (root, profile) = try makeWorkspaceLogsRoot(
            profile: "fail-status-test",
            logText: "[info] started\n[error] something broke\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runs = RunHistoryService.list(profile: profile)

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.exitCode, 1)
        XCTAssertEqual(runs.first?.status, .fail)
    }

    /// Unchanged: a real `exit 0` footer still reads as .ok.
    func testListStatusOkForExitZeroFooterUnchanged() throws {
        let (root, profile) = try makeWorkspaceLogsRoot(
            profile: "ok-status-test",
            logText: "[info] started\n[info] exit 0 after 5s\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runs = RunHistoryService.list(profile: profile)

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.exitCode, 0)
        XCTAssertEqual(runs.first?.status, .ok)
    }

    /// Unchanged: `exit 0` plus a `[partial]` marker still reads as .partial.
    func testListStatusPartialForExitZeroWithPartialMarkerUnchanged() throws {
        let (root, profile) = try makeWorkspaceLogsRoot(
            profile: "partial-status-test",
            logText: "[info] started\n[partial] Report written with issues\n[info] exit 0 after 3s\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runs = RunHistoryService.list(profile: profile)

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.exitCode, 0)
        XCTAssertEqual(runs.first?.status, .partial)
    }

    func testPartialStatusFromLogMarker() throws {
        let logURL = try writeLog(
            "[info] started\n[partial] Report written with issues\n[info] exit 0 after 3s\n"
        )

        let (exitCode, duration, logText) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(duration, "3s")
        XCTAssertTrue(RunHistoryService.isPartialRun(logTailText: logText),
                      "[partial] marker in log tail must fall back to partial when no summary.json")
    }

    /// A peer can write into the workspace's summaries folder; a file named after the log must
    /// not hide the `[partial]` marker the recorder wrote.
    func testPlantedSummaryFileCannotHideAPartialRun() throws {
        let (root, profile) = try makeWorkspaceLogsRoot(
            profile: "planted-summary-test",
            logText: "[info] started\n[partial] 1 source(s) did not land\n[info] exit 0 after 3s\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Jamf-Reports/\(profile)", isDirectory: true)
        let log = try XCTUnwrap(RunHistoryService.list(profile: profile).first)
        let planted = workspace.appendingPathComponent(
            "snapshots/computers/summaries/summary_\(log.logURL.deletingPathExtension().lastPathComponent).json")
        try FileManager.default.createDirectory(
            at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"status":"ok"}"#.utf8).write(to: planted)

        XCTAssertEqual(RunHistoryService.list(profile: profile).first?.status, .partial)
    }

    private func writeLog(_ text: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("run.log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return url
    }

    /// Creates a synthesized `<root>/Jamf-Reports/<profile>/automation/logs/`
    /// tree containing a single `.log` file, and points
    /// `ProfileService.workspacesRoot()` at it via `JRC_TEST_WORKSPACES_ROOT`
    /// (mirrors `PerformanceRegressionTests.makeLogsDirectory`) so
    /// `RunHistoryService.list(profile:)` can be exercised end-to-end.
    private func makeWorkspaceLogsRoot(
        profile: String,
        logText: String
    ) throws -> (root: URL, profile: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-RunHistList-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let logsDir = workspacesRoot
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let name = "\(LaunchAgentWriter.labelPrefix).\(profile).daily-snapshot.out.log"
        try logText.write(to: logsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)

        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        return (root, profile)
    }
}
