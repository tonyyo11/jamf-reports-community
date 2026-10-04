import Foundation

/// Per-agent history for days the app recorded before it wrote `securityAgentCoverage`,
/// rebuilt from the dated `ea-results` snapshots the way `loadMobileCountBackfill` rebuilds
/// mobile counts. It is a second phase after the Trends and Overview load, because one
/// production snapshot is about 13 MB: decoding one takes about 0.5 s in a debug build (about
/// 0.1 s of it the coverage pass), so every day with a snapshot would hold the first paint for
/// seconds.
///
/// What it does, so the cost stays bounded:
/// - only summaries without `securityAgentCoverage` are touched, and nothing is read when
///   none is missing or no agent is configured;
/// - only the newest `agentBackfillMaxDays` such days that have a snapshot stamped that local
///   day (the newest of the day, sync-conflict copies and manifests excluded) are read;
/// - each snapshot is decoded once per app session: the result, or the fact that it could not
///   be used, is kept in memory under the file's name and the agents' configuration;
/// - a snapshot recovered from a truncated file is not used, since a partial row set would
///   understate coverage.
extension TrendStore {
    nonisolated static let agentBackfillMaxDays = 21

    /// `summaries` with per-agent coverage filled in where the summary lacks it and a
    /// snapshot of its day can supply it. Order is unchanged. Off the main actor.
    nonisolated static func resolvingAgentCoverage(
        _ summaries: [DailySummary], profile: String
    ) -> [DailySummary] {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let config = try? ConfigLoader.load(
                  from: workspace.appendingPathComponent("config.yaml"))
        else { return summaries }
        let agents = SecurityScoreInputs.namedAgents(in: config)
        let days = summaries.filter { $0.securityAgentCoverage == nil }.map(\.date)
        guard !agents.isEmpty, !days.isEmpty else { return summaries }
        let dataDir = (try? WorkspacePaths.dataDir(for: profile))
            ?? workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let installed = agentCounts(
            onDays: Set(days), agents: agents, profile: profile, dataDir: dataDir)
        guard !installed.isEmpty else { return summaries }
        let edr = SecurityScoreInputs.edrAgent(in: config)
            .map { SecurityScoreInputs.agentKey($0.name) }
        return summaries.map { summary in
            guard summary.securityAgentCoverage == nil, let counts = installed[summary.date]
            else { return summary }
            var coverage: [String: Double] = [:]
            for (name, count) in counts {
                coverage[name] = SecurityAgentCoverage.percent(
                    installed: count, fleet: summary.totalDevices)
            }
            return coverage.isEmpty
                ? summary : summary.withBackfilledAgentCoverage(coverage, edrAgent: edr)
        }
    }

    /// Macs connected per agent (only agents some Mac reports) for the newest
    /// `agentBackfillMaxDays` of `days` that have a usable snapshot, keyed by day.
    private nonisolated static func agentCounts(
        onDays days: Set<String>, agents: [SecurityAgentConfig], profile: String, dataDir: URL
    ) -> [String: [String: Int]] {
        var newestByDay: [String: (url: URL, date: Date)] = [:]
        for snapshot in datedSnapshots(of: "ea-results", in: dataDir) {
            let day = SummaryJSONParser.dateFormatter.string(from: snapshot.date)
            if days.contains(day) { newestByDay[day] = snapshot }  // oldest first: newest wins
        }
        let signature = agents
            .map { "\($0.name)|\($0.column)|\($0.connectedValue)" }.joined(separator: ";")
        var result: [String: [String: Int]] = [:]
        for day in newestByDay.keys.sorted(by: >).prefix(agentBackfillMaxDays) {
            guard let snapshot = newestByDay[day] else { continue }
            let key = "\(profile)|\(day)|\(snapshot.url.lastPathComponent)|\(signature)"
            let counts = AgentBackfillCache.shared.counts(for: key) {
                decodedAgentCounts(at: snapshot.url, agents: agents)
            }
            if !counts.isEmpty { result[day] = counts }
        }
        return result
    }

    private nonisolated static func decodedAgentCounts(
        at url: URL, agents: [SecurityAgentConfig]
    ) -> [String: Int] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoded = EAResultRow.decodeSnapshot(data)
        guard let rows = decoded.rows, decoded.reason == "array" || decoded.reason == "envelope"
        else { return [:] }
        var counts: [String: Int] = [:]
        for coverage in SecurityAgentCoverage.compute(rows: rows, agents: agents)
        where coverage.reporting > 0 {
            counts[SecurityScoreInputs.agentKey(coverage.name)] = coverage.installed
        }
        return counts
    }
}

/// Per-session memory of what each dated `ea-results` snapshot said about the agents, so the
/// 13 MB files are decoded once however often the Overview and Trends reload. An empty entry
/// records a snapshot that could not be used, which is not retried either.
private final class AgentBackfillCache: @unchecked Sendable {
    static let shared = AgentBackfillCache()
    private let lock = NSLock()
    private var entries: [String: [String: Int]] = [:]

    func counts(for key: String, compute: () -> [String: Int]) -> [String: Int] {
        lock.lock()
        let hit = entries[key]
        lock.unlock()
        if let hit { return hit }
        let value = compute()
        lock.lock()
        entries[key] = value
        lock.unlock()
        return value
    }
}
