import SwiftUI

/// Per-profile state that every screen reads. Owned by the app shell so a profile
/// switch (sidebar bottom chip) re-routes every view to a different workspace's data.
@MainActor
@Observable
final class WorkspaceStore {

    var org: Org
    var profile: String
    var profiles: [JamfCLIProfile]
    var schedules: [Schedule]
    var sheetCatalog: [SheetGroup]
    var customEAs: [CustomEA]
    var columnMappings: [ColumnMapping]
    var demoMode: Bool
    var selectedScoreCards: [TrendSeries.Metric]

    init(demoMode: Bool? = nil) {
        // Auto-detect demo mode: if no real workspace exists, fall back to demo.
        // The Settings screen's Demo Mode toggle will overwrite this later.
        let realProfiles = ProfileService.discoverLocal()
        let realSchedules = LaunchAgentService.list()
        let isDemo = demoMode ?? (realProfiles.isEmpty)

        self.demoMode = isDemo
        self.org = DemoData.org
        self.profile = isDemo ? DemoData.org.profile : (realProfiles.first?.name ?? DemoData.org.profile)
        self.profiles = isDemo ? DemoData.cliProfiles : realProfiles
        self.schedules = isDemo ? DemoData.scheduledRuns : realSchedules
        self.sheetCatalog = DemoData.sheetCatalog
        self.customEAs = DemoData.customEAs
        self.columnMappings = DemoData.columnMappings
        self.selectedScoreCards = [.activeDevices, .fileVault, .compliance, .stale]
    }

    func setProfile(_ id: String) {
        guard ProfileService.isValid(id) else { return }
        profile = id
        if !demoMode {
            // Reload real schedules for the new profile (filtered by label prefix).
            schedules = LaunchAgentService.list().filter { $0.profile == id }
        }
    }

    /// Reload from disk — called from the sidebar refresh and after onboarding.
    func reloadFromDisk() {
        let real = ProfileService.discoverLocal()
        if real.isEmpty {
            demoMode = true
            profiles = DemoData.cliProfiles
            schedules = DemoData.scheduledRuns
        } else {
            demoMode = false
            profiles = real
            schedules = LaunchAgentService.list()
            if !real.contains(where: { $0.name == profile }) {
                profile = real.first!.name
            }
        }
    }
}

/// Routes the active screen. `Tab` is the source of truth for which detail view
/// the `NavigationSplitView` renders, and the title shown in the toolbar.
enum Tab: String, CaseIterable, Identifiable, Hashable {
    case overview, devices, trends, reports, schedules, runs
    case config, customize, sources, settings, onboarding

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:   "Overview"
        case .devices:    "Devices"
        case .trends:     "Trends"
        case .reports:    "Generated"
        case .schedules:  "Schedules"
        case .runs:       "Run History"
        case .config:     "Config"
        case .customize:  "Customize"
        case .sources:    "Data Sources"
        case .settings:   "Settings"
        case .onboarding: "Onboarding"
        }
    }

    /// SF Symbol for the sidebar — closest match to the prototype's inline SVG icons.
    var sfSymbol: String {
        switch self {
        case .overview:   "house"
        case .devices:    "laptopcomputer"
        case .trends:     "chart.line.uptrend.xyaxis"
        case .reports:    "doc.text"
        case .schedules:  "clock"
        case .runs:       "terminal"
        case .config:     "wrench.and.screwdriver"
        case .customize:  "sparkles"
        case .sources:    "externaldrive"
        case .settings:   "gear"
        case .onboarding: "wand.and.stars"
        }
    }

    var badge: String? {
        switch self {
        case .devices:   "inv"
        case .trends:    "26w"
        case .reports:   "47"
        case .schedules: "5"
        default:         nil
        }
    }

    var badgeIsGold: Bool { self == .trends }
}

/// Sidebar collapse state. Persisted via `@AppStorage`. Standard macOS shortcut
/// `⌘0` cycles through the three states.
enum SidebarMode: String, CaseIterable {
    case expanded, compact, hidden

    func next() -> SidebarMode {
        switch self {
        case .expanded: .compact
        case .compact:  .hidden
        case .hidden:   .expanded
        }
    }
}
