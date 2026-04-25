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

    init(demoMode: Bool = true) {
        self.demoMode = demoMode
        self.org = DemoData.org
        self.profile = DemoData.org.profile
        self.profiles = DemoData.cliProfiles
        self.schedules = DemoData.scheduledRuns
        self.sheetCatalog = DemoData.sheetCatalog
        self.customEAs = DemoData.customEAs
        self.columnMappings = DemoData.columnMappings
    }

    func setProfile(_ id: String) {
        profile = id
        // In a real workspace switch, we'd reload from
        // ~/Jamf-Reports/<id>/{config.yaml, jamf-cli-data/, Generated Reports/}
    }
}

/// Routes the active screen. `Tab` is the source of truth for which detail view
/// the `NavigationSplitView` renders, and the title shown in the toolbar.
enum Tab: String, CaseIterable, Identifiable, Hashable {
    case overview, trends, reports, schedules, runs
    case config, customize, sources, settings, onboarding

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:   "Overview"
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
