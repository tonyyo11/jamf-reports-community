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

    static func due(
        schedules: [Schedule],
        lastStarted: [String: Date],
        runNowLabels: Set<String>,
        now: Date
    ) -> [Schedule] {
        schedules.filter { schedule in
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
            return schedule.mode.runsAtLoad || now.timeIntervalSince(fire) <= nonCatchUpWindow
        }
    }
}
