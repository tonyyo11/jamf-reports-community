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

    /// The demo workspace's own summaries (`DemoData.fleetSummaries(for:)`); every demo trend
    /// date is a summary, so the stability trend has the Overview's history, not one point.
    private func demoFleetOverview() -> FleetWorkspaceOverview {
        let summaries = DemoData.fleetSummaries(for: profile)
        return FleetWorkspaceOverview(
            profile: profile, summary: summaries.last, summaries: summaries,
            isSchool: DemoData.environmentProducts(for: profile).isSchool)
    }
}
