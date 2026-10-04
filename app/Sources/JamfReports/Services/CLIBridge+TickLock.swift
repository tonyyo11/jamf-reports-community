import Foundation

/// The tick lock every GUI collect holds (#226 5c). `collect` takes it, so a `--tick` wake
/// during any GUI collect exits queued. The tick and the included CLI call
/// `CollectRouter.run` directly and never come through here, so the hold can neither block
/// their collects nor nest inside them.
///
/// One hold runs at a time in this process, whatever the profile: a second collect is
/// refused with `CLIBridgeError.collectInProgress` instead of fanning a second set of
/// jamf-cli calls out at the same server. A jamf-cli install or update holds the same lock
/// (`HoldPurpose.toolUpdate`), so neither starts while the other runs and the binary never
/// changes under a collect. Nothing nests today, so a hold started inside another is
/// refused too.
extension CLIBridge {
    /// What a hold is for. Decides which refusal the next caller gets.
    enum HoldPurpose: Sendable {
        case collect
        case toolUpdate

        var label: String {
            switch self {
            case .collect: "Collect"
            case .toolUpdate: "jamf-cli update"
            }
        }
    }

    /// Injectable so tests never touch the real lock file.
    static var tickLock: @Sendable () -> TickLock = { TickLock(url: TickLock.defaultURL) }

    /// What the running hold in this process is for, lock file or not; nil when none runs.
    private(set) static var holdPurpose: HoldPurpose?

    /// A collect is running inside `holdingTickLock`.
    static var collectRunning: Bool { holdPurpose == .collect }

    /// A jamf-cli install or update is running inside `holdingTickLock`.
    static var toolUpdateRunning: Bool { holdPurpose == .toolUpdate }

    /// That hold has the lock file, which it does not when the file cannot be written.
    private(set) static var holdsTickLock = false

    /// When the last hold ended.
    private(set) static var tickLockReleasedAt: Date?

    /// Whether another live process holds `tickLock`. False for this process's own hold.
    static func tickLockHeldElsewhere() -> Bool {
        tickLock().isHeldByAnotherLiveProcess()
    }

    /// Why a hold started now would be refused, or nil: the hold running here, else a live
    /// process holding the lock. `holdingTickLock`'s checks, asked without claiming, for a
    /// caller that must not record a run for a refusal.
    static func collectRefusal() -> CLIBridgeError? {
        runningHoldRefusal ?? (tickLockHeldElsewhere() ? .tickLockHeld : nil)
    }

    /// The refusal for the hold running in this process, nil when none runs.
    private static var runningHoldRefusal: CLIBridgeError? {
        switch holdPurpose {
        case .collect: .collectInProgress
        case .toolUpdate: .toolUpdateInProgress
        case nil: nil
        }
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
    /// six hours. Throws, without running `body`, `CLIBridgeError.collectInProgress` or
    /// `.toolUpdateInProgress` when another hold is running in this process, and
    /// `CLIBridgeError.tickLockHeld` when another live process holds the lock.
    static func holdingTickLock<T: Sendable>(
        purpose: HoldPurpose = .collect,
        beatEvery interval: Duration = TickLock.heartbeatInterval,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        // Checked and set with no suspension between, so two callers cannot both pass.
        if let running = runningHoldRefusal {
            AppLogger.event(
                .collect, .notice, "\(purpose.label) refused: \(running.localizedDescription)")
            throw running
        }
        let lock = tickLock()
        switch lock.claim() {
        case .heldElsewhere:
            AppLogger.event(
                .collect, .notice, "\(purpose.label) refused: a scheduled run holds the tick lock")
            throw CLIBridgeError.tickLockHeld
        case .writeFailed:
            // `claim` logged why. A tick needs the same file, so none can start beside this.
            holdPurpose = purpose
            defer { holdPurpose = nil }
            return try await body()
        case .acquired:
            holdPurpose = purpose
            holdsTickLock = true
            let beats = lock.heartbeat(every: interval)
            defer {
                beats.cancel()
                holdPurpose = nil
                holdsTickLock = false
                lock.release()
                tickLockReleasedAt = Date()
            }
            return try await body()
        }
    }
}
