import SwiftUI

struct SchedulesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var profileFilter: String = "All"
    @State private var bridge = CLIBridge()
    @State private var isRunning = false
    @State private var lastRunMessage: String? = nil

    private var profileCount: Int {
        Set(workspace.schedules.map(\.profile)).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                profileFilterStrip
                nextUpCallout
                schedulesTable
                runModesExplainer
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "macOS LaunchAgent · UserAgent",
            title: "Scheduled Runs",
            subtitle: "\(workspace.schedules.count) schedules · \(workspace.schedules.filter(\.enabled).count) enabled · across \(profileCount) jamf-cli profiles"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Open launchctl", icon: "terminal")
                    PNPButton(title: "New schedule", icon: "plus", style: .gold)
                }
            )
        }
    }

    private var profileFilterStrip: some View {
        HStack(spacing: 8) {
            Kicker(text: "JAMF-CLI PROFILE")
                .padding(.trailing, 4)

            Pill(text: "All · \(workspace.schedules.count)", tone: .gold)

            ForEach(DemoData.cliProfiles) { p in
                let count = workspace.schedules.filter { $0.profile == p.name }.count
                Pill(text: "\(p.name) · \(count)", tone: .muted)
                    .opacity(count > 0 ? 1 : 0.5)
            }

            Spacer()

            PNPButton(title: "Add profile", icon: "plus", size: .sm)
        }
    }

    private var nextUpCallout: some View {
        GlassPane(borderColor: Theme.Colors.gold.opacity(0.4)) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.Colors.gold, Theme.Colors.goldDim],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Image(systemName: "clock")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x1A1408))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Kicker(text: "Next run · in 21h 46m", tone: .gold)
                    Text("Daily Snapshot Collection")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    HStack(spacing: 4) {
                        Text("Apr 26 · 06:00 · jamf-cli-only · profile")
                        Text("meridian-prod").foregroundStyle(Theme.Colors.goldBright)
                        Text("· refreshes 14 snapshot files")
                    }
                    .font(Theme.Fonts.mono(11.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                }
                Spacer()
                PNPButton(
                    title: isRunning ? "Running…" : "Run now",
                    icon: isRunning ? "hourglass" : "play.fill"
                ) {
                    guard !isRunning else { return }
                    Task { await runNextScheduledNow() }
                }
            }
        }
    }

    private func runNextScheduledNow() async {
        let target = workspace.schedules.first(where: \.enabled) ?? workspace.schedules.first
        guard let target, ProfileService.isValid(target.profile) else { return }
        isRunning = true
        lastRunMessage = "Running \(target.name) (\(target.profile))…"
        let exit = await bridge.collect(profile: target.profile) { _ in }
        isRunning = false
        lastRunMessage = exit == 0
            ? "\(target.name) completed · exit 0"
            : "\(target.name) failed · exit \(exit)"
    }

    private var schedulesTable: some View {
        Card(padding: 0) {
            Table(workspace.schedules) {
                TableColumn("") { s in
                    PNPToggle(isOn: .constant(s.enabled))
                        .allowsHitTesting(false)
                }
                .width(48)

                TableColumn("Schedule") { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.system(size: 13, weight: .semibold))
                        Mono(text: s.launchAgentLabel, size: 10.5)
                    }
                }

                TableColumn("Profile") { s in
                    Pill(text: s.profile, tone: .gold)
                }
                .width(140)

                TableColumn("Cadence") { s in Mono(text: s.schedule) }
                TableColumn("Mode") { s in Pill(text: s.mode.rawValue, tone: .muted) }
                TableColumn("Next Run") { s in
                    Mono(text: s.next, color: s.enabled ? Theme.Colors.goldBright : Theme.Colors.fgMuted)
                }
                TableColumn("Last Run") { s in Mono(text: s.last) }
                TableColumn("Status") { s in
                    statusPill(for: s.lastStatus)
                }
                .width(80)
                TableColumn("Outputs") { s in
                    HStack(spacing: 4) {
                        if s.artifacts.isEmpty {
                            Text("—").foregroundStyle(Theme.Colors.fgMuted)
                        } else {
                            ForEach(s.artifacts, id: \.self) { a in
                                Pill(text: a, tone: .muted)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            .scrollContentBackground(.hidden)
        }
    }

    private func statusPill(for s: Schedule.LastStatus) -> some View {
        switch s {
        case .ok:    Pill(text: "OK", tone: .teal, icon: "checkmark")
        case .warn:  Pill(text: "WARN", tone: .warn, icon: "exclamationmark")
        case .fail:  Pill(text: "FAIL", tone: .danger, icon: "xmark")
        }
    }

    private var runModesExplainer: some View {
        let modes: [(String, String, String, Color)] = [
            ("snapshot-only", "Refresh jamf-cli JSON · archive CSVs", "icloud.and.arrow.up", Theme.Colors.info),
            ("jamf-cli-only", "Live or cached jamf-cli sheets", "bolt.fill", Theme.Colors.gold),
            ("jamf-cli-full", "Baseline CSV + snapshots + report", "shield.lefthalf.filled", Theme.Colors.ok),
            ("csv-assisted",  "CSV inbox + jamf-cli", "folder.fill", Theme.Colors.purple),
        ]
        return HStack(spacing: 10) {
            ForEach(modes, id: \.0) { mode in
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: mode.2)
                                .font(.system(size: 14))
                                .foregroundStyle(mode.3)
                            Text(mode.0)
                                .font(Theme.Fonts.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fg)
                        }
                        Text(mode.1)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
            }
        }
    }
}
