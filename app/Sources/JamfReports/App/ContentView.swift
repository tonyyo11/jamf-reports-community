import SwiftUI

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var tab: Tab = .trends
    @AppStorage("sidebarMode") private var sidebarModeRaw: String = SidebarMode.expanded.rawValue

    private var sidebarMode: SidebarMode {
        get { SidebarMode(rawValue: sidebarModeRaw) ?? .expanded }
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarMode != .hidden {
                Sidebar(activeTab: $tab, mode: sidebarMode)
                    .frame(width: sidebarMode == .compact
                           ? Theme.Metrics.sidebarWidthCompact
                           : Theme.Metrics.sidebarWidthExpanded)
                    .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                Titlebar(
                    title: tab.label,
                    sub: subtitle(for: tab),
                    sidebarMode: sidebarMode,
                    onCycleSidebar: cycleSidebar
                )
                Divider().background(Theme.Colors.hairline)
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.winBG)
            }
        }
        .background(Theme.Colors.winBG.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .cycleSidebar)) { _ in
            cycleSidebar()
        }
        .animation(.snappy(duration: 0.28), value: sidebarModeRaw)
    }

    @ViewBuilder
    private var detailView: some View {
        switch tab {
        case .overview:   OverviewView()
        case .devices:    DevicesView()
        case .trends:     TrendsView()
        case .reports:    ReportsView()
        case .schedules:  SchedulesView()
        case .runs:       RunsView()
        case .config:     ConfigView()
        case .customize:  CustomizeView()
        case .sources:    SourcesView()
        case .settings:   SettingsView()
        case .onboarding: OnboardingView()
        }
    }

    private func subtitle(for tab: Tab) -> String? {
        switch tab {
        case .overview:   "FLEET"
        case .devices:    "INVENTORY"
        case .trends:     "26W"
        case .schedules:  "LAUNCHAGENT"
        case .runs:       "STDOUT"
        case .config:     "CONFIG.YAML"
        case .customize:  "SHEETS"
        case .sources:    "INPUTS"
        case .settings:   "APP"
        case .onboarding: "FIRST RUN"
        case .reports:    nil
        }
    }

    private func cycleSidebar() {
        sidebarModeRaw = sidebarMode.next().rawValue
    }
}
