import Foundation

/// Locked process box for task cancellation and the timeout: terminates the child after a
/// deadline (SIGTERM, then SIGKILL after `CLIBridge.timeoutKillGrace`). Shared by
/// `CLIBridge.runAndCapture` and `JamfCLIProbe`.
final class TimedProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var readHandles: [FileHandle] = []
    private var timeoutItem: DispatchWorkItem?
    private var timedOut = false
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func set(_ p: Process) {
        lock.lock(); process = p; lock.unlock()
        Self.live.add(self)
    }
    func terminate() { lock.lock(); let p = process; lock.unlock(); p?.terminate() }

    /// Whether the child is running, for `terminateAllRunning`.
    private var isChildRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    func setReadHandles(_ handles: [FileHandle]) {
        lock.lock(); readHandles = handles; lock.unlock()
    }

    func clearReadHandlers() {
        lock.lock(); let handles = readHandles; lock.unlock()
        for handle in handles { handle.readabilityHandler = nil }
    }

    /// Terminates the child after `seconds` unless it has exited by then, and kills it
    /// if it is still running `timeoutKillGrace` later. Arm it once the child is
    /// running, so a slow launch does not use up the allowance. The flag is set before
    /// terminate(), and only for a live child, so a child that exited on its own as the
    /// timer fired is not reported as timed out.
    func armTimeout(_ seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let p = self.process, p.isRunning else { self.lock.unlock(); return }
            self.timedOut = true
            self.lock.unlock()
            p.terminate()
            let killAt = DispatchTime.now() + CLIBridge.timeoutKillGrace
            DispatchQueue.global().asyncAfter(deadline: killAt) { [weak self] in
                self?.killIfStillRunning()
            }
        }
        lock.lock(); timeoutItem = item; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func disarmTimeout() { lock.lock(); let i = timeoutItem; lock.unlock(); i?.cancel() }

    /// Checked under the lock and only while Foundation still reports the child running,
    /// so the pid of a child that has exited (and could be reused) is not signalled.
    private func killIfStillRunning() {
        lock.lock(); defer { lock.unlock() }
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
    }

    // MARK: - Every child this process started

    private static let live = LiveBoxes()

    /// Terminates every child still running that a box here started (SIGTERM, then SIGKILL after
    /// `grace` for any that ignore it) and returns how many it signalled. For a process that is
    /// about to exit and must not leave jamf-cli running past it: exiting does not end a child.
    /// Blocks up to `grace`. Only a child Foundation reports running is signalled, so the pid of
    /// one that exited is never reused here.
    @discardableResult
    static func terminateAllRunning(grace: TimeInterval = CLIBridge.timeoutKillGrace) -> Int {
        let running = live.boxes.filter(\.isChildRunning)
        for box in running { box.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while running.contains(where: \.isChildRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for box in running { box.killIfStillRunning() }
        return running.count
    }
}

/// Weak references to the boxes that hold a child, so a box that has finished is not kept alive.
private final class LiveBoxes: @unchecked Sendable {
    private struct Weak { weak var box: TimedProcessBox? }
    private let lock = NSLock()
    private var entries: [Weak] = []

    func add(_ box: TimedProcessBox) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.box == nil }
        entries.append(Weak(box: box))
    }

    var boxes: [TimedProcessBox] {
        lock.lock(); defer { lock.unlock() }
        return entries.compactMap(\.box)
    }
}
