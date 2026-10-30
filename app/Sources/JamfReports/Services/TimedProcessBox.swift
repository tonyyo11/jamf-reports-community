import Foundation
import Synchronization

/// Locked process box for task cancellation and the timeout: terminates the child after a
/// deadline (SIGTERM, then SIGKILL after `CLIBridge.timeoutKillGrace`). Shared by
/// `CLIBridge.runAndCapture` and `JamfCLIProbe`.
final class TimedProcessBox: Sendable {
    private struct State {
        var process: Process?
        var readHandles: [FileHandle] = []
        var disarmed = false
        var timedOut = false
    }
    private let state = Mutex(State())
    var didTimeOut: Bool { state.withLock { $0.timedOut } }
    func set(_ p: Process) {
        state.withLock { $0.process = p }
        Self.live.add(self)
    }
    func terminate() { state.withLock { $0.process?.terminate() } }

    /// Right after `process.run()` at every launch site: a process that is exiting
    /// (`terminateAllRunning` ran) must not leave a child it started after that pass. Same
    /// SIGTERM, grace, SIGKILL as the pass, blocking up to `grace`: the process is exiting, and
    /// a child that ignores SIGTERM would otherwise outlive it.
    func stopIfClosing(grace: TimeInterval = CLIBridge.timeoutKillGrace) {
        guard Self.isClosing else { return }
        Self.terminate([self], grace: grace)
    }

    /// Whether the child is running, for `terminateAllRunning`.
    private var isChildRunning: Bool {
        state.withLock { $0.process?.isRunning == true }
    }

    func setReadHandles(_ handles: [FileHandle]) {
        state.withLock { $0.readHandles = handles }
    }

    func clearReadHandlers() {
        let handles = state.withLock { $0.readHandles }
        for handle in handles { handle.readabilityHandler = nil }
    }

    /// Terminates the child after `seconds` unless it has exited by then, and kills it
    /// if it is still running `timeoutKillGrace` later. Arm it once the child is
    /// running, so a slow launch does not use up the allowance. The flag is set before
    /// terminate(), and only for a live child, so a child that exited on its own as the
    /// timer fired is not reported as timed out.
    func armTimeout(_ seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.state.withLock({ $0.disarmed }) else { return }
            // The flag is set, then the child stopped, in one critical section.
            let stopped = self.state.withLock { state -> Bool in
                guard let p = state.process, p.isRunning else { return false }
                state.timedOut = true
                p.terminate()
                return true
            }
            guard stopped else { return }
            let killAt = DispatchTime.now() + CLIBridge.timeoutKillGrace
            DispatchQueue.global().asyncAfter(deadline: killAt) { [weak self] in
                self?.killIfStillRunning()
            }
        }
    }

    func disarmTimeout() { state.withLock { $0.disarmed = true } }

    /// Checked under the lock and only while Foundation still reports the child running,
    /// so the pid of a child that has exited (and could be reused) is not signalled.
    private func killIfStillRunning() { signalIfRunning(SIGKILL) }

    private func signalIfRunning(_ signal: Int32) {
        state.withLock { state in
            guard let p = state.process, p.isRunning else { return }
            kill(p.processIdentifier, signal)
        }
    }

    // MARK: - Every child this process started

    private static let live = LiveBoxes()
    private static let closing = ClosingLatch()

    /// True once `terminateAllRunning` has run in this process: it is exiting, so no launch
    /// site may leave a child running (see `stopIfClosing`).
    static var isClosing: Bool { closing.value }

    /// Tests only: lets later tests start children after one exercised the exit path.
    static func reopen() { closing.set(false) }

    /// Terminates every child still running that a box here started (SIGTERM, then SIGKILL after
    /// `grace` for any that ignore it) and returns how many it signalled. Latches `isClosing`
    /// first, so a launch that follows the pass is stopped by its own site. For a process that is
    /// about to exit and must not leave jamf-cli running past it: exiting does not end a child.
    /// Blocks up to `grace`. Only a child Foundation reports running is signalled, so the pid of
    /// one that exited is never reused here.
    @discardableResult
    static func terminateAllRunning(grace: TimeInterval = CLIBridge.timeoutKillGrace) -> Int {
        closing.set(true)
        let running = live.boxes.filter(\.isChildRunning)
        terminate(running, grace: grace)
        return running.count
    }

    private static func terminate(_ boxes: [TimedProcessBox], grace: TimeInterval) {
        for box in boxes { box.signalIfRunning(SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while boxes.contains(where: \.isChildRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for box in boxes { box.killIfStillRunning() }
    }
}

private final class ClosingLatch: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set(_ new: Bool) { flag.withLock { $0 = new } }
}

/// Weak references to the boxes that hold a child, so a box that has finished is not kept alive.
private final class LiveBoxes: Sendable {
    private struct Weak { weak var box: TimedProcessBox? }
    private let entries = Mutex<[Weak]>([])

    func add(_ box: TimedProcessBox) {
        entries.withLock {
            $0.removeAll { $0.box == nil }
            $0.append(Weak(box: box))
        }
    }

    var boxes: [TimedProcessBox] { entries.withLock { $0.compactMap(\.box) } }
}
