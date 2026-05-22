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

        // Drain the readabilityHandler so any pending stderr lines arrive.
        try? await Task.sleep(nanoseconds: 50_000_000)
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
