import SwiftUI

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var workspace
    /// Default landing tab once a workspace exists. Overview is the
    /// app's home page — it surfaces every metric at a glance, while
    /// Trends only renders after at least two scheduled runs (so a
    /// freshly-onboarded workspace would otherwise land on an empty
    /// "No trend data yet" screen).
    @State private var tab: Tab = .overview
    /// Tracks the chooser → OnboardingView handoff on a truly fresh
    /// install (no profiles, no persisted demo preference). Transient
    /// UI state — does not need to survive relaunch. If the user quits
    /// the app mid-onboarding, the chooser shows again on next launch,
    /// which is the right behaviour: they didn't commit to a path.
    @State private var userPickedOnboarding = false
    @AppStorage("sidebarMode") private var sidebarModeRaw: String = SidebarMode.expanded.rawValue
    @AppStorage("defaultTrendRange") private var defaultTrendRangeRaw: String = TrendRange.w4.rawValue
    @AppStorage("hiddenTabs") private var hiddenTabsRaw: String = ""

    private var sidebarMode: SidebarMode {
        get { SidebarMode(rawValue: sidebarModeRaw) ?? .expanded }
    }

    var body: some View {
        if workspace.profiles.isEmpty && !workspace.demoMode {
            if userPickedOnboarding {
                OnboardingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.winBG.ignoresSafeArea())
            } else {
                FirstLaunchChooserView(onStartOnboarding: { userPickedOnboarding = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.winBG.ignoresSafeArea())
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPreviousTab)) { _ in
            let visibility = TabVisibility.parse(hiddenTabsRaw)
            if let dest = previousVisibleTab(from: tab, in: visibility) { tab = dest }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToNextTab)) { _ in
            let visibility = TabVisibility.parse(hiddenTabsRaw)
            if let dest = nextVisibleTab(from: tab, in: visibility) { tab = dest }
        }
        .task {
            await workspace.autoUpdateJamfCLIIfNeeded()
            // PR-24: wire up the background refresh coordinator. The
            // foreground observer re-checks staleness when the app
            // reactivates; the initial trigger covers this launch, since
            // willBecomeActive may have already fired before the observer
            // registered. Both no-op in demo mode.
            workspace.registerForegroundRefresh()
            workspace.triggerRefresh(for: workspace.profile)
            // v2.2.0 launch freshness sweep: surface a prompt for heavy-tier
            // data older than a week (never auto-collected — on-prem safety)
            // and silently refresh week-old audit data (config analysis,
            // cheap). Both no-op in demo mode.
            await workspace.checkHeavyTierStaleness()
            await workspace.autoRefreshAuditIfStale()
            // v2.2.0 managed automation: reconcile the policy-driven
            // all-profiles agents. No-op unless the operator opted in
            // (AutomationPolicy.isManaged); no-op in demo mode.
            await workspace.reconcileManagedAutomation()
        }
        .animation(.snappy(duration: 0.28), value: sidebarModeRaw)
        .animation(.snappy, value: workspace.toast != nil)
    }

    @ViewBuilder
    private var detailView: some View {
        switch tab {
        case .overview:          OverviewView()
        case .fleet:             FleetOverviewView()
        case .devices:           DevicesView()
        case .deviceLookup:      DeviceLookupView()
        case .trends:            TrendsView()
        case .audit:             AuditView()
        case .reports:           ReportsView()
        case .schedules:         SchedulesView()
        case .runs:              RunsView()
        case .config:            ConfigView()
        case .customize:         CustomizeView()
        case .sources:           SourcesView()
        case .backups:           BackupsView()
        case .settings:          SettingsView()
        case .onboarding:        OnboardingView()
        case .securityPosture:   SecurityPostureView()
        case .compliancePosture: CompliancePostureView()
        case .complianceBenchmarks: ComplianceBenchmarksView()
        case .patch:             PatchView()
        case .updates:           UpdatesView()
        case .ddmBlueprints:     DDMBlueprintView()
        case .policyProfile:     PolicyProfileView()
        case .extensionAttributes: ExtensionAttributesView()
        case .outreach:          OutreachView()
        case .protectDashboard:  ProtectView()
        case .mobileFleet:       MobileFleetView()
        case .groupInventory:    GroupsView()
        }
    }

    private func subtitle(for tab: Tab) -> String? {
        switch tab {
        case .overview:          "FLEET"
        case .fleet:             "MULTI-PROFILE"
        case .devices:           "INVENTORY"
        case .deviceLookup:      "LOOKUP"
        case .trends:            TrendRange(rawValue: defaultTrendRangeRaw)?.rawValue ?? TrendRange.w4.rawValue
        case .audit:             "HEALTH & HYGIENE"
        case .schedules:         "LAUNCHAGENT"
        case .runs:              "STDOUT"
        case .config:            "CONFIG.YAML"
        case .customize:         "SHEETS"
        case .sources:           "INPUTS"
        case .backups:           "CONFIG SNAPSHOTS"
        case .settings:          "APP"
        case .onboarding:        "FIRST RUN"
        case .reports:           nil
        case .securityPosture:   "SCORE & CONTROLS"
        case .compliancePosture: "BANDS & GAPS"
        case .complianceBenchmarks: "EXPERIMENTAL · PLATFORM API"
        case .patch:             "TITLES & FAILURES"
        case .updates:           "PLANS & FAILURES"
        case .ddmBlueprints:     "EXPERIMENTAL · PLATFORM API"
        case .policyProfile:     "FINDINGS & STATUS"
        case .extensionAttributes: "COVERAGE & VALUES"
        case .outreach:          "STALE TIERS"
        case .protectDashboard:  "ALERTS & AGENTS"
        case .mobileFleet:       "IOS · IPADOS"
        case .groupInventory:    "CLASSIC API"
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
                .font(.body.weight(.medium))
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
