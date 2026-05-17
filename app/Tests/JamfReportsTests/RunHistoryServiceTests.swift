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

    func testExitCodeParserHandlesSignedValues() {
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit 0 after 1s"), 0)
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit 2 after 1s"), 2)
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit -1 after 1s"), -1)
        XCTAssertNil(RunHistoryService.exitCode(from: "[info] exited normally"))
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

    private func writeLog(_ text: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("run.log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return url
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
}
