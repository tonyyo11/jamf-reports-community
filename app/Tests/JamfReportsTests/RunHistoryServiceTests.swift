import Foundation
import XCTest
import CryptoKit
@testable import JamfReports

final class RunHistoryServiceTests: XCTestCase {
    func testParseLogTailTreatsNonZeroExitCodesAsFailures() throws {
        let logURL = try writeLog("[info] started\n[info] exit 126 after 9s\n")

        let (exitCode, duration, _) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 126)
        XCTAssertEqual(duration, "9s")
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

    func testPartialStatusFromSummaryJSON() throws {
        let (logURL, workspace) = try writeWorkspaceLog(
            timestamp: "20260516-143000",
            logText: "[info] exit 0 after 5s\n",
            summaryStatus: "partial"
        )

        let (exitCode, duration, logText) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(duration, "5s")
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "Partial status from summary.json should be authoritative")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
    }

    func testPartialStatusFromLogMarker() throws {
        let logURL = try writeLog(
            "[info] started\n[partial] Report written with issues\n[info] exit 0 after 3s\n"
        )

        let (exitCode, duration, logText) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(duration, "3s")
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "[partial] marker in log tail must fall back to partial when no summary.json")
    }

    func testSummaryJSONOverridesLogAmbiguity() throws {
        let (logURL, workspace) = try writeWorkspaceLog(
            timestamp: "20260516-144500",
            logText: "[info] exit 0 after 2s\n",
            summaryStatus: "ok"
        )

        let (exitCode, duration, logText) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(duration, "2s")
        XCTAssertFalse(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                       "summary.json status=ok must override any ambiguity")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
    }

    // MARK: - PR-11 / threat-model T-12: manifest verification

    /// When the sibling manifest.json hash matches, the verified summary
    /// is trusted — same as legacy behavior, no change.
    func testPartialStatusFromManifestVerifiedSummary() throws {
        let (logURL, workspace) = try writeWorkspaceLogWithManifest(
            timestamp: "20260517-130000",
            logText: "[info] exit 0 after 5s\n",
            summaryStatus: "partial",
            manifestMode: .matching
        )
        let (_, _, logText) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "manifest-verified summary with status=partial must be trusted")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
    }

    /// PR-11 attack scenario: an attacker flips `"status":"partial"` to
    /// `"status":"ok"` AFTER the manifest was written. The sibling
    /// manifest's hash no longer matches → Swift falls back to scanning
    /// the log for `[partial]` markers instead of trusting the tampered
    /// file. Closes the cross-trust-boundary bypass on the PARTIAL pill.
    func testPartialStatusFallsBackToLogOnManifestMismatch() throws {
        let (logURL, workspace) = try writeWorkspaceLogWithManifest(
            timestamp: "20260517-131500",
            logText: "[info] [partial] something failed\n[info] exit 0 after 4s\n",
            summaryStatus: "ok",            // attacker flipped this
            manifestMode: .mismatchedHash    // manifest still pins the original partial-status hash
        )
        let (_, _, logText) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "manifest-mismatched summary must NOT be trusted; fall back to log marker")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
    }

    /// A corrupt manifest (unparseable JSON) must also trigger the log
    /// fallback — we can't verify the summary, so we can't trust it.
    func testPartialStatusFallsBackToLogOnCorruptManifest() throws {
        let (logURL, workspace) = try writeWorkspaceLogWithManifest(
            timestamp: "20260517-132500",
            logText: "[info] [partial] failure\n[info] exit 0 after 2s\n",
            summaryStatus: "ok",
            manifestMode: .corrupt
        )
        let (_, _, logText) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "corrupt manifest must NOT be trusted; fall back to log marker")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
    }

    /// PR-11 security-reviewer M-01: `.omitted` is an attacker-injection
    /// bypass post-PR-11. Every legitimate write registers the file in the
    /// manifest; a file present in summaries/ but missing from
    /// manifest.json must mean either (a) the manifest is stale (rare
    /// race) or (b) attacker injection. Either way the file cannot be
    /// trusted — fall back to log marker.
    func testPartialStatusFallsBackToLogOnOmittedManifest() throws {
        let (logURL, workspace) = try writeWorkspaceLogWithManifest(
            timestamp: "20260517-140000",
            logText: "[info] [partial] failure\n[info] exit 0 after 3s\n",
            summaryStatus: "ok",                 // attacker-injected status
            manifestMode: .omitsThisFile         // manifest exists, lists a different file
        )
        let (_, _, logText) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "manifest-present-but-omits-this-file is injection bypass; fall back to log marker")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
    }

    /// Absent manifest (legacy, pre-PR-11) preserves prior behavior: the
    /// summary file is trusted at face value.
    func testPartialStatusTrustsSummaryWhenManifestAbsent() throws {
        // The original writeWorkspaceLog helper writes no manifest;
        // verify behavior remains "trust summary content."
        let (logURL, workspace) = try writeWorkspaceLog(
            timestamp: "20260517-133500",
            logText: "[info] exit 0 after 1s\n",
            summaryStatus: "partial"
        )
        let (_, _, logText) = RunHistoryService.parseLogTail(from: logURL)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: logURL, logTailText: logText),
                      "manifest-absent summary preserves legacy trust behavior")
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
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

    /// Creates `<workspace>/automation/logs/<ts>.log` and
    /// `<workspace>/snapshots/computers/summaries/summary_<ts>.json` so
    /// `RunHistoryService.isPartialRun` can resolve the sibling summary.
    private func writeWorkspaceLog(
        timestamp: String,
        logText: String,
        summaryStatus: String
    ) throws -> (logURL: URL, workspace: URL) {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logsDir = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        let summariesDir = workspace
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("computers", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let logURL = logsDir.appendingPathComponent("\(timestamp).log")
        try logText.write(to: logURL, atomically: true, encoding: .utf8)

        let summaryURL = summariesDir.appendingPathComponent("summary_\(timestamp).json")
        let jsonData = try JSONSerialization.data(withJSONObject: ["status": summaryStatus])
        try jsonData.write(to: summaryURL)

        return (logURL, workspace)
    }

    /// Test-only enum for the manifest scenarios PR-11 exercises.
    enum ManifestMode {
        /// Manifest hash matches the summary content exactly.
        case matching
        /// Manifest lists a different hash than what's on disk
        /// (the documented T-12 attack: tampered summary after manifest write).
        case mismatchedHash
        /// Manifest file exists but is unparseable JSON.
        case corrupt
        /// Manifest exists and is well-formed, but the summary's
        /// filename is NOT listed (attacker dropped a file into
        /// summaries/ without manifest privileges — M-01 injection).
        case omitsThisFile
    }

    /// Like `writeWorkspaceLog` but also writes a `manifest.json` sibling.
    private func writeWorkspaceLogWithManifest(
        timestamp: String,
        logText: String,
        summaryStatus: String,
        manifestMode: ManifestMode
    ) throws -> (logURL: URL, workspace: URL) {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logsDir = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        let summariesDir = workspace
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("computers", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let logURL = logsDir.appendingPathComponent("\(timestamp).log")
        try logText.write(to: logURL, atomically: true, encoding: .utf8)

        let summaryURL = summariesDir.appendingPathComponent("summary_\(timestamp).json")
        let summaryPayload = try JSONSerialization.data(
            withJSONObject: ["status": summaryStatus], options: [.sortedKeys]
        )
        try summaryPayload.write(to: summaryURL)

        let manifestURL = summariesDir.appendingPathComponent(SnapshotManifest.fileName)
        switch manifestMode {
        case .matching:
            let hash = SHA256.hash(data: summaryPayload)
                .map { String(format: "%02x", $0) }.joined()
            try writeManifest(at: manifestURL, files: [summaryURL.lastPathComponent: hash])
        case .mismatchedHash:
            // Pin a hash that doesn't match the current summary contents.
            let stalePayload = try JSONSerialization.data(
                withJSONObject: ["status": "partial"], options: [.sortedKeys]
            )
            let staleHash = SHA256.hash(data: stalePayload)
                .map { String(format: "%02x", $0) }.joined()
            try writeManifest(at: manifestURL, files: [summaryURL.lastPathComponent: staleHash])
        case .corrupt:
            try Data("not even close to json {".utf8).write(to: manifestURL)
        case .omitsThisFile:
            // Manifest exists with a DIFFERENT filename listed — simulates
            // an attacker writing summary_<x>.json into a directory that
            // already has a legitimate manifest from prior runs.
            let otherHash = SHA256.hash(data: Data("other".utf8))
                .map { String(format: "%02x", $0) }.joined()
            try writeManifest(at: manifestURL, files: ["summary_other.json": otherHash])
        }

        return (logURL, workspace)
    }

    private func writeManifest(at url: URL, files: [String: String]) throws {
        let payload: [String: Any] = ["algorithm": "sha256", "files": files]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
    }
}
