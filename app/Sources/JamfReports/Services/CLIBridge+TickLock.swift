import Foundation

/// The tick lock every GUI collect holds (#226 5c). `collect` takes it, so a `--tick` wake
/// during any GUI collect exits queued. The tick and the included CLI call
/// `CollectRouter.run` directly and never come through here, so the hold can neither block
/// their collects nor nest inside them.
///
/// One collect runs at a time in this process, whatever the profile: a second one is refused
/// with `CLIBridgeError.collectInProgress` instead of fanning a second set of jamf-cli calls
/// out at the same server. Nothing nests today, so a hold started inside another is refused too.
extension CLIBridge {
    /// Injectable so tests never touch the real lock file.
    static var tickLock: @Sendable () -> TickLock = { TickLock(url: TickLock.defaultURL) }

    /// A collect is running inside `holdingTickLock`, lock file or not.
    private(set) static var collectRunning = false

    /// That collect holds the lock file, which it does not when the file cannot be written.
    private(set) static var holdsTickLock = false

    /// When the last hold ended.
    private(set) static var tickLockReleasedAt: Date?

    /// Whether another live process holds `tickLock`. False for this process's own hold.
    static func tickLockHeldElsewhere() -> Bool {
        tickLock().isHeldByAnotherLiveProcess()
    }

    /// Why a collect started now would be refused, or nil. `holdingTickLock`'s two checks,
    /// asked without claiming, for a caller that must not record a run for a refusal.
    static func collectRefusal() -> CLIBridgeError? {
        if collectRunning { return .collectInProgress }
        return tickLockHeldElsewhere() ? .tickLockHeld : nil
    }

    /// True while this process holds the lock, and for one tick wake plus a minute after its
    /// last hold ends: a wake the hold turned away runs only at the next interval, so the
    /// schedules it was blocking are still waiting until then.
    static func tickLockHeldRecently(now: Date = Date()) -> Bool {
        if holdsTickLock { return true }
        guard let released = tickLockReleasedAt else { return false }
        return now.timeIntervalSince(released) < TickLock.wakeInterval + 60
    }

    /// Runs `body` holding the tick lock, touching it every `beatEvery` for up to the tick's
    /// six hours. Throws `CLIBridgeError.collectInProgress` without running `body` when
    /// another collect is running in this process, and `CLIBridgeError.tickLockHeld` when
    /// another live process holds the lock.
    static func holdingTickLock<T: Sendable>(
        beatEvery interval: Duration = TickLock.heartbeatInterval,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        // Checked and set with no suspension between, so two callers cannot both pass.
        guard !collectRunning else {
            AppLogger.event(.collect, .notice, "Collect refused: a collect is already running")
            throw CLIBridgeError.collectInProgress
        }
        let lock = tickLock()
        switch lock.claim() {
        case .heldElsewhere:
            AppLogger.event(
                .collect, .notice, "Collect refused: a scheduled run holds the tick lock")
            throw CLIBridgeError.tickLockHeld
        case .writeFailed:
            // `claim` logged why. A tick needs the same file, so none can start beside this.
            collectRunning = true
            defer { collectRunning = false }
            return try await body()
        case .acquired:
            collectRunning = true
            holdsTickLock = true
            let beats = lock.heartbeat(every: interval)
            defer {
                beats.cancel()
                collectRunning = false
                holdsTickLock = false
                lock.release()
                tickLockReleasedAt = Date()
            }
            return try await body()
        }
    }
}
