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
/// changes under a collect. A report run holds it too (`holdingGenerate`), so no collect
/// replaces snapshots under a report being built. Holds do not nest: one started inside
/// another is refused, except the collect a report run asks for itself.
extension CLIBridge {
    /// What a hold is for. Decides which refusal the next caller gets.
    enum HoldPurpose: Sendable {
        case collect
        case generate
        case toolUpdate

        var label: String {
            switch self {
            case .collect: "Collect"
            case .generate: "Report"
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

    /// Counts holds taken, so `generateHoldID` can name the one a task belongs to.
    private(set) static var holdSerial = 0

    /// The report hold the running task is inside, which lets the collect that run asks for
    /// through. Task-local, so a collect started from anywhere else is still refused.
    @TaskLocal private static var generateHoldID: Int?

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
        case .generate: .generateInProgress
        case .toolUpdate: .toolUpdateInProgress
        case nil: nil
        }
    }

    /// The task is inside the report hold that is running now, not one that ended.
    private static var isInsideRunningGenerateHold: Bool {
        holdPurpose == .generate && generateHoldID == holdSerial
    }

    /// True while this process holds the lock, and for one tick wake plus a minute after its
    /// last hold ends: a wake the hold turned away runs only at the next interval, so the
    /// schedules it was blocking are still waiting until then.
    static func tickLockHeldRecently(now: Date = Date()) -> Bool {
        if holdsTickLock { return true }
        guard let released = tickLockReleasedAt else { return false }
        return now.timeIntervalSince(released) < TickLock.wakeInterval + 60
    }

    /// What `beginHold` took, for `endHold`.
    private struct Hold {
        let id: Int
        /// Nil when the lock file could not be written: the hold still keeps the app's own
        /// collects apart.
        let claimed: (hold: TickLockHold, beats: Task<Void, Never>)?
    }

    /// Checked and set with no suspension between, so two callers cannot both pass.
    private static func beginHold(
        purpose: HoldPurpose, beatEvery interval: Duration
    ) throws -> Hold {
        if let running = runningHoldRefusal {
            AppLogger.event(
                .collect, .notice, "\(purpose.label) refused: \(running.localizedDescription)")
            throw running
        }
        let lock = tickLock()
        let claimed: (hold: TickLockHold, beats: Task<Void, Never>)?
        switch lock.claim() {
        case .heldElsewhere:
            AppLogger.event(
                .collect, .notice, "\(purpose.label) refused: a scheduled run holds the tick lock")
            throw CLIBridgeError.tickLockHeld
        case .writeFailed:
            // `claim` logged why. A tick needs the same file, so none can start beside this.
            claimed = nil
        case .acquired(let held):
            holdsTickLock = true
            claimed = (held, held.heartbeat(every: interval))
        }
        holdPurpose = purpose
        holdSerial += 1
        return Hold(id: holdSerial, claimed: claimed)
    }

    private static func endHold(_ hold: Hold) {
        holdPurpose = nil
        guard let claimed = hold.claimed else { return }
        claimed.beats.cancel()
        holdsTickLock = false
        claimed.hold.release()
        tickLockReleasedAt = Date()
    }

    /// Runs `body` holding the tick lock (a kernel `flock` this process keeps open, so a sleep
    /// or a crash never leaves it stale), touching it every `beatEvery` and giving it up after
    /// the tick's six hours. Throws, without running `body`,
    /// `CLIBridgeError.collectInProgress`, `.generateInProgress` or `.toolUpdateInProgress`
    /// when another hold is running in this process, and `CLIBridgeError.tickLockHeld` when
    /// another live process holds the lock. A collect inside `holdingGenerate` runs under that
    /// hold instead.
    static func holdingTickLock<T: Sendable>(
        purpose: HoldPurpose = .collect,
        beatEvery interval: Duration = TickLock.heartbeatInterval,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        if purpose == .collect, isInsideRunningGenerateHold { return try await body() }
        let hold = try beginHold(purpose: purpose, beatEvery: interval)
        defer { endHold(hold) }
        return try await body()
    }

    /// Runs `body`, a report run (the collect it asks for, the narrative and every format),
    /// holding the tick lock throughout, so a collect, a tick or a second report never
    /// replaces snapshots or summary.json under it. One hold for the whole run: it is never
    /// released between the collect and the report. Throws as `holdingTickLock` does.
    static func holdingGenerate<T>(_ body: () async throws -> T) async throws -> T {
        let hold = try beginHold(purpose: .generate, beatEvery: TickLock.heartbeatInterval)
        defer { endHold(hold) }
        return try await $generateHoldID.withValue(hold.id, operation: body)
    }
}
