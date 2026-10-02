import Foundation

/// The tick lock every GUI collect holds (#226 5c). `collect` takes it, so a `--tick` wake
/// during any GUI collect exits queued. The tick and the included CLI call
/// `CollectRouter.run` directly and never come through here, so the hold can neither block
/// their collects nor nest inside them.
extension CLIBridge {
    /// Injectable so tests never touch the real lock file.
    static var tickLock: @Sendable () -> TickLock = { TickLock(url: TickLock.defaultURL) }

    /// Holds this process has on `tickLock`. Overlapping collects share the file; the last
    /// one out removes it.
    private(set) static var tickLockHolds = 0

    /// Whether another live process holds `tickLock`. False for this process's own holds.
    static func tickLockHeldElsewhere() -> Bool {
        tickLock().isHeldByAnotherLiveProcess()
    }

    /// Runs `body` holding the tick lock, touching it every `beatEvery` for up to the tick's
    /// six hours. Throws `CLIBridgeError.tickLockHeld` without running `body` when another
    /// live process holds the lock.
    static func holdingTickLock<T: Sendable>(
        beatEvery interval: Duration = TickLock.heartbeatInterval,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let lock = tickLock()
        switch lock.claim() {
        case .heldElsewhere:
            AppLogger.event(
                .collect, .notice, "Collect refused: a scheduled run holds the tick lock")
            throw CLIBridgeError.tickLockHeld
        case .writeFailed:
            // `claim` logged why. A tick needs the same file, so none can start beside this.
            return try await body()
        case .acquired:
            tickLockHolds += 1
            let beats = lock.heartbeat(every: interval)
            defer {
                beats.cancel()
                tickLockHolds -= 1
                if tickLockHolds == 0 { lock.release() }
            }
            return try await body()
        }
    }
}
