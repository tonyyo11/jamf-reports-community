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

/// An acquired tick lock: the open descriptor holding the kernel's exclusive `flock` on the
/// lock file. The kernel drops the lock when the descriptor closes or the process dies, so a
/// holder that exits, crashes or is killed never leaves a lock behind.
final class TickLockHold: @unchecked Sendable {
    private let state = NSLock()
    private var fd: Int32

    fileprivate init(fd: Int32) { self.fd = fd }

    deinit { release() }

    /// Names no holder, then closes the descriptor, which frees the lock. Idempotent. The
    /// file stays: unlinking it would let a claimer holding the old inode and one creating a
    /// new file both think they hold the lock.
    func release() {
        state.lock()
        defer { state.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        close(fd)
        fd = -1
    }

    /// Resets the lock file's mtime, which the read-only probe judges staleness by. Best-effort.
    func touch(now: Date = Date()) {
        state.lock()
        defer { state.unlock() }
        guard fd >= 0 else { return }
        let seconds = now.timeIntervalSince1970
        let stamp = timespec(
            tv_sec: Int(seconds), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1e9))
        var times = [stamp, stamp]
        _ = futimens(fd, &times)
    }

    /// Runs `body` while touching the lock every `interval`; beats stop after `limit`, which
    /// releases the lock (see `heartbeat`). Stopped before returning.
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

    /// `keepingAlive`'s beats, for a holder whose body runs on the main actor and so cannot
    /// be handed over: touches the lock every `interval` until cancelled. At `limit` it gives
    /// up the lock instead: no real run lasts that long, and a wedged live holder must not
    /// silence the ticker for good.
    func heartbeat(
        every interval: Duration = TickLock.heartbeatInterval,
        limit: Duration = TickLock.heartbeatLimit
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: limit)
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard clock.now < deadline else {
                    AppLogger.schedule.warning("tick lock given up: the run passed its time limit")
                    release()
                    return
                }
                touch()
            }
        }
    }
}

/// One tick at a time. The holder takes an exclusive `flock` on the lock file and keeps the
/// descriptor open for the whole hold, so two claimers can never both win and the kernel frees
/// the lock when the holder dies (a Mac that slept mid-run keeps its lock on wake). The GUI
/// holds it for every collect too (`CLIBridge.holdingTickLock`), so a wake during one queues.
///
/// The holder's pid is written into the file only so the read-only probe
/// (`isHeldByAnotherLiveProcess`) can answer without acquiring: `flock` has no test that does
/// not take the lock, and a probe that took and dropped it could fail a real claim.
struct TickLock: Sendable {
    static var defaultURL: URL { AppSupport.directory().appendingPathComponent(".tick.lock") }

    /// Where the first blocked wake stamps itself, so the run that eventually
    /// gets in knows how long the queue has been waiting.
    static var defaultBlockedURL: URL {
        AppSupport.directory().appendingPathComponent(".tick.blocked")
    }

    /// The probe's "assume stale" age for a file whose holder stopped touching it. The kernel
    /// lock, not this, decides `claim`; a holder that goes quiet this long is probably wedged.
    static let staleAfter: TimeInterval = 3600

    /// How often a running tick re-touches the lock — well inside `staleAfter`,
    /// so a probe landing between two beats still sees a fresh lock.
    static let heartbeatInterval: Duration = .seconds(300)

    /// No real run lasts this long; past it the heartbeat gives the lock up.
    static let heartbeatLimit: Duration = .seconds(6 * 3600)

    /// The bundled agent's `StartInterval`: a wake the lock turned away runs this long later.
    static let wakeInterval: TimeInterval = 300

    let url: URL

    /// What `claim` found.
    enum Claim: Sendable {
        /// This caller holds the lock until `release()`; the file names `pid`.
        case acquired(TickLockHold)
        /// Another descriptor holds the kernel lock; the file is untouched.
        case heldElsewhere
        /// The file could not be opened or written and nothing is held.
        case writeFailed
    }

    /// The probe: the file names a live pid other than `pid` and is not stale. Read-only —
    /// never writes, touches or locks. A pid of 1 or below is no holder: `kill(0, 0)` and
    /// `kill(-1, 0)` signal whole process groups and succeed, and pid 1 is launchd, so a lock
    /// file naming one would read as alive until its date went stale.
    func isHeldByAnotherLiveProcess(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> Bool {
        guard let holder = holder(), holder > 1 else { return false }
        return holder != pid && isAlive(holder) && !isStale()
    }

    /// Takes the kernel lock and records `pid` in the file. Never follows a symlink at `url`.
    /// `protect` sets the file's mode; its failure is logged, not fatal, since the pid is
    /// already on disk and the hold must be released.
    func claim(
        pid: Int32 = getpid(),
        protect: (Int32) throws -> Void = {
            guard fchmod($0, 0o600) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    ) -> Claim {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return failed("opened", errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(fd)
            return reason == EWOULDBLOCK ? .heldElsewhere : failed("locked", reason)
        }
        // Written before the length is set, so a probe never reads an empty file in between.
        let bytes = Array(String(pid).utf8)
        guard pwrite(fd, bytes, bytes.count, 0) == bytes.count,
              ftruncate(fd, off_t(bytes.count)) == 0
        else {
            let reason = errno
            close(fd)
            return failed("written", reason)
        }
        do {
            try protect(fd)
        } catch {
            AppLogger.schedule.warning(
                "tick lock permissions not set: \(error.localizedDescription, privacy: .public)")
        }
        return .acquired(TickLockHold(fd: fd))
    }

    private func failed(_ what: String, _ code: Int32) -> Claim {
        let reason = String(cString: strerror(code))
        AppLogger.schedule.error(
            "tick lock could not be \(what, privacy: .public): \(reason, privacy: .public)")
        return .writeFailed
    }

    /// The pid the file names; nil when there is no file or it holds no pid.
    private func holder() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
        case .acquired(let hold):
            let beats = hold.heartbeat(every: interval)
            defer {
                beats.cancel()
                hold.release()
            }
            return try await body()
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
