import Foundation
import XCTest
@testable import JamfReports

/// Contract test for `CLIBridge.runAndCapture`:
///   - stdout is captured into the returned Data (silently — NOT streamed to onLine)
///   - stderr is streamed to onLine line-by-line (and NOT captured)
///
/// Locks the fix from commit 5d69c28 that stopped a 360 KB JSON payload
/// (`pro scripts list --output json`) leaking into the live run-log popover.
final class CLIBridgeStreamingTests: XCTestCase {

    func testStdoutCapturedNotStreamed_StderrStreamedNotCaptured() async throws {
        let bridge = CLIBridge()
        let collector = LineCollector()
        let (exit, data) = try await bridge.runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'PAYLOAD-LINE-1\\nPAYLOAD-LINE-2\\n'; printf 'PROGRESS-LINE\\n' 1>&2"],
            onLine: { line in collector.append(line) }
        )
        XCTAssertEqual(exit, 0)

        // stdout: captured intact, including both lines.
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "PAYLOAD-LINE-1\nPAYLOAD-LINE-2\n"
        )

        // No drain wait: runAndCapture returns only after stderr's EOF (#207 G24).
        let lines = collector.snapshot().map(\.text)

        // stderr: surfaced via onLine.
        XCTAssertTrue(
            lines.contains("PROGRESS-LINE"),
            "stderr line should be streamed via onLine; got: \(lines)"
        )

        // stdout: NOT surfaced via onLine — the whole bug.
        XCTAssertFalse(
            lines.contains("PAYLOAD-LINE-1") || lines.contains("PAYLOAD-LINE-2"),
            "stdout payload must NOT leak into onLine; got: \(lines)"
        )
    }

    func testStdoutPayloadIsBinarySafe() async throws {
        // A real-world `pro scripts list --output json` response is one massive
        // line of JSON with embedded escape sequences. Confirm it round-trips.
        let bridge = CLIBridge()
        let collector = LineCollector()
        let payload = #"{"scripts":[{"name":"FileVault","body":"echo \"hi\"\nexit 0"}]}"#
        let (exit, data) = try await bridge.runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' '\(payload)'"],
            onLine: { line in collector.append(line) }
        )
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(String(data: data, encoding: .utf8), payload)
        // Default environment is now environmentForJamfCLI() (S-02), so
        // no inherited variables can leak into the child. The test
        // command writes only to stdout so collector stays empty.
        XCTAssertTrue(collector.snapshot().isEmpty, "no log lines should leak for clean stdout-only command")
    }

    /// Collect classifies a command that exits 0 without data from its stderr, so a tail
    /// still in the pipe at exit must reach onLine before runAndCapture returns (#207 G24).
    /// 20,000 lines is more than a pipe holds, so the child can exit with the tail unread.
    /// The handler splits lines at chunk boundaries, hence the comparison of joined text.
    func testEveryStderrLineHasArrivedWhenItReturns() async throws {
        let lines = (1...20_000).map { "line-\($0)" }
        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Stderr-\(UUID().uuidString).txt")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let bridge = CLIBridge()
        let collector = LineCollector()
        let (exit, data) = try await bridge.runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/cat \"$1\" 1>&2", "sh", file.path],
            onLine: { line in collector.append(line) }
        )

        XCTAssertEqual(exit, 0)
        XCTAssertTrue(data.isEmpty)
        let received = collector.snapshot().map(\.text).joined()
        let expected = lines.joined()
        XCTAssertEqual(received.utf8.count, expected.utf8.count, "stderr text was dropped")
        XCTAssertTrue(received == expected, "stderr text arrived incomplete or out of order")
    }

    /// The same contract without the race: the line is written only after the shell has
    /// exited, so returning at termination loses it every time, not only under load.
    func testStderrWrittenAfterTheProcessExitsArrivesBeforeReturn() async throws {
        let bridge = CLIBridge()
        let collector = LineCollector()
        // The shell exits at once; a background writer with its stdout closed prints later.
        let (exit, _) = try await bridge.runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(exec 1>&-; sleep 0.3; printf 'LATE-LINE\\n' 1>&2) & exit 0"],
            onLine: { line in collector.append(line) }
        )
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(
            collector.snapshot().map(\.text).contains("LATE-LINE"),
            "stderr written after exit must reach onLine before runAndCapture returns"
        )
    }

    // MARK: - timeout (#207 G22)

    /// The shell execs sleep so SIGTERM reaches the process that holds the pipes; a child left
    /// behind would keep stdout open and the call would wait for its EOF.
    private func sleepingChild(_ preamble: String = "") -> [String] {
        ["-c", "\(preamble)exec /bin/sleep 10"]
    }

    func testTimeoutTerminatesTheChildAndReturnsTheTimedOutCode() async throws {
        let bridge = CLIBridge()
        let started = Date()
        let (exit, data) = try await bridge.runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: sleepingChild("printf 'PARTIAL'; "),
            timeout: 0.5,
            onLine: CLIBridge.noOpOnLine
        )

        XCTAssertEqual(exit, CLIBridge.exitCodeTimedOut)
        XCTAssertEqual(String(data: data, encoding: .utf8), "PARTIAL",
                       "stdout read before the timeout is still returned")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8,
                          "returned at the timeout, not at the child's exit")
    }

    func testTimeoutKeepsAnUnterminatedLastStderrLine() async throws {
        let collector = LineCollector()
        let (exit, _) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            // A grandchild keeps the pipes open past the shell's SIGTERM, so stderr never
            // reaches EOF and only the timeout path can flush the partial line.
            arguments: ["-c", "printf 'no newline' 1>&2; (trap '' TERM; exec /bin/sleep 2) & wait"],
            timeout: 0.5,
            onLine: { line in collector.append(line) }
        )

        XCTAssertEqual(exit, CLIBridge.exitCodeTimedOut)
        XCTAssertTrue(collector.snapshot().map(\.text).contains("no newline"),
                      "a partial stderr line read before the timeout must reach onLine")
    }

    func testTimedOutChildIsGoneWhenTheCallReturns() async throws {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Timeout-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let (exit, _) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: sleepingChild("echo $$ > '\(pidFile.path)'; "),
            timeout: 0.5,
            onLine: CLIBridge.noOpOnLine
        )

        XCTAssertEqual(exit, CLIBridge.exitCodeTimedOut)
        assertProcessGone(try pid(in: pidFile), "the child must not outlive the call")
    }

    private func pid(in file: URL) throws -> Int32 {
        try XCTUnwrap(
            Int32(try String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// errno is read before any assertion runs: XCTest can overwrite it while evaluating one.
    private func assertProcessGone(
        _ pid: Int32, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let result = kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1, message, file: file, line: line)
        XCTAssertEqual(error, ESRCH, message, file: file, line: line)
    }

    /// Stubs for a child that outlives the timeout's SIGTERM. Neither execs: the shell is not
    /// the process holding the pipes, a sleeper that ignores SIGTERM is, as a grandchild would.
    /// The shell's pid goes to `pid`, the sleeper's to `sleeper`.
    private func runUncooperativeChild(
        shellIgnoresTerm: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (elapsed: TimeInterval, pid: Int32) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let sleeperFile = dir.appendingPathComponent("sleeper")
        let script = (shellIgnoresTerm ? "trap '' TERM; " : "")
            + "echo $$ > '\(pidFile.path)'; "
            + "(trap '' TERM; exec /bin/sleep 10) & echo $! > '\(sleeperFile.path)'; wait"

        let started = Date()
        let (exit, _) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: 0.5,
            onLine: CLIBridge.noOpOnLine
        )
        let elapsed = Date().timeIntervalSince(started)
        // The sleeper outlives the shell by design; do not leave it for the next 10 seconds.
        if let sleeper = try? pid(in: sleeperFile) { kill(sleeper, SIGKILL) }

        XCTAssertEqual(exit, CLIBridge.exitCodeTimedOut, file: file, line: line)
        return (elapsed, try pid(in: pidFile))
    }

    /// The bound is the timeout, the SIGTERM grace and a margin for a loaded machine, far under
    /// the 10 seconds the stub would otherwise run.
    private var uncooperativeBound: TimeInterval { 0.5 + CLIBridge.timeoutKillGrace + 3 }

    func testTimeoutKillsAChildThatIgnoresSIGTERM() async throws {
        let (elapsed, pid) = try await runUncooperativeChild(shellIgnoresTerm: true)

        XCTAssertLessThan(elapsed, uncooperativeBound,
                          "SIGKILL after the grace, not the child's exit")
        assertProcessGone(pid, "SIGKILL must have removed the shell")
    }

    func testTimeoutReturnsWhileAGrandchildStillHoldsThePipes() async throws {
        let (elapsed, pid) = try await runUncooperativeChild(shellIgnoresTerm: false)

        XCTAssertLessThan(elapsed, uncooperativeBound, "no wait for EOF the grandchild holds open")
        assertProcessGone(pid, "the shell dies on SIGTERM")
    }

    func testACommandThatFinishesInsideTheTimeoutIsNotTimedOut() async throws {
        let (exit, data) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'DONE'; exit 3"],
            timeout: 30,
            onLine: CLIBridge.noOpOnLine
        )

        XCTAssertEqual(exit, 3, "the real exit code, not the timeout's")
        XCTAssertEqual(String(data: data, encoding: .utf8), "DONE")
    }
}

/// Thread-safe collector for onLine callbacks (the handler is called from a
/// readabilityHandler queue, not the test thread).
private final class LineCollector: @unchecked Sendable {
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
