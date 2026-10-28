import XCTest
@testable import JamfReports

/// The tick's six-hour give-up ends the process, which does not end the jamf-cli call it
/// started: `CLIBridge.terminateRunningChildren` does, with SIGKILL after a grace.
final class TerminateRunningChildrenTests: XCTestCase {

    override func tearDown() {
        TimedProcessBox.reopen()
        super.tearDown()
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.withLock { texts.append(line.text) } }
        var all: [String] { lock.withLock { texts } }
    }

    /// Starts `script` under `/bin/sh` (not jamf-cli) and waits until it has said `up`, with
    /// the child's pid, on stderr.
    private func startChild(
        _ script: String
    ) async throws -> (exit: Task<Int32, Error>, pid: Int32) {
        let lines = Lines()
        let task = Task {
            try await CLIBridge().runAndCapture(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                onLine: lines.add).0
        }
        for _ in 0..<500 where !lines.all.contains(where: { $0.hasPrefix("up ") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let up = try XCTUnwrap(lines.all.first { $0.hasPrefix("up ") }, "the child never started")
        return (task, Int32(up.dropFirst(3)) ?? 0)
    }

    private static func isGone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    func testASlowChildIsTerminated() async throws {
        let (exit, pid) = try await startChild("echo up $$ >&2; exec sleep 60")

        XCTAssertEqual(CLIBridge.terminateRunningChildren(grace: 2), 1)

        let code = try await exit.value
        XCTAssertEqual(code, SIGTERM, "a child that exits on SIGTERM gets no SIGKILL")
        XCTAssertTrue(Self.isGone(pid))
    }

    func testAChildThatIgnoresSIGTERMIsKilledAfterTheGrace() async throws {
        let (exit, pid) = try await startChild(
            #"trap "" TERM; echo up $$ >&2; while :; do :; done"#)
        let started = Date()

        XCTAssertEqual(CLIBridge.terminateRunningChildren(grace: 0.3), 1)

        let code = try await exit.value
        XCTAssertEqual(code, SIGKILL)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(Self.isGone(pid))
    }

    /// The exit path latches: a call that starts once the pass has run (the next kind, Mac or
    /// schedule) is stopped by its own launch site instead of outliving the process.
    func testAChildStartedAfterThePassIsStoppedByItsOwnLaunchSite() async throws {
        CLIBridge.terminateRunningChildren(grace: 0.1)
        XCTAssertTrue(TimedProcessBox.isClosing)

        let (code, _) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 60"],
            onLine: { _ in })

        XCTAssertEqual(code, SIGTERM)
    }

    /// A launch after the pass gets the pass's SIGTERM, grace, SIGKILL, not SIGTERM alone. The
    /// test waits for the child's trap before calling `stopIfClosing`, which production cannot
    /// do: that is the case where the signal arrives first.
    func testALaunchAfterThePassThatIgnoresSIGTERMIsKilledAfterTheGrace() throws {
        let box = TimedProcessBox()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"trap "" TERM; echo up; while :; do :; done"#]
        let out = Pipe()
        process.standardOutput = out
        CLIBridge.terminateRunningChildren(grace: 0.1)
        XCTAssertTrue(TimedProcessBox.isClosing)
        try process.run()
        box.set(process)
        defer { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readData(ofLength: 3),
                              as: UTF8.self), "up\n")
        let started = Date()

        box.stopIfClosing(grace: 0.3)

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        // Foundation reaps the child on its own thread, a moment after the kill.
        for _ in 0..<200 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(process.isRunning, "SIGTERM alone left the child running")
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testNothingRunningTerminatesNothing() {
        XCTAssertEqual(CLIBridge.terminateRunningChildren(grace: 0.1), 0)
    }

    /// The give-up stops the child before it ends the process.
    func testTheGiveUpStopsTheChildBeforeItExits() async throws {
        let (exit, pid) = try await startChild("echo up $$ >&2; exec sleep 60")
        let goneAtExit = LockedFlag()

        exitAfterLockGiveUp(profiles: [], exit: { _ in goneAtExit.set(Self.isGone(pid)) })

        XCTAssertTrue(goneAtExit.value, "the child was still running when the tick exited")
        _ = try await exit.value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ new: Bool) { lock.withLock { flag = new } }
}
