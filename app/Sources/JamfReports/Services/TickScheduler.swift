import Foundation

/// Per-label "last started" / "last succeeded" stamps plus the retry count for
/// the current fire. Lives beside the schedule store, not in a workspace: the
/// recorder's status file has no start time, and a managed schedule's status
/// is one file per profile.
struct TickState: Codable, Sendable {
    static var defaultURL: URL { AppSupport.directory().appendingPathComponent("tick-state.json") }

    var lastStarted: [String: Date] = [:]
    var lastSucceeded: [String: Date] = [:]
    /// Retries run for the fire `lastStarted` belongs to; a new fire resets it.
    var retryCount: [String: Int] = [:]

    init() {}

    /// Lenient on purpose: a pre-retry `tick-state.json` carries only
    /// `lastStarted`, and dropping those stamps would re-run every schedule.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastStarted = try c.decodeIfPresent([String: Date].self, forKey: .lastStarted) ?? [:]
        lastSucceeded = try c.decodeIfPresent([String: Date].self, forKey: .lastSucceeded) ?? [:]
        retryCount = try c.decodeIfPresent([String: Int].self, forKey: .retryCount) ?? [:]
    }

    static func load(url: URL = TickState.defaultURL) -> TickState {
        guard let data = try? Data(contentsOf: url) else { return TickState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TickState.self, from: data)) ?? TickState()
    }

    func save(url: URL = TickState.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Stamp a start. A calendar fire restarts the retry count, a retry
    /// advances it, and a run-now leaves it alone — it belongs to no fire.
    mutating func noteStarted(_ label: String, at now: Date, reason: TickScheduler.Reason) {
        lastStarted[label] = now
        switch reason {
        case .fire: retryCount[label] = 0
        case .retry: retryCount[label] = (retryCount[label] ?? 0) + 1
        case .runNow: break
        }
    }

    /// Stamp a success at the run's START, so it compares against the fire
    /// the same way `lastStarted` does. Ends the retry sequence for that fire.
    mutating func noteSucceeded(_ label: String, startedAt: Date) {
        lastSucceeded[label] = startedAt
        retryCount[label] = 0
    }
}

/// A schedule run's exit code plus what the tick needs beyond it: whether a
/// collect came back incomplete, and whether a same-day retry could fetch what
/// is missing.
struct ScheduleRunOutcome: Sendable {
    let exitCode: Int32
    /// A source or the summary did not land; Run History shows the run as Partial.
    let incomplete: Bool
    /// False when everything missing failed in a way a retry repeats. Defaults to
    /// `incomplete`.
    let retryCouldHelp: Bool

    init(exitCode: Int32, incomplete: Bool, retryCouldHelp: Bool? = nil) {
        self.exitCode = exitCode
        self.incomplete = incomplete
        self.retryCouldHelp = retryCouldHelp ?? incomplete
    }

    /// Exit 0 with nothing left on the table.
    var succeeded: Bool { exitCode == 0 && !incomplete }

    /// Exit 0 with nothing a retry could fetch — the only outcome that ends retries.
    var endsRetries: Bool { exitCode == 0 && !retryCouldHelp }
}

/// Pure "what is due" decision. Input order is preserved so the caller
/// controls run order (managed kinds first, then hand-built by label).
enum TickScheduler {
    /// Modes that do NOT catch up (generate-from-cache, backup) only run when
    /// the missed fire is this recent — matches their old `RunAtLoad: false`.
    static let nonCatchUpWindow: TimeInterval = 15 * 60

    /// Waits before each same-day retry of a collect that failed or came back
    /// incomplete; after the last one, the next calendar fire. Spaced so the
    /// tick alone never re-polls an on-prem server inside an hour.
    static let retryBackoffs: [TimeInterval] = [1 * 3600, 2 * 3600, 4 * 3600]

    /// Why a run is due — the tick stamps each differently (`TickState.noteStarted`).
    enum Reason: Sendable, Equatable { case runNow, fire, retry }

    struct DueRun: Sendable {
        let schedule: Schedule
        let reason: Reason
    }

    /// - Parameter nonCatchUpAnchor: When a wake was turned away by the lock,
    ///   the time of the FIRST such refusal. The non-catch-up window is measured
    ///   from the earlier of it and `now`, so a 40-minute collect that blocks
    ///   three wakes cannot swallow the 07:00 backup that came due while it ran.
    ///   `nil` (the default) measures from `now`, the plain uncontended case.
    static func due(
        schedules: [Schedule],
        state: TickState,
        runNowLabels: Set<String>,
        now: Date,
        nonCatchUpAnchor: Date? = nil
    ) -> [DueRun] {
        let anchor = min(nonCatchUpAnchor ?? now, now)
        return schedules.compactMap { schedule -> DueRun? in
            guard let label = schedule.launchAgentLabel else { return nil }
            if runNowLabels.contains(label) { return DueRun(schedule: schedule, reason: .runNow) }
            guard schedule.enabled else { return nil }
            guard let entries = try? LaunchAgentWriter.calendarIntervals(for: schedule.schedule),
                  let fire = LaunchAgentService.lastScheduledFireDate(from: entries, before: now)
            else {
                AppLogger.schedule.warning(
                    "tick: \(label, privacy: .public) has an unreadable cadence and was skipped")
                return nil
            }
            let started = state.lastStarted[label] ?? .distantPast
            if fire > started {
                let catchesUp = schedule.mode.runsAtLoad
                    || anchor.timeIntervalSince(fire) <= nonCatchUpWindow
                return catchesUp ? DueRun(schedule: schedule, reason: .fire) : nil
            }
            let retry = retryIsDue(
                mode: schedule.mode, label: label, fire: fire, state: state, now: now)
            return retry ? DueRun(schedule: schedule, reason: .retry) : nil
        }
    }

    /// Same-day retry of a run that started for `fire` but never succeeded:
    /// collect modes only, at most `retryBackoffs.count` per fire, each one its
    /// backoff after the previous start. Only reached once the fire has started.
    private static func retryIsDue(
        mode: Schedule.RunMode, label: String, fire: Date, state: TickState, now: Date
    ) -> Bool {
        guard mode.runsAtLoad else { return false }
        guard (state.lastSucceeded[label] ?? .distantPast) < fire else { return false }
        let retries = state.retryCount[label] ?? 0
        guard retryBackoffs.indices.contains(retries) else { return false }
        let started = state.lastStarted[label] ?? .distantPast
        return now.timeIntervalSince(started) >= retryBackoffs[retries]
    }
}

/// One tick at a time. A pid file: a live holder blocks, a dead or garbage
/// holder is taken over — the 300-second wake must never pile a second run
/// on top of a 20-minute collect. The GUI holds it for every collect too
/// (`CLIBridge.holdingTickLock`), so a wake during one queues.
struct TickLock: Sendable {
    static var defaultURL: URL { AppSupport.directory().appendingPathComponent(".tick.lock") }

    /// Where the first blocked wake stamps itself, so the run that eventually
    /// gets in knows how long the queue has been waiting.
    static var defaultBlockedURL: URL {
        AppSupport.directory().appendingPathComponent(".tick.blocked")
    }

    /// A lock older than this is taken over even when its pid still looks
    /// alive. Pids are recycled and a run can wedge on a hung network call;
    /// without an upper bound either one silences the ticker permanently.
    static let staleAfter: TimeInterval = 3600

    /// How often a running tick re-touches the lock — well inside `staleAfter`,
    /// so a wake landing between two beats still sees a fresh lock.
    static let heartbeatInterval: Duration = .seconds(300)

    /// No real run lasts this long; past it the lock is left to go stale.
    static let heartbeatLimit: Duration = .seconds(6 * 3600)

    /// The bundled agent's `StartInterval`: a wake the lock turned away runs this long later.
    static let wakeInterval: TimeInterval = 300

    let url: URL

    /// What `claim` found.
    enum Claim: Sendable, Equatable {
        /// The file names `pid`.
        case acquired
        /// A live, fresh holder other than `pid`; the file is untouched.
        case heldElsewhere
        /// The file could not be written and `pid` holds nothing.
        case writeFailed
    }

    /// The test `acquire()` refuses on: the file names a live pid other than
    /// `pid` and is not stale. Read-only — never writes or touches the lock.
    /// A pid of 1 or below is no holder: `kill(0, 0)` and `kill(-1, 0)` signal whole process
    /// groups and succeed, and pid 1 is launchd, so a lock file naming one would read as alive
    /// until its date went stale.
    func isHeldByAnotherLiveProcess(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> Bool {
        guard let holder = holder(), holder > 1 else { return false }
        return holder != pid && isAlive(holder) && !isStale()
    }

    func acquire(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> Bool {
        claim(pid: pid, isAlive: isAlive) == .acquired
    }

    /// `acquire` with the reason a caller that degrades on a write failure needs. Decided
    /// from one read of the holder, so a holder letting go mid-call cannot read as a failure.
    func claim(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        protect: (URL) throws -> Void = {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: $0.path)
        }
    ) -> Claim {
        if isHeldByAnotherLiveProcess(pid: pid, isAlive: isAlive) { return .heldElsewhere }
        do {
            try Data(String(pid).utf8).write(to: url, options: .atomic)
        } catch {
            AppLogger.schedule.error(
                "tick lock could not be written: \(error.localizedDescription, privacy: .public)")
            // A hold this process already had stands; only the rewrite failed.
            return holder() == pid ? .acquired : .writeFailed
        }
        do {
            try protect(url)
        } catch {
            // The file names `pid` now: reporting a failure would leave it unreleased.
            AppLogger.schedule.warning(
                "tick lock permissions not set: \(error.localizedDescription, privacy: .public)")
        }
        return .acquired
    }

    /// Only removes the file if it still names OUR pid — a takeover by
    /// another process must not have its lock deleted out from under it.
    func release(pid: Int32 = getpid()) {
        guard holder() == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The pid the file names; nil when there is no file or it holds no pid.
    private func holder() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Resets the lock file's mtime so a long-running holder never crosses
    /// `staleAfter` and gets taken over mid-run. Best-effort.
    func touch(now: Date = Date()) {
        try? FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: url.path)
    }

    /// Runs `body` while touching the lock every `interval` so a long run is not taken over;
    /// beats stop after `limit`, so a wedged run still goes stale. Stopped before returning.
    func keepingAlive<T: Sendable>(
        every interval: Duration = TickLock.heartbeatInterval,
        limit: Duration = TickLock.heartbeatLimit,
        _ body: () async -> T
    ) async -> T {
        let beats = heartbeat(every: interval, limit: limit)
        let result = await body()
        beats.cancel()
        await beats.value
        return result
    }

    /// The line a run turned away by `holdingForRun` prints, after its own prefix.
    static let busyMessage =
        "another collect, report or scheduled run is in progress — try again when it finishes"

    /// Runs `body` holding this lock, kept fresh while it runs, for a process other than the
    /// tick that collects or writes a report (`--scheduled-run` from an external scheduler, the
    /// included CLI): it cannot overlap a GUI collect or report, a tick or another such process.
    /// Nil, without running `body`, when another live process holds the lock. A lock file that
    /// cannot be written runs `body` without it, as a GUI collect does: refusing would turn a
    /// broken Application Support into a dead command, and a tick needs the same file.
    func holdingForRun<T: Sendable>(
        beatEvery interval: Duration = TickLock.heartbeatInterval,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T? {
        switch claim() {
        case .heldElsewhere:
            return nil
        case .writeFailed:
            return try await body()
        case .acquired:
            let beats = heartbeat(every: interval)
            defer {
                beats.cancel()
                release()
            }
            return try await body()
        }
    }

    /// `keepingAlive`'s beats, for a holder whose body runs on the main actor and so
    /// cannot be handed over: touches the lock every `interval` until cancelled or `limit`.
    func heartbeat(
        every interval: Duration = TickLock.heartbeatInterval,
        limit: Duration = TickLock.heartbeatLimit
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: limit)
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, clock.now < deadline else { return }
                touch()
            }
        }
    }

    /// Unreadable attributes fail toward "not stale" — keep blocking rather
    /// than run a second collect on a guess.
    private func isStale(now: Date = Date()) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) > Self.staleAfter
    }

    /// Record that a wake was turned away, once — the FIRST refusal is the one
    /// the non-catch-up window should be measured from, so an existing stamp is
    /// never overwritten by a later blocked wake.
    static func noteBlocked(url: URL = defaultBlockedURL, now: Date = Date()) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = ISO8601DateFormatter().string(from: now)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Read and clear the stamp; nil when no wake was blocked since the last
    /// successful tick.
    static func takeBlockedSince(url: URL = defaultBlockedURL) -> Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return ISO8601DateFormatter()
            .date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
