import Foundation

/// What the Overview's "Since last collect" section shows: the newest summary's change counts
/// and each security agent's coverage against the summary before it. Pure, so tests and demo
/// mode build it without a store.
struct OverviewChanges: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        /// The Computers list behind the count; nil for 0, not measured or no snapshot pair.
        var filter: ChangeFilter? = nil
        /// The screen the row opens without a filter (benchmark rules).
        var opens: Tab? = nil
        /// A `ChangeKind` raw value, "benchmarks" or the agent's name; never the translated label.
        var id: String

        init(label: String, value: String, filter: ChangeFilter? = nil, opens: Tab? = nil,
             id: String? = nil) {
            self.label = label
            self.value = value
            self.filter = filter
            self.opens = opens
            self.id = id ?? label
        }
    }

    /// The day of the summary the Mac counts (else the benchmark rules) come from; shown when
    /// it is not today's.
    let day: String
    let computers: ComputerChanges?
    let benchmarks: BenchmarkChanges?
    let patch: PatchChanges?
    let agents: [Row]

    /// A patch part from further back than one weekly scan plus a day is not shown: the scan
    /// has stopped landing, or is on hold.
    static let patchMaxAgeDays = 8

    /// Each part from the newest summary that has it: Mac counts and benchmark rules come
    /// every two days, patch scans weekly, so one summary rarely holds all three. Nil when no
    /// summary carries a part.
    static func build(summaries: [DailySummary], format: PercentFormat) -> OverviewChanges? {
        let sorted = summaries.sorted { $0.date < $1.date }
        let computers = sorted.last { $0.changes?.computers != nil }
        let benchmarks = sorted.last { $0.changes?.benchmarks != nil }
        let patch = sorted.last { $0.changes?.patch != nil }.flatMap { day in
            recent(day.parsedDate, newest: sorted.last?.parsedDate) ? day : nil
        }
        guard let anchor = computers ?? benchmarks ?? patch else { return nil }
        let withAgents = sorted.filter { $0.securityAgentCoverage != nil }
        let agents = withAgents.count >= 2
            ? agentRows(newer: withAgents[withAgents.count - 1].securityAgentCoverage,
                        older: withAgents[withAgents.count - 2].securityAgentCoverage,
                        format: format)
            : []
        return OverviewChanges(
            day: anchor.date, computers: computers?.changes?.computers,
            benchmarks: benchmarks?.changes?.benchmarks, patch: patch?.changes?.patch,
            agents: agents)
    }

    private static func recent(_ day: Date, newest: Date?) -> Bool {
        guard let newest else { return false }
        let days = Calendar.current.dateComponents([.day], from: day, to: newest).day ?? .max
        return days <= patchMaxAgeDays
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
        let kinds: [ChangeKind] = [.joined, .left, .becameStale, .noLongerStale, .fileVaultOff,
                                   .fileVaultStoppedReporting, .osChanged]
        return kinds.map { kind in
            Row(label: kind.label, value: Self.value(kind.count(in: computers)),
                filter: ChangeFilter.from(computers, kind: kind), id: kind.rawValue)
        }
    }

    private static func value(_ count: Int?) -> String { count.map { "\($0)" } ?? L("Not measured") }

    /// Why the counts are missing, or the large-change note; nil when neither applies.
    var computerNote: String? {
        guard let computers else { return nil }
        if computers.baselineUnreadable == true {
            return computers.baselineUnreadableReason == .tooLarge
                ? L("Could not be read: over the 256 MB limit")
                : L("Could not be read: the file did not decode")
        }
        if let percent = computers.largeChangePercent {
            let share = PercentFormat.whole.text(Double(percent))
            return L("Large change: \(share) of the fleet joined or left. Check that the last collect finished.")
        }
        return nil
    }

    /// The patch rows, in policy failures (Mac and policy pairs); none without a part.
    var patchRows: [Row] {
        guard let patch else { return [] }
        return [ChangeKind.patchStarted, .patchNoLongerListed].map { kind in
            Row(label: kind.label,
                value: patch.baselineUnreadable == true
                    ? Self.unreadable(patch.baselineUnreadableReason)
                    : Self.value(kind.count(in: patch)),
                filter: ChangeFilter.from(patch, kind: kind), id: kind.rawValue)
        }
    }

    private static func unreadable(_ reason: ComputerChanges.UnreadableReason?) -> String {
        reason == .tooLarge
            ? L("Could not be read: over the read limit") : L("Could not be read")
    }

    /// The scan's day when it differs from `day`; nil when its stamp does not parse.
    var patchScanDay: String? {
        guard let stamp = patch?.currentStamp,
              let date = PatchReleaseDateService.stampDate(stamp) else { return nil }
        let scanDay = SummaryJSONParser.dateFormatter.string(from: date)
        return scanDay == day ? nil : scanDay
    }

    var benchmarkRow: Row? {
        guard let benchmarks else { return nil }
        if benchmarks.baselineUnreadable == true {
            return Row(label: L("Benchmark rules newly failing"),
                       value: Self.unreadable(benchmarks.baselineUnreadableReason),
                       id: "benchmarks")
        }
        guard let newly = benchmarks.newlyFailing else { return nil }
        return Row(label: L("Benchmark rules newly failing"), value: "\(newly)",
                   opens: newly > 0 ? .complianceBenchmarks : nil, id: "benchmarks")
    }
}
