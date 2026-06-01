import XCTest
@testable import JamfReports

/// ScheduledRunRecorder writes the per-run log + status JSON that Run History
/// and the Schedules screen read. Before it existed, native scheduled/manual
/// runs were invisible in both UIs (logs went only to ~/Library/Logs/).
final class ScheduledRunRecorderTests: XCTestCase {

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return workspace
    }

    private let label = "com.github.tonyyo11.jamf-reports-community.testprofile.daily-report"

    func testInitCreatesLogInAutomationLogs() throws {
        let workspace = try makeWorkspace()
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: workspace, label: label))

        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.logURL.path))
        XCTAssertEqual(
            recorder.logURL.deletingLastPathComponent().lastPathComponent, "logs"
        )
        XCTAssertEqual(
            recorder.logURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "automation"
        )
        XCTAssertTrue(recorder.logURL.lastPathComponent.hasPrefix(label + "."))
        XCTAssertEqual(recorder.logURL.pathExtension, "log")
    }

    func testRecordAndFinishWriteLogWithExitFooter() throws {
        let workspace = try makeWorkspace()
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: workspace, label: label))

        recorder.record("[ok] collected 5 snapshots")
        recorder.finish(exitCode: 0)

        let text = try String(contentsOf: recorder.logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[info] run started"))
        XCTAssertTrue(text.contains("[ok] collected 5 snapshots"))
        XCTAssertTrue(text.contains("[info] exit 0 after"))
    }

    func testRunHistoryParsesRecorderLog() throws {
        let workspace = try makeWorkspace()
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: workspace, label: label))
        recorder.record("[ok] generate complete")
        recorder.finish(exitCode: 0)

        // RunHistoryService.parseLogTail is the same parser list() applies.
        let (exitCode, _, _) = RunHistoryService.parseLogTail(from: recorder.logURL)
        XCTAssertEqual(exitCode, 0)
    }

    func testRunHistoryParsesFailedRecorderLog() throws {
        let workspace = try makeWorkspace()
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: workspace, label: label))
        recorder.record("[error] something broke")
        recorder.finish(exitCode: 1)

        let (exitCode, _, _) = RunHistoryService.parseLogTail(from: recorder.logURL)
        XCTAssertEqual(exitCode, 1)
    }

    func testFinishWritesStatusJSONForSchedulesLastRun() throws {
        let workspace = try makeWorkspace()
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: workspace, label: label))
        let artifact = workspace.appendingPathComponent("report_2026-06-01.xlsx")
        recorder.finish(exitCode: 0, artifacts: [artifact])

        XCTAssertEqual(recorder.statusURL.lastPathComponent, "\(label)_status.json")
        let data = try Data(contentsOf: recorder.statusURL)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["success"] as? Bool, true)
        XCTAssertEqual(payload["exit_code"] as? Int, 0)
        XCTAssertEqual(payload["xlsx_report_path"] as? String, artifact.path)
        // finished_at must parse as ISO8601 — the format LaunchAgentService.dateValue reads.
        let finishedAt = try XCTUnwrap(payload["finished_at"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: finishedAt))
    }

    func testFailedRunStatusJSONReportsFailure() throws {
        let workspace = try makeWorkspace()
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: workspace, label: label))
        recorder.finish(exitCode: 3)

        let data = try Data(contentsOf: recorder.statusURL)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["success"] as? Bool, false)
        XCTAssertEqual(payload["exit_code"] as? Int, 3)
    }

    func testRecorderLogNamePattern() {
        XCTAssertTrue(ScheduledRunRecorder.isRecorderLogName("\(label).20260601-185500.log"))
        XCTAssertFalse(ScheduledRunRecorder.isRecorderLogName("\(label).out.log"))
        XCTAssertFalse(ScheduledRunRecorder.isRecorderLogName("\(label).err.log"))
        XCTAssertFalse(ScheduledRunRecorder.isRecorderLogName("stdout.log"))
        XCTAssertFalse(ScheduledRunRecorder.isRecorderLogName("\(label).20260601-185500.log.1"))
    }

    func testPruneKeepsNewestAndIgnoresLegacyLogs() throws {
        let workspace = try makeWorkspace()
        let logsDir = workspace
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // 5 recorder-pattern logs with increasing mtimes + 1 legacy log.
        var recorderLogs: [URL] = []
        for index in 0..<5 {
            let url = logsDir.appendingPathComponent("\(label).2026060\(index)-12000\(index).log")
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: TimeInterval(index * 60))],
                ofItemAtPath: url.path
            )
            recorderLogs.append(url)
        }
        let legacy = logsDir.appendingPathComponent("\(label).out.log")
        try "legacy".write(to: legacy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)],
            ofItemAtPath: legacy.path
        )

        ScheduledRunRecorder.pruneRunLogs(in: logsDir, keep: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: logsDir.path).sorted()
        // Newest 2 recorder logs survive; legacy log untouched even though oldest.
        XCTAssertTrue(remaining.contains(legacy.lastPathComponent))
        XCTAssertTrue(remaining.contains(recorderLogs[4].lastPathComponent))
        XCTAssertTrue(remaining.contains(recorderLogs[3].lastPathComponent))
        XCTAssertEqual(remaining.count, 3)
    }

    func testInitReturnsNilWhenWorkspaceNotWritable() {
        // A path under a file (not a directory) cannot have subdirectories created.
        let bogus = URL(fileURLWithPath: "/dev/null/not-a-dir")
        XCTAssertNil(ScheduledRunRecorder(workspace: bogus, label: label))
    }
}
