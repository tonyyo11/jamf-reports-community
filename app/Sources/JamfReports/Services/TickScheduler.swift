import Foundation
import Synchronization

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
    /// When the previous wake that took the lock ran. A long gap before the next wake means the
    /// Mac was off or asleep, which lets a daily schedule run on the first wake of a day.
    var lastTick: Date?
    /// Labels whose last run failed in a way a retry repeats (`ScheduleRunOutcome.retryCouldHelp`
    /// false): the hourly retries after the backoffs skip them.
    var retryWouldRepeat: Set<String> = []
    /// How each profile of a multi-profile schedule ended in the current fire's runs. A same-day
    /// retry leaves out the profiles whose entry says a retry would fetch nothing. Per Mac, like
    /// the retry count: a peer's run says nothing about what this Mac's collect fetched.
    var profileOutcomes: [String: [ProfileOutcome]] = [:]

    init() {}

    /// Lenient on purpose: a pre-retry `tick-state.json` carries only
    /// `lastStarted`, and dropping those stamps would re-run every schedule. Keys a later build
    /// dropped (`catchUpStarted`) are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastStarted = try c.decodeIfPresent([String: Date].self, forKey: .lastStarted) ?? [:]
        lastSucceeded = try c.decodeIfPresent([String: Date].self, forKey: .lastSucceeded) ?? [:]
        retryCount = try c.decodeIfPresent([String: Int].self, forKey: .retryCount) ?? [:]
        lastTick = try c.decodeIfPresent(Date.self, forKey: .lastTick)
        retryWouldRepeat = try c.decodeIfPresent(Set<String>.self, forKey: .retryWouldRepeat) ?? []
        // An unreadable entry reads as no outcome (the retry runs every profile); it must not
        // cost the stamps above, which would re-run every schedule.
        profileOutcomes = (try? c.decodeIfPresent(
            [String: [ProfileOutcome]].self, forKey: .profileOutcomes)) ?? [:]
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

    /// Stamp a scheduled start, which pays its local day. A fire or a catch-up restarts the retry
    /// count, a retry advances it. A Run now writes nothing: it pays no day and ends no retries.
    mutating func noteStarted(_ label: String, at now: Date, reason: TickScheduler.Reason) {
        switch reason {
        case .fire, .catchUp:
            lastStarted[label] = now
            retryCount[label] = 0
            // Yesterday's outcomes must not decide today's retry if this run dies mid-way.
            profileOutcomes[label] = nil
        case .retry:
            lastStarted[label] = now
            retryCount[label] = (retryCount[label] ?? 0) + 1
        case .runNow: break
        }
    }

    /// Stamp a success at the run's START, so it compares against the fire
    /// the same way `lastStarted` does. Ends the retry sequence for that fire.
    mutating func noteSucceeded(_ label: String, startedAt: Date) {
        lastSucceeded[label] = startedAt
        retryCount[label] = 0
        retryWouldRepeat.remove(label)
    }

    /// Records whether a retry of a run that did not end its retries could help. True when that
    /// changed the state.
    mutating func noteRetry(_ label: String, couldHelp: Bool) -> Bool {
        couldHelp ? retryWouldRepeat.remove(label) != nil : retryWouldRepeat.insert(label).inserted
    }
}

/// How one profile of a multi-profile run ended, as `retryCouldHelp(profile:exitCode:since:)`
/// judged it. Stored in `tick-state.json` as `profiles` under the schedule's label.
struct ProfileOutcome: Codable, Sendable, Equatable {
    let profile: String
    let exitCode: Int32
    let incomplete: Bool
    let retryCouldHelp: Bool
    let started: Date
    let finished: Date

    private enum CodingKeys: String, CodingKey {
        case profile, incomplete, started, finished
        case exitCode = "exit"
        case retryCouldHelp = "retry_could_help"
    }
}

extension ProfileOutcome {
    /// Exit 0 and complete: nothing to fetch and nothing standing.
    var isClean: Bool { exitCode == 0 && !incomplete }
}

extension TickState {
    /// Folds a run's per-profile outcomes into the label's: a profile that ran replaces its
    /// entry, one that did not keeps it, and one outside `considered` (removed, excluded or
    /// skipped for a missing jamf-cli profile) loses it, since nothing would ever refresh it.
    /// A Run now writes nothing, as for the other stamps. True when the stored outcomes changed.
    mutating func noteProfileOutcomes(
        _ label: String, _ ran: [ProfileOutcome], considered: Set<String>?,
        reason: TickScheduler.Reason
    ) -> Bool {
        guard reason != .runNow else { return false }
        let before = profileOutcomes[label]
        let ranNames = Set(ran.map(\.profile))
        let kept = (before ?? []).filter {
            !ranNames.contains($0.profile) && (considered?.contains($0.profile) ?? true)
        }
        let merged = kept + ran
        profileOutcomes[label] = merged.isEmpty ? nil : merged
        return profileOutcomes[label] != before
    }

    /// Profiles a retry leaves alone: with any profile whose failure a retry could fetch, all
    /// the others; with none, the clean ones, so the backoffs still retry a failure that
    /// repeats; nothing left out when no outcome is recorded or every profile is clean. A
    /// profile with no outcome is never here: not knowing fails toward collecting.
    func profilesNotNeedingRetry(_ label: String) -> Set<String> {
        let all = profileOutcomes[label] ?? []
        let helped = all.filter(\.retryCouldHelp)
        let wanted = helped.isEmpty ? all.filter { !$0.isClean } : helped
        guard !wanted.isEmpty else { return [] }
        return Set(all.map(\.profile)).subtracting(wanted.map(\.profile))
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
    /// The profiles of a multi-profile run that ran, in run order; empty for a single-profile
    /// schedule and for a run that skipped them all.
    let profiles: [ProfileOutcome]
    /// Every profile this run answers for (those it ran and those it left out), when it is a
    /// multi-profile run; nil for a single-profile schedule. Outcomes of any other profile are
    /// stale.
    let considered: Set<String>?

    init(
        exitCode: Int32, incomplete: Bool, retryCouldHelp: Bool? = nil,
        profiles: [ProfileOutcome] = [], considered: Set<String>? = nil
    ) {
        self.exitCode = exitCode
        self.incomplete = incomplete
        self.retryCouldHelp = retryCouldHelp ?? incomplete
        self.profiles = profiles
        self.considered = considered
    }

    /// The schedule's outcome over every profile's latest (`all`), of which this run's
    /// `ran` are the newest: a retry that ran two of three profiles still judges all three.
    init(over all: [ProfileOutcome], ran: [ProfileOutcome], considered: Set<String>? = nil) {
        self.init(
            exitCode: all.contains { $0.exitCode != 0 } ? 1 : 0,
            incomplete: all.contains(where: \.incomplete),
            retryCouldHelp: all.contains(where: \.retryCouldHelp), profiles: ran,
            considered: considered)
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

    /// Wait between retries once `retryBackoffs` are spent, while today's summary is missing.
    static let missingSummaryRetryInterval: TimeInterval = 3600

    /// A longer gap between two wakes than this (the agent wakes every 300 s) means the Mac was
    /// off or asleep.
    static let offGap: TimeInterval = 15 * 60

    /// Why a run is due — the tick stamps each differently (`TickState.noteStarted`). A
    /// `catchUp` is a daily schedule's run on the first wake after the Mac was off, for a day
    /// whose fire it may be off for again; it is stamped as a `fire`.
    enum Reason: Sendable, Equatable { case runNow, fire, catchUp, retry }

    struct DueRun: Sendable {
        let schedule: Schedule
        let reason: Reason
        /// Profiles a multi-profile retry leaves alone: their last run left nothing a retry
        /// could fetch. Empty for every other reason, so a fire or Run now runs them all.
        var skipProfiles: Set<String> = []
    }

    /// The profiles a multi-profile run covers: `profiles` less `skip`, or all of them when
    /// that leaves none (a profile left in the outcomes has since gone).
    static func profilesToRun(_ profiles: [String], skipping skip: Set<String>) -> [String] {
        let remaining = profiles.filter { !skip.contains($0) }
        return remaining.isEmpty ? profiles : remaining
    }

    /// Runs `run` for each of `names` that `profilesToRun` keeps, in order, and says which it
    /// left out through `onLine`. `run` returns nil for a profile that cannot run (no jamf-cli
    /// profile); that profile is not `considered`, so its old outcome goes.
    static func runProfiles(
        names: [String], skipping skip: Set<String>,
        onLine: (String) -> Void = { fputs($0 + "\n", stderr) },
        run: (String) async -> ProfileOutcome?
    ) async -> (ran: [ProfileOutcome], considered: Set<String>) {
        let toRun = TickScheduler.profilesToRun(names, skipping: skip)
        let leftOut = names.filter { !toRun.contains($0) }
        if !leftOut.isEmpty {
            onLine("[info] retrying only profiles that need it; leaving out: "
                   + leftOut.joined(separator: ", "))
        }
        var ran: [ProfileOutcome] = []
        for name in toRun {
            if let outcome = await run(name) { ran.append(outcome) }
        }
        return (ran, Set(leftOut).union(ran.map(\.profile)))
    }

    /// - Parameter summaryMissingToday: Whether `schedule` should have produced today's daily
    ///   summary and none exists. Asked only once the backoffs are spent: a collect that has not
    ///   produced it keeps retrying hourly until local midnight (a laptop off the VPN until
    ///   14:00 still gets its day). The default says it exists, so retries stop after the
    ///   backoffs.
    /// - Parameter nonCatchUpAnchor: When a wake was turned away by the lock, the time of the
    ///   FIRST such refusal since the Mac was last off (`nonCatchUpAnchor(refusals:now:)`).
    ///   The non-catch-up window is measured
    ///   from the earlier of it and `now`, so a 40-minute collect that blocks
    ///   three wakes cannot swallow the 07:00 backup that came due while it ran.
    ///   `nil` (the default) measures from `now`, the plain uncontended case.
    /// - Parameter wasOff: This wake is the first after the Mac was off or asleep (`wasOff(...)`).
    ///
    /// A daily collect pays a local day when a scheduled run starts on it, and is due while
    /// today is unpaid and either its latest fire's day is unpaid or the Mac was off: a Mac on
    /// 08:00-17:00 runs its 18:00 schedule at 08:00, an always-on Mac waits for 18:00. Every
    /// other schedule is due when its latest fire is later than its last start. A Run now
    /// marker runs the schedule's own due reason when it has one, else as `runNow`.
    static func due(
        schedules: [Schedule],
        state: TickState,
        runNowLabels: Set<String>,
        now: Date,
        nonCatchUpAnchor: Date? = nil,
        wasOff: Bool = false,
        summaryMissingToday: (Schedule) -> Bool = { _ in false }
    ) -> [DueRun] {
        let anchor = min(nonCatchUpAnchor ?? now, now)
        return schedules.compactMap { schedule -> DueRun? in
            guard let label = schedule.launchAgentLabel else { return nil }
            // A disabled schedule's marker still runs.
            let runNow = runNowLabels.contains(label) ? DueRun(schedule: schedule, reason: .runNow)
                : nil
            guard schedule.enabled else { return runNow }
            guard let entries = try? LaunchAgentWriter.calendarIntervals(for: schedule.schedule),
                  let fire = LaunchAgentService.lastScheduledFireDate(from: entries, before: now)
            else {
                AppLogger.schedule.warning(
                    "tick: \(label, privacy: .private) has an unreadable cadence and was skipped")
                return runNow
            }
            let daily = schedule.mode.runsAtLoad && isDaily(entries)
            if let reason = scheduledReason(
                fire: fire, started: startStamp(state.lastStarted[label], now: now),
                daily: daily, wasOff: wasOff, now: now),
               schedule.mode.runsAtLoad || anchor.timeIntervalSince(fire) <= nonCatchUpWindow {
                return DueRun(schedule: schedule, reason: reason)
            }
            let retry = retryIsDue(
                mode: schedule.mode, label: label, daily: daily, state: state, now: now,
                summaryMissing: { summaryMissingToday(schedule) })
            guard retry else { return runNow }
            // A Run now marker on a retry-due label still runs every profile.
            return DueRun(
                schedule: schedule, reason: .retry,
                skipProfiles: runNow == nil ? state.profilesNotNeedingRetry(label) : [])
        }
    }

    /// `.fire` when the latest fire is unpaid, `.catchUp` when only the off gap makes a daily
    /// schedule due, nil when neither.
    private static func scheduledReason(
        fire: Date, started: Date, daily: Bool, wasOff: Bool, now: Date
    ) -> Reason? {
        guard daily else { return fire > started ? .fire : nil }
        let calendar = Calendar.current
        let paid = started == .distantPast ? .distantPast : calendar.startOfDay(for: started)
        guard paid < calendar.startOfDay(for: now) else { return nil }
        if calendar.startOfDay(for: fire) > paid { return .fire }
        return wasOff ? .catchUp : nil
    }

    /// One fire a day: no weekday or day-of-month in any entry.
    private static func isDaily(_ entries: [[String: Int]]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { $0["Weekday"] == nil && $0["Day"] == nil }
    }

    /// The Mac was off or asleep since the previous wake that took the lock: the first wake
    /// since `lastTick`, a turned-away one included, came more than `offGap` after it; two
    /// turned-away wakes were that far apart (a run held the lock through a night's sleep); or
    /// this wake came that long after the latest turned-away one (a lid closed during a run). A
    /// stamp ahead of now reads as absent; no `lastTick` (a file from before it) is no gap
    /// before the refusals.
    static func wasOff(lastTick: Date?, refusals: TickLock.Refusals?, now: Date) -> Bool {
        func present(_ stamp: Date?) -> Date? { stamp.flatMap { $0 <= now ? $0 : nil } }
        if present(refusals?.afterGap) != nil { return true }
        if let latest = present(refusals?.latest), now.timeIntervalSince(latest) > offGap {
            return true
        }
        guard let lastTick = present(lastTick) else { return false }
        return (present(refusals?.first) ?? now).timeIntervalSince(lastTick) > offGap
    }

    /// Where the non-catch-up window is measured from: the first refusal since the Mac was last
    /// off, so a refusal from the evening before cannot let a morning backup run late. Nil (this
    /// wake) when no wake was refused since the last gap.
    static func nonCatchUpAnchor(refusals: TickLock.Refusals?, now: Date) -> Date? {
        guard let refusals, now.timeIntervalSince(refusals.latest) <= offGap else { return nil }
        return refusals.afterGap ?? refusals.first
    }

    /// `stamp`, or `.distantPast` for none or one beyond clock skew in the future (a clock set
    /// ahead once): a future stamp would otherwise cover every fire until then.
    private static func startStamp(_ stamp: Date?, now: Date) -> Date {
        guard let stamp, stamp.timeIntervalSince(now) <= SharedWorkspace.clockSkewTolerance
        else { return .distantPast }
        return stamp
    }

    /// Retry of a scheduled run that did not end its retries: collect modes only, each one its
    /// backoff after the previous start (`retryBackoffs.count` of them), then hourly on the same
    /// local day while `summaryMissing`, unless the last run failed in a way a retry repeats. A
    /// daily schedule's retries never cross local midnight; the next day is its own.
    private static func retryIsDue(
        mode: Schedule.RunMode, label: String, daily: Bool, state: TickState, now: Date,
        summaryMissing: () -> Bool
    ) -> Bool {
        guard mode.runsAtLoad else { return false }
        // A success stamped beyond clock skew ahead (a clock set ahead once) is no success yet.
        let succeeded = state.lastSucceeded[label].flatMap {
            $0.timeIntervalSince(now) <= SharedWorkspace.clockSkewTolerance ? $0 : nil
        } ?? .distantPast
        let started = startStamp(state.lastStarted[label], now: now)
        let sameDay = Calendar.current.isDate(started, inSameDayAs: now)
        guard succeeded < started, sameDay || !daily else { return false }
        let retries = state.retryCount[label] ?? 0
        guard retryBackoffs.indices.contains(retries) else {
            return sameDay
                && now.timeIntervalSince(started) >= missingSummaryRetryInterval
                && !state.retryWouldRepeat.contains(label)
                && summaryMissing()
        }
        return now.timeIntervalSince(started) >= retryBackoffs[retries]
    }
}

/// An acquired tick lock: the open descriptor holding the kernel's exclusive `flock` on the
/// lock file. The kernel drops the lock when the descriptor closes or the process dies, so a
/// holder that exits, crashes or is killed never leaves a lock behind.
final class TickLockHold: Sendable {
    private let fd: Mutex<Int32>

    fileprivate init(fd: Int32) { self.fd = Mutex(fd) }

    deinit { release() }

    /// Names no holder, then closes the descriptor, which frees the lock. Idempotent. The
    /// file stays: unlinking it would let a claimer holding the old inode and one creating a
    /// new file both think they hold the lock.
    func release() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            _ = fremovexattr(fd, TickLock.startAttribute, 0)
            _ = ftruncate(fd, 0)
            close(fd)
            fd = -1
        }
    }

    /// Still holding the lock: false once released or given up.
    var isHeld: Bool {
        fd.withLock { $0 >= 0 }
    }

    /// Sets the lock file's mtime to now, which the read-only probe judges staleness by.
    /// Best-effort.
    func touch() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            _ = futimens(fd, nil)
        }
    }

    /// Runs `body` while touching the lock every `interval`; beats stop after `limit`, which
    /// releases the lock and calls `onGiveUp` (see `heartbeat`). Stopped before returning.
    func keepingAlive<T: Sendable>(
        every interval: Duration = TickLock.heartbeatInterval,
        limit: Duration = TickLock.heartbeatLimit,
        onGiveUp: (@Sendable () -> Void)? = nil,
        _ body: () async -> T
    ) async -> T {
        let beats = heartbeat(every: interval, limit: limit, onGiveUp: onGiveUp)
        let result = await body()
        beats.cancel()
        await beats.value
        return result
    }

    /// `keepingAlive`'s beats, for a holder whose body runs on the main actor and so cannot
    /// be handed over: touches the lock every `interval` until cancelled. At `limit` it gives
    /// up the lock instead: no real run lasts that long, and a wedged live holder must not
    /// silence the ticker for good. `onGiveUp` runs right after the release, for a holder that is
    /// its own process and must not outlive its lock (the tick exits). The limit counts awake
    /// time only (`SuspendingClock`): a Mac that slept through the run must not give the lock up
    /// while the run goes on.
    func heartbeat(
        every interval: Duration = TickLock.heartbeatInterval,
        limit: Duration = TickLock.heartbeatLimit,
        onGiveUp: (@Sendable () -> Void)? = nil
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            let clock = SuspendingClock()
            let deadline = clock.now.advanced(by: limit)
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard clock.now < deadline else {
                    AppLogger.schedule.warning("tick lock given up: the run passed its time limit")
                    release()
                    onGiveUp?()
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
    ///
    /// When the holder recorded its start time (see `claim`), a pid that no longer exists or
    /// started at another time is a reused pid, not the holder. A reading that cannot be taken
    /// keeps today's answer, and so does a file with no record (written by 2.9.0).
    func isHeldByAnotherLiveProcess(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        startTime: (Int32) -> ProcessStartReading = TickLock.processStart
    ) -> Bool {
        guard let holder = holder(), holder > 1, holder != pid else { return false }
        guard !isReusedPid(holder, startTime: startTime) else { return false }
        return isAlive(holder) && !isStale()
    }

    /// True when the holder recorded its start time and the process now at that pid is gone
    /// or started at another time.
    private func isReusedPid(_ holder: Int32, startTime: (Int32) -> ProcessStartReading) -> Bool {
        guard let recorded = recordedStart(forHolder: holder) else { return false }
        switch startTime(holder) {
        case .noProcess: return true
        case .started(let actual): return actual != recorded
        case .unreadable: return false
        }
    }

    /// Takes the kernel lock and records `pid` in the file. Never follows a symlink at `url`.
    /// `protect` sets the file's mode; its failure is logged, not fatal, since the pid is
    /// already on disk and the hold must be released. The holder's start time goes in an
    /// extended attribute, not the text: 2.9.0 reads the whole file as a pid.
    func claim(
        pid: Int32 = getpid(),
        startTime: (Int32) -> ProcessStartReading = TickLock.processStart,
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
        recordStart(startTime(pid), pid: pid, fd: fd)
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
                "tick lock permissions not set: \(error.localizedDescription, privacy: .private)")
        }
        return .acquired(TickLockHold(fd: fd))
    }

    private func failed(_ what: String, _ code: Int32) -> Claim {
        let reason = String(cString: strerror(code))
        AppLogger.schedule.error(
            "tick lock could not be \(what, privacy: .public): \(reason, privacy: .private)")
        return .writeFailed
    }

    /// Name of the attribute that carries the holder's `"<pid> <sec> <usec>"` start time.
    static let startAttribute = "com.github.tonyyo11.jamf-reports-community.tick-start"

    /// When a process started, to tell a pid's holder from a later process that reused it.
    struct ProcessStart: Equatable, Sendable {
        let sec: Int
        let usec: Int32
    }

    enum ProcessStartReading: Equatable, Sendable {
        case started(ProcessStart)
        /// The kernel has no process with that pid.
        case noProcess
        case unreadable
    }

    /// `kp_proc.p_starttime` from `sysctl(KERN_PROC_PID)`, which works on another user's
    /// process without privilege; `proc_pidinfo` is private API and answers 0 on EPERM. A pid
    /// with no process is a successful call that returns no bytes.
    static func processStart(of pid: Int32) -> ProcessStartReading {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return .unreadable
        }
        guard size > 0 else { return .noProcess }
        return reading(of: info)
    }

    /// A zombie keeps its pid and start time until its parent reaps it but runs nothing, and
    /// `kill(pid, 0)` still succeeds on it, so it is no holder.
    static func reading(of info: kinfo_proc) -> ProcessStartReading {
        if Int32(info.kp_proc.p_stat) == SZOMB { return .noProcess }
        let started = info.kp_proc.p_starttime
        return .started(ProcessStart(sec: Int(started.tv_sec), usec: Int32(started.tv_usec)))
    }

    /// Through the held descriptor, before the pid is written, so a probe that sees the new
    /// pid sees its start time too. A reading that cannot be taken clears the attribute a
    /// previous holder left; the probe then answers as it did before the attribute existed.
    private func recordStart(_ reading: ProcessStartReading, pid: Int32, fd: Int32) {
        guard case .started(let started) = reading else {
            _ = fremovexattr(fd, Self.startAttribute, 0)
            return
        }
        let value = Array("\(pid) \(started.sec) \(started.usec)".utf8)
        if fsetxattr(fd, Self.startAttribute, value, value.count, 0, 0) != 0 {
            _ = fremovexattr(fd, Self.startAttribute, 0)
        }
    }

    /// The start time the file's holder recorded; nil when there is none or it names another
    /// pid than the text does (a holder that does not record one rewrote the file).
    private func recordedStart(forHolder holder: Int32) -> ProcessStart? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let length = getxattr(
            url.path, Self.startAttribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        let parts = String(decoding: buffer[0..<length], as: UTF8.self).split(separator: " ")
        guard parts.count == 3, Int32(parts[0]) == holder,
              let sec = Int(parts[1]), let usec = Int32(parts[2]) else { return nil }
        return ProcessStart(sec: sec, usec: usec)
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
    /// broken Application Support into a dead command, and a tick needs the same file. Past
    /// `limit` the lock is given up and `onGiveUp` runs, as for the tick: a call that never
    /// answered would otherwise run on beside the next wake's. A give-up under way finishes
    /// before this returns, so the caller never races its record or its exit.
    func holdingForRun<T: Sendable>(
        beatEvery interval: Duration = TickLock.heartbeatInterval,
        limit: Duration = TickLock.heartbeatLimit,
        onGiveUp: (@Sendable () -> Void)? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T? {
        switch claim() {
        case .heldElsewhere:
            return nil
        case .writeFailed:
            return try await body()
        case .acquired(let hold):
            let beats = hold.heartbeat(every: interval, limit: limit, onGiveUp: onGiveUp)
            defer { hold.release() }
            do {
                let result = try await body()
                beats.cancel()
                await beats.value
                return result
            } catch {
                beats.cancel()
                await beats.value
                throw error
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

    /// The wakes the lock turned away since the last wake that took it: the first, the latest,
    /// and the first after a gap of more than `TickScheduler.offGap` between two of them.
    typealias Refusals = (first: Date, latest: Date, afterGap: Date?)

    /// Logged when the stamp cannot be written or read; a test swaps it to capture the line.
    static let defaultStampWarning: @Sendable (String) -> Void = { message in
        AppLogger.schedule.warning("\(message, privacy: .private)")
    }

    /// The stamp's lines. A missing file is no stamp and no warning; a file that cannot be read
    /// warns and reads as absent, the same fail-safe a missing one gets.
    private static func stampLines(
        at url: URL, warn: (String) -> Void
    ) -> [String]? {
        do {
            let data = try BoundedFile.read(url, limit: 4096, followSymlinks: false)
            guard let text = String(data: data, encoding: .utf8) else {
                warn("tick refusal stamp \(url.lastPathComponent) is not UTF-8; read as absent")
                removeUnreadable(url)
                return nil
            }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch BoundedFile.Failure.unreadable(ENOENT) {
            return nil
        } catch {
            warn("tick refusal stamp \(url.lastPathComponent) could not be read "
                + "(\(error.localizedDescription)); read as absent")
            removeUnreadable(url)
            return nil
        }
    }

    /// Drop a bad regular file so its warning does not repeat on every wake; a folder or other
    /// non-regular entry at the path stays and keeps warning.
    private static func removeUnreadable(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Record that a wake was turned away. The stamp holds `Refusals` one per line (the third
    /// only once a gap happened) and is rewritten whole, atomically; the FIRST refusal is never
    /// overwritten. A stamp that cannot be read starts over; one that cannot be written warns.
    static func noteBlocked(
        url: URL = defaultBlockedURL, now: Date = Date(),
        warn: (String) -> Void = defaultStampWarning
    ) {
        let stamp = ISO8601Time.string(now)
        let lines = stampLines(at: url, warn: warn) ?? []
        var afterGap = lines.count > 2 ? lines[2] : nil
        if let latest = (lines.count > 1 ? lines[1] : lines.first).flatMap(ISO8601Time.parse),
           now.timeIntervalSince(latest) > TickScheduler.offGap {
            afterGap = stamp
        }
        let text = ([lines.first ?? stamp, stamp] + [afterGap].compactMap { $0 })
            .joined(separator: "\n")
        do {
            try Data("\(text)\n".utf8).write(to: url, options: .atomic)
        } catch {
            warn("tick refusal stamp \(url.lastPathComponent) could not be written "
                + "(\(error.localizedDescription)); the next run cannot tell it was queued")
        }
    }

    /// Read and clear the stamp; nil when no wake was blocked since the last wake that took the
    /// lock, or when the stamp cannot be read (warned). A stamp from an earlier build (one or
    /// two lines) reads as no gap, its one line as both the first and the latest.
    static func takeBlockedSince(
        url: URL = defaultBlockedURL, warn: (String) -> Void = defaultStampWarning
    ) -> Refusals? {
        guard let lines = stampLines(at: url, warn: warn) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let stamps = lines.map { ISO8601Time.parse($0) }
        guard let parsed = stamps.first, let first = parsed else { return nil }
        let latest = stamps.count > 1 ? stamps[1] : nil
        return (first, latest ?? first, stamps.count > 2 ? stamps[2] : nil)
    }
}
