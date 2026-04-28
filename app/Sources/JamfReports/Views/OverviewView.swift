import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var bridge = CLIBridge()
    @State private var trendStore = TrendStore()
    @State private var runStatus: String? = nil
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !workspace.demoMode, !workspace.isWorkspaceInitialized {
                    workspaceInitBanner
                }
                statRow
                if workspace.demoMode {
                    osAndRules
                    securityAgents
                    recentActivity
                } else {
                    liveWorkspaceState
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .onAppear {
            if !workspace.demoMode {
                trendStore.load(profile: workspace.profile, range: .w12)
            }
        }
        .onChange(of: workspace.profile) { _, newValue in
            if !workspace.demoMode {
                trendStore.load(profile: newValue, range: .w12)
            }
        }
    }

    private var workspaceInitBanner: some View {
        Card(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workspace not initialized")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text(workspace.workspaceInitMessage ?? workspaceInitDefaultMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if workspace.isInitializingWorkspace {
                    ProgressView().controlSize(.small)
                } else {
                    PNPButton(title: "Initialize", style: .gold, size: .sm) {
                        Task { await workspace.initializeWorkspace() }
                    }
                }
            }
        }
    }

    private var workspaceInitDefaultMessage: String {
        guard let url = ProfileService.workspaceURL(for: workspace.profile) else {
            return "Invalid workspace profile. Choose another profile or rename it in jamf-cli."
        }
        let config = url.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: url.path) {
            return "\(config.path) is missing. Initialize it to seed config.yaml and helper folders."
        }
        return "\(url.path) does not exist yet. Initialize it to seed config.yaml and helper folders."
    }

    private var liveWorkspaceState: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Live Workspace")
                    Spacer()
                    Pill(text: workspace.profile, tone: .gold)
                }

                HStack(spacing: 12) {
                    liveStateTile(
                        label: "jamf-cli",
                        value: workspace.jamfCLIVersion ?? "Missing",
                        sub: workspace.jamfCLIPath ?? "Not found",
                        ok: workspace.jamfCLIPath != nil
                    )
                    liveStateTile(
                        label: "jrc",
                        value: workspace.jrcPath == nil ? "Missing" : "Available",
                        sub: workspace.jrcPath ?? "No CLI entrypoint found",
                        ok: workspace.jrcPath != nil
                    )
                    liveStateTile(
                        label: "Trend summaries",
                        value: "\(trendStore.filteredSummaries.count)",
                        sub: "~/Jamf-Reports/\(workspace.profile)/",
                        ok: !trendStore.filteredSummaries.isEmpty
                    )
                }

                if trendStore.filteredSummaries.isEmpty {
                    Divider().background(Theme.Colors.hairline)
                    Text("No cached tenant summaries are available for this profile yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
            }
        }
    }

    private func liveStateTile(label: String, value: String, sub: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Kicker(text: label, tone: ok ? .teal : .muted)
            Text(value)
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .lineLimit(1)
            Mono(text: sub, size: 10.5, color: Theme.Colors.fgMuted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ok ? Theme.Colors.hairlineStrong : Theme.Colors.warn.opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        PageHeader(
            kicker: runStatus ?? (workspace.demoMode ? "Snapshot · Apr 25, 2026 · 09:14" : "Snapshot · \(trendStore.filteredSummaries.last?.date ?? "No Data")"),
            title: "\(workspace.org.name) Fleet Overview",
            subtitle: workspace.demoMode ? "524 Macs across 8 departments · 3 sites · NIST 800-53r5 Moderate baseline" : "\(trendStore.filteredSummaries.last?.totalDevices ?? 0) Macs · NIST 800-53r5 Moderate baseline"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        workspace.reloadFromDisk()
                        if !workspace.demoMode {
                            trendStore.load(profile: workspace.profile, range: .w12)
                        }
                    }
                    PNPButton(
                        title: isRunning ? "Running…" : "Generate Report",
                        icon: isRunning ? "hourglass" : "play.fill",
                        style: .gold
                    ) {
                        guard !isRunning else { return }
                        Task { await runGenerate() }
                    }
                }
            )
        }
    }

    private func runGenerate() async {
        guard ProfileService.isValid(workspace.profile) else {
            runStatus = "Invalid profile name — generate aborted"
            return
        }
        isRunning = true
        runStatus = "jrc collect + generate · profile=\(workspace.profile)"
        let profile = workspace.profile
        let exit = await bridge.collectThenGenerate(profile: profile, csvPath: nil) { line in
            Task { @MainActor in
                runStatus = "jrc · \(line.text)"
            }
        }
        isRunning = false
        runStatus = exit == 0
            ? "Generate completed · exit 0"
            : "Generate failed · exit \(exit) · check Run History"
            
        if exit == 0 {
            workspace.reloadFromDisk()
        }
        if exit == 0 && !workspace.demoMode {
            trendStore.reload()
        }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            ForEach(workspace.selectedScoreCards) { metric in
                scoreCard(for: metric)
            }
        }
    }

    private func scoreCard(for metric: TrendSeries.Metric) -> some View {
        let values: [Double] = workspace.demoMode ? 
            (metric == .activeDevices ? DemoData.totalDevicesTrend : (DemoData.trends[metric] ?? [])) :
            trendStore.values(metric: metric)
        
        let current = values.last ?? 0
        let prev = values.count > 1 ? values[values.count - 2] : current
        let diff = current - prev
        
        let valueStr: String = {
            if metric.unit == "%" {
                return "\(String(format: "%.1f", current))%"
            } else {
                return "\(Int(current))"
            }
        }()
        
        let deltaStr: String = {
            let absDiff = abs(diff)
            if metric.unit == "%" {
                return "\(diff >= 0 ? "+" : "−")\(String(format: "%.1f", absDiff))pp"
            } else {
                return "\(diff >= 0 ? "+" : "−")\(Int(absDiff))"
            }
        }()
        
        let trend: StatTile.Trend = {
            if diff == 0 { return .flat }
            if metric == .stale {
                return diff < 0 ? .up : .down // lower stale is good (up)
            }
            return diff > 0 ? .up : .down
        }()

        return StatTile(
            label: metric.displayLabel,
            value: valueStr,
            delta: deltaStr,
            deltaTrend: trend,
            sparkValues: values,
            sparkColor: Color(hex: metric.colorHex)
        )
    }

    // MARK: OS distribution donut + Top failing rules

    private var osAndRules: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionHeader(title: "macOS Distribution")
                        Spacer()
                        Pill(text: "5 versions", tone: .muted)
                    }
                    HStack(alignment: .center, spacing: 18) {
                        donut
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(DemoData.osDistribution) { o in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color(hex: o.colorHex))
                                        .frame(width: 8, height: 8)
                                    Text(o.version)
                                        .font(.system(size: 12))
                                        .foregroundStyle(o.current ? Theme.Colors.fg : Theme.Colors.fgMuted)
                                    Spacer(minLength: 0)
                                    Mono(text: "\(o.count)")
                                    Text("\(String(format: "%.1f", o.pct))%")
                                        .font(Theme.Fonts.mono(11, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.fg)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionHeader(title: "Top Failing Rules")
                            Text("NIST 800-53r5 Moderate · across 502 active devices")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                        PNPButton(title: "View all 47", size: .sm)
                    }
                    failingRulesBars
                }
            }
            .frame(maxWidth: .infinity * 1.4)
        }
    }

    private var donut: some View {
        Chart(DemoData.osDistribution) { o in
            SectorMark(
                angle: .value("Devices", o.pct),
                innerRadius: .ratio(0.62),
                outerRadius: .ratio(0.95),
                angularInset: 1.2
            )
            .foregroundStyle(Color(hex: o.colorHex))
        }
        .chartLegend(.hidden)
        .frame(width: 160, height: 160)
        .overlay(
            VStack(spacing: 2) {
                Text("73%")
                    .font(Theme.Fonts.serif(26, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                Kicker(text: "On Current")
            }
        )
    }

    private var failingRulesBars: some View {
        let rules = DemoData.topFailingRules.prefix(6)
        let maxFails = rules.map(\.fails).max() ?? 1
        return VStack(spacing: 8) {
            ForEach(Array(rules)) { r in
                HStack(spacing: 8) {
                    Text(r.ruleID)
                        .font(Theme.Fonts.mono(11.5))
                        .foregroundStyle(Theme.Colors.fg2)
                        .frame(width: 260, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        let w = CGFloat(r.fails) / CGFloat(maxFails) * geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.04))
                                .frame(height: 10)
                            Capsule().fill(Theme.Colors.gold).frame(width: w, height: 10)
                        }
                    }
                    .frame(height: 10)
                    Text("\(r.fails)")
                        .font(Theme.Fonts.mono(11.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Security agents

    private var securityAgents: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Security Agents")
                    Spacer()
                    Kicker(text: "5 tracked")
                }
                HStack(spacing: 10) {
                    ForEach(DemoData.securityAgents) { a in
                        agentCard(a)
                    }
                }
            }
        }
    }

    private func agentCard(_ a: SecurityAgent) -> some View {
        let barColor: Color = a.pct > 90 ? Theme.Colors.ok :
                              a.pct > 80 ? Theme.Colors.gold : Theme.Colors.warn
        return VStack(alignment: .leading, spacing: 4) {
            Text(a.name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
            Text("\(String(format: "%.1f", a.pct))%")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
            HStack(spacing: 6) {
                Mono(text: "\(a.installed) / 502", size: 10.5)
                if a.trend == .up {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.ok)
                }
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.05)).frame(height: 4)
                GeometryReader { geo in
                    Capsule().fill(barColor).frame(width: geo.size.width * a.pct / 100, height: 4)
                }
                .frame(height: 4)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Recent activity table

    private var recentActivity: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "Recent Activity")
                    Spacer()
                    Pill(text: "8 of 524", tone: .muted)
                    PNPButton(title: "View all", size: .sm)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                Divider().background(Theme.Colors.hairlineStrong)

                Table(DemoData.deviceSample) {
                    TableColumn("Device") { d in
                        Text(d.name).font(.system(size: 12.5, weight: .semibold))
                    }
                    TableColumn("Serial") { d in Mono(text: d.serial) }
                    TableColumn("macOS") { d in Mono(text: d.os) }
                    TableColumn("User") { d in
                        Text(d.user).font(.system(size: 12.5)).foregroundStyle(Theme.Colors.fgMuted)
                    }
                    TableColumn("Department") { d in Text(d.dept).font(.system(size: 12.5)) }
                    TableColumn("FV") { d in
                        Image(systemName: d.fileVault ? "checkmark" : "xmark")
                            .foregroundStyle(d.fileVault ? Theme.Colors.ok : Theme.Colors.danger)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .width(40)
                    TableColumn("Failed Rules") { d in failurePill(d.fails) }
                    TableColumn("Last Seen") { d in
                        Mono(text: d.lastSeen,
                             color: d.lastSeen.contains("day") ? Theme.Colors.warn : Theme.Colors.fgMuted)
                    }
                }
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func failurePill(_ count: Int) -> some View {
        switch count {
        case 0:        Pill(text: "PASS", tone: .teal)
        case 1...10:   Pill(text: "\(count)", tone: .muted)
        case 11...30:  Pill(text: "\(count)", tone: .warn)
        default:       Pill(text: "\(count)", tone: .danger)
        }
    }
}
