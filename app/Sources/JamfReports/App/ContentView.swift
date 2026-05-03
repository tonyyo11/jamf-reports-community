import SwiftUI

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var tab: Tab = .trends
    @AppStorage("sidebarMode") private var sidebarModeRaw: String = SidebarMode.expanded.rawValue

    private var sidebarMode: SidebarMode {
        get { SidebarMode(rawValue: sidebarModeRaw) ?? .expanded }
    }

    var body: some View {
        if workspace.profiles.isEmpty && !workspace.demoMode {
            OnboardingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.winBG.ignoresSafeArea())
        } else {
            shell
        }
    }

    private var shell: some View {
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

                ZStack(alignment: .bottom) {
                    detailView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.Colors.winBG)

                    if let toast = workspace.toast {
                        toastView(toast)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(100)
                    }
                }

                StatusBar(status: workspace.globalStatus)
            }
        }
        .background(Theme.Colors.winBG.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .cycleSidebar)) { _ in
            cycleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTab)) { note in
            if let raw = note.userInfo?["tab"] as? String, let newTab = Tab(rawValue: raw) {
                tab = newTab
            }
        }
        .task {
            await workspace.autoUpdateJamfCLIIfNeeded()
        }
        .animation(.snappy(duration: 0.28), value: sidebarModeRaw)
        .animation(.snappy, value: workspace.toast != nil)
    }

    @ViewBuilder
    private var detailView: some View {
        switch tab {
        case .overview:   OverviewView()
        case .fleet:      FleetOverviewView()
        case .devices:    DevicesView()
        case .trends:     TrendsView()
        case .audit:      AuditView()
        case .reports:    ReportsView()
        case .schedules:  SchedulesView()
        case .runs:       RunsView()
        case .config:     ConfigView()
        case .customize:  CustomizeView()
        case .sources:    SourcesView()
        case .backups:    BackupsView()
        case .settings:   SettingsView()
        case .onboarding: OnboardingView()
        }
    }

    private func subtitle(for tab: Tab) -> String? {
        switch tab {
        case .overview:   "FLEET"
        case .fleet:      "MULTI-PROFILE"
        case .devices:    "INVENTORY"
        case .trends:     "26W"
        case .audit:      "HEALTH & HYGIENE"
        case .schedules:  "LAUNCHAGENT"
        case .runs:       "STDOUT"
        case .config:     "CONFIG.YAML"
        case .customize:  "SHEETS"
        case .sources:    "INPUTS"
        case .backups:    "CONFIG SNAPSHOTS"
        case .settings:   "APP"
        case .onboarding: "FIRST RUN"
        case .reports:    nil
        }
    }

    private func cycleSidebar() {
        sidebarModeRaw = sidebarMode.next().rawValue
    }

    @ViewBuilder
    private func toastView(_ toast: Toast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: toastIcon(toast.style))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toastColor(toast.style))

            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)

            Button {
                workspace.toast = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .padding(.bottom, 40)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if workspace.toast?.id == toast.id {
                    workspace.toast = nil
                }
            }
        }
    }

    private func toastIcon(_ style: Toast.Style) -> String {
        switch style {
        case .info:    "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .danger:  "exclamationmark.triangle.fill"
        }
    }

    private func toastColor(_ style: Toast.Style) -> Color {
        switch style {
        case .info:    Theme.Colors.info
        case .success: Theme.Colors.ok
        case .danger:  Theme.Colors.danger
        }
    }
}
