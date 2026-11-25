import Foundation

/// What the Overview's "Since last collect" section shows: the newest summary's change counts
/// and each security agent's coverage against the summary before it. Pure, so tests and demo
/// mode build it without a store.
struct OverviewChanges: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// The summary the counts come from; shown when it is not today's.
    let day: String
    let computers: ComputerChanges?
    let benchmarks: BenchmarkChanges?
    let agents: [Row]

    /// Nil when no summary carries a change part.
    static func build(summaries: [DailySummary], format: PercentFormat) -> OverviewChanges? {
        let sorted = summaries.sorted { $0.date < $1.date }
        guard let newest = sorted.last(where: { $0.changes != nil }), let changes = newest.changes
        else { return nil }
        let withAgents = sorted.filter { $0.securityAgentCoverage != nil }
        let agents = withAgents.count >= 2
            ? agentRows(newer: withAgents[withAgents.count - 1].securityAgentCoverage,
                        older: withAgents[withAgents.count - 2].securityAgentCoverage,
                        format: format)
            : []
        return OverviewChanges(day: newest.date, computers: changes.computers,
                               benchmarks: changes.benchmarks, agents: agents)
    }

    /// "41.2% → 43.0%" per agent both summaries list, sorted by name; an agent on one side
    /// only, or whose printed share did not change, is left out.
    static func agentRows(
        newer: [String: Double]?, older: [String: Double]?, format: PercentFormat
    ) -> [Row] {
        guard let newer, let older else { return [] }
        return newer.keys.sorted().compactMap { name in
            guard let now = newer[name], let before = older[name] else { return nil }
            let (was, isNow) = (format.text(before), format.text(now))
            return was == isNow ? nil : Row(label: name, value: "\(was) → \(isNow)")
        }
    }

    /// One row per Mac count; "Not measured" for a count the collect could not take.
    var computerRows: [Row] {
        guard let computers, computers.baselineUnreadable != true else { return [] }
        func value(_ count: Int?) -> String { count.map { "\($0)" } ?? L("Not measured") }
        return [
            Row(label: L("Enrolled"), value: value(computers.joined)),
            Row(label: L("Removed"), value: value(computers.left)),
            Row(label: L("Went stale"), value: value(computers.becameStale)),
            Row(label: L("Checking in again"), value: value(computers.noLongerStale)),
            Row(label: L("FileVault turned off"), value: value(computers.fileVaultOff)),
            Row(label: L("FileVault stopped reporting"),
                value: value(computers.fileVaultStoppedReporting)),
            Row(label: L("macOS version changed"), value: value(computers.osChanged)),
        ]
    }

    /// Why the counts are missing, or the large-change note; nil when neither applies.
    var computerNote: String? {
        guard let computers else { return nil }
        if computers.baselineUnreadable == true {
            return computers.baselineUnreadableReason == .tooLarge
                ? L("Could not be read: over the 256 MB limit")
                : L("Could not be read: the file did not decode")
        }
        if let percent = computers.largeChangePercent {
            return L("Large change: \(percent)% of the fleet joined or left. Check that the last collect finished.")
        }
        return nil
    }

    var benchmarkRow: Row? {
        guard let newly = benchmarks?.newlyFailing else { return nil }
        return Row(label: L("Benchmark rules newly failing"), value: "\(newly)")
    }
}
