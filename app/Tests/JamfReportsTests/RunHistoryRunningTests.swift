import XCTest
@testable import JamfReports

/// Run History used to read a run still in progress as WARN with no duration, and dated every
/// row at the log's last write. A run with no exit footer now reads "Running" while its recorder
/// still has the log open, "interrupted" (WARN) once it does not, and every row carries the
/// run's start.
final class RunHistoryRunningTests: XCTestCase {

    private let profile = "runs"
    private let label = "\(LaunchAgentWriter.labelPrefix).manual-collect"

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-run-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return try XCTUnwrap(ProfileService.workspaceURL(for: profile))
    }

    private func hoursAgo(_ hours: Double) -> Date {
        let whole = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970.rounded()
        return Date(timeIntervalSince1970: whole)
    }

    func testARunStillWritingReadsAsRunningAtItsStart() throws {
        let workspace = try makeWorkspace()
        let started = hoursAgo(2)
        let recorder = try XCTUnwrap(
            ScheduledRunRecorder(workspace: workspace, label: label, now: started))
        recorder.record("[plan] profile runs — collecting 3 sources: a, b, c")

        let run = try XCTUnwrap(RunHistoryService.list(profile: profile).first)
        XCTAssertTrue(run.isRunning)
        XCTAssertNil(run.exitCode)
        XCTAssertNil(run.duration)
        XCTAssertEqual(run.date, started, "the row is dated at the start, not the last write")

        recorder.finish(exitCode: 0)
        let done = try XCTUnwrap(RunHistoryService.list(profile: profile).first)
        XCTAssertFalse(done.isRunning)
        XCTAssertEqual(done.status, .ok)
        XCTAssertEqual(done.exitCode, 0)
        XCTAssertNotNil(done.duration)
        XCTAssertEqual(done.date, started, "finishing does not move the row")
    }

    /// No footer and nobody writing: killed mid-flight. That stays a warning, never success
    /// and never "running".
    func testAnAbandonedLogReadsAsInterrupted() throws {
        let workspace = try makeWorkspace()
        let logs = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let started = hoursAgo(5)
        let name = "\(label).\(ScheduledRunRecorder.timestamp(from: started)).log"
        try "[info] run started 2026-01-01T00:00:00Z for \(label)\n[info] collecting a for runs\n"
            .write(to: logs.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let run = try XCTUnwrap(RunHistoryService.list(profile: profile).first)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.status, .warn)
        XCTAssertNil(run.exitCode)
        XCTAssertEqual(run.date, started)
    }

    func testRowsAreOrderedByStartNotByLastWrite() throws {
        let workspace = try makeWorkspace()
        let older = try XCTUnwrap(ScheduledRunRecorder(
            workspace: workspace, label: label, now: hoursAgo(3)))
        let newer = try XCTUnwrap(ScheduledRunRecorder(
            workspace: workspace, label: label, now: hoursAgo(1)))
        newer.finish(exitCode: 0)
        older.finish(exitCode: 0)

        let runs = RunHistoryService.list(profile: profile)
        XCTAssertEqual(runs.map(\.date), [hoursAgo(1), hoursAgo(3)])
    }

    /// The tick is another process. When it dies, its lock goes with it, so a killed run
    /// stops reading as running.
    func testAnotherProcessHoldingTheLogIsRunningUntilItDies() throws {
        let workspace = try makeWorkspace()
        let logs = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent(
            "\(label).\(ScheduledRunRecorder.timestamp(from: hoursAgo(1))).log")
        try "[info] run started 2026-01-01T00:00:00Z for \(label)\n"
            .write(to: log, atomically: true, encoding: .utf8)

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", """
            use Fcntl qw(:flock); open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die;
            $| = 1; print "ready\\n"; sleep 60;
            """, log.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer {
            if holder.isRunning { holder.terminate() }
            holder.waitUntilExit()
        }
        XCTAssertEqual(
            String(data: out.fileHandleForReading.availableData, encoding: .utf8), "ready\n")

        XCTAssertTrue(ScheduledRunRecorder.isRunInProgress(logURL: log))
        XCTAssertTrue(try XCTUnwrap(RunHistoryService.list(profile: profile).first).isRunning)

        holder.terminate()
        holder.waitUntilExit()
        XCTAssertFalse(ScheduledRunRecorder.isRunInProgress(logURL: log))
        XCTAssertFalse(try XCTUnwrap(RunHistoryService.list(profile: profile).first).isRunning)
    }

    func testStartComesFromTheStampInTheLogName() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let name = "\(label).\(ScheduledRunRecorder.timestamp(from: started)).log"
        XCTAssertEqual(ScheduledRunRecorder.startDate(fromLogName: name), started)
        XCTAssertNil(ScheduledRunRecorder.startDate(fromLogName: "\(label).out.log"))
    }
}
