import Foundation

/// Per-label "last started" stamps. Lives beside the schedule store, not in
/// a workspace: the recorder's status file has no start time, and a managed
/// schedule's status is one file per profile.
struct TickState: Codable, Sendable {
    static let defaultURL = AppSupport.directory().appendingPathComponent("tick-state.json")

    var lastStarted: [String: Date] = [:]

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
}

/// Pure "what is due" decision. Input order is preserved so the caller
/// controls run order (managed kinds first, then hand-built by label).
enum TickScheduler {
    /// Modes that do NOT catch up (generate-from-cache, backup) only run when
    /// the missed fire is this recent — matches their old `RunAtLoad: false`.
    static let nonCatchUpWindow: TimeInterval = 15 * 60

    /// - Parameter nonCatchUpAnchor: When a wake was turned away by the lock,
    ///   the time of the FIRST such refusal. The non-catch-up window is measured
    ///   from the earlier of it and `now`, so a 40-minute collect that blocks
    ///   three wakes cannot swallow the 07:00 backup that came due while it ran.
    ///   `nil` (the default) measures from `now`, the plain uncontended case.
    static func due(
        schedules: [Schedule],
        lastStarted: [String: Date],
        runNowLabels: Set<String>,
        now: Date,
        nonCatchUpAnchor: Date? = nil
    ) -> [Schedule] {
        let anchor = min(nonCatchUpAnchor ?? now, now)
        return schedules.filter { schedule in
            guard let label = schedule.launchAgentLabel else { return false }
            if runNowLabels.contains(label) { return true }
            guard schedule.enabled else { return false }
            guard let entries = try? LaunchAgentWriter.calendarIntervals(for: schedule.schedule),
                  let fire = LaunchAgentService.lastScheduledFireDate(from: entries, before: now)
            else {
                AppLogger.schedule.warning(
                    "tick: \(label, privacy: .public) has an unreadable cadence and was skipped")
                return false
            }
            let started = lastStarted[label] ?? .distantPast
            guard fire > started else { return false }
            return schedule.mode.runsAtLoad || anchor.timeIntervalSince(fire) <= nonCatchUpWindow
        }
    }
}

/// One tick at a time. A pid file: a live holder blocks, a dead or garbage
/// holder is taken over — the 300-second wake must never pile a second run
/// on top of a 20-minute collect.
struct TickLock: Sendable {
    static let defaultURL = AppSupport.directory().appendingPathComponent(".tick.lock")

    /// Where the first blocked wake stamps itself, so the run that eventually
    /// gets in knows how long the queue has been waiting.
    static let defaultBlockedURL = AppSupport.directory()
        .appendingPathComponent(".tick.blocked")

    /// A lock older than this is taken over even when its pid still looks
    /// alive. Pids are recycled and a run can wedge on a hung network call;
    /// without an upper bound either one silences the ticker permanently.
    static let staleAfter: TimeInterval = 3600

    let url: URL

    func acquire(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> Bool {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let holder = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           holder != pid, isAlive(holder), !isStale() {
            return false
        }
        do {
            try Data(String(pid).utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            AppLogger.schedule.error(
                "tick lock could not be written: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
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
