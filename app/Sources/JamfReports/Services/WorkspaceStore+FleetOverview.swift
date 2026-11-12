import Foundation

/// What Fleet Overview shows: the active workspace's daily summaries. Two workspaces can be
/// different Jamf Pro servers, so the screen never reads another profile; cross-environment
/// figures exist only in the report-group exports (`FleetReportEmitter`, `FleetWorkbookEmitter`).
struct FleetWorkspaceOverview: Sendable {
    let profile: String
    let summary: DailySummary?
    var summaries: [DailySummary] = []
    /// A Jamf School workspace writes no daily summary, so none of the summary issues applies.
    var isSchool = false

    /// Taken when shown, so a Customize change reads without reloading the summaries.
    func issues(format: PercentFormat, staleDays: Int) -> [FleetProfileIssue] {
        isSchool ? [] : fleetProfileIssues(summary, format: format, staleDays: staleDays)
    }

    /// This overview when it was loaded for `profile`, else nil: a load that finished after
    /// the sidebar moved to another workspace must not show under that workspace's name.
    func shown(for profile: String) -> FleetWorkspaceOverview? {
        self.profile == profile ? self : nil
    }
}

extension WorkspaceStore {
    /// Changes with the sidebar profile, so switching it reloads Fleet Overview.
    var fleetOverviewLoadKey: String { "\(demoMode)|\(profile)" }

    /// Reads the active profile's summaries off the main actor; no other profile is read.
    func loadFleetOverview(
        readSummaries: @escaping @Sendable (String) -> [DailySummary] = {
            TrendStore.readSummaries(profile: $0)
        }
    ) async -> FleetWorkspaceOverview {
        if demoMode { return demoFleetOverview() }
        let name = profile
        let isSchool = isSchoolWorkspace
        let summaries = await Task.detached(priority: .utility) { readSummaries(name) }.value
        return FleetWorkspaceOverview(
            profile: name, summary: summaries.last, summaries: summaries, isSchool: isSchool)
    }

    /// The first demo profile reads the Overview's own demo fleet; each later one is a
    /// smaller variation of it.
    private func demoFleetOverview() -> FleetWorkspaceOverview {
        func latest(_ metric: TrendSeries.Metric) -> Double {
            DemoData.trends[metric]?.last ?? 0
        }
        let idx = profiles.firstIndex { $0.name == profile } ?? 0
        let offset = Double(idx * 4)
        let dateIndex = max(DemoData.trendDates.count - 1 - idx, 0)
        let summary = DailySummary(
            date: DemoData.trendDates[safe: dateIndex] ?? "2026-04-20",
            totalDevices: DemoData.deviceCount(forProfileAt: idx),
            fileVaultPct: latest(.fileVault) - offset,
            compliancePct: max(latest(.compliance) - offset, 0),
            staleCount: Int(latest(.stale).rounded()) + idx * 4,
            osCurrentPct: latest(.osCurrent) - offset,
            crowdstrikePct: latest(.edrAgent) - offset,
            patchPct: latest(.patch) - offset
        )
        return FleetWorkspaceOverview(profile: profile, summary: summary, summaries: [summary])
    }
}
