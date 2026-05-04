import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var bridge = CLIBridge()
    @State private var trendStore = TrendStore()
    @State private var isRunning = false
    @State private var activitySelection: DeviceInventoryRecord.ID? = nil

    var body: some View {
        NavigationStack {
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
            .navigationDestination(for: OverviewDrillDown.self) { destination in
                overviewDetail(destination)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            workspace.reloadFromDisk()
            if !workspace.demoMode {
                trendStore.load(profile: workspace.profile, range: .w12)
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
            kicker: workspace.demoMode ? "Snapshot · Apr 25, 2026 · 09:14" : "Snapshot · \(trendStore.filteredSummaries.last?.date ?? "No Data")",
            title: "\(workspace.org.name) Fleet Overview",
            subtitle: workspace.demoMode ? "524 Macs across 8 departments · 3 sites · NIST 800-53r5 Moderate baseline" : "\(trendStore.filteredSummaries.last?.totalDevices ?? 0) Macs · NIST 800-53r5 Moderate baseline",
            lastModified: workspace.demoMode ? Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 25)) : trendStore.filteredSummaries.last?.parsedDate
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
            workspace.toast = Toast(message: "Invalid profile name — generate aborted", style: .danger)
            return
        }
        isRunning = true
        workspace.globalStatus = "jrc collect + generate · profile=\(workspace.profile)"
        let profile = workspace.profile
        let exit = await bridge.collectThenGenerate(profile: profile, csvPath: nil) { line in
            Task { @MainActor in
                workspace.globalStatus = "jrc · \(line.text)"
            }
        }
        isRunning = false
        workspace.globalStatus = nil

        if exit == 0 {
            workspace.toast = Toast(message: "Report generated successfully", style: .success)
            workspace.reloadFromDisk()
            if !workspace.demoMode {
                trendStore.reload()
            }
        } else {
            workspace.toast = Toast(message: "Generate failed · exit \(exit)", style: .danger)
        }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            ForEach(workspace.selectedScoreCards) { metric in
                let isPrimary = metric == .stability
                let isDanger = scoreCardTrend(for: metric) == .down && metric != .stale
                NavigationLink(value: OverviewDrillDown.metric(metric.rawValue)) {
                    scoreCard(for: metric)
                        .modifier(StatTileHealthModifier(isDanger: isDanger, isPrimary: isPrimary))
                        .drillDownChrome()
                }
                .buttonStyle(.plain)
                .help("Open \(metric.displayLabel) details")
                .layoutPriority(isPrimary ? 1 : 0)
            }
        }
    }

    private func scoreCardTrend(for metric: TrendSeries.Metric) -> StatTile.Trend {
        let values: [Double] = workspace.demoMode ?
            (metric == .activeDevices ? DemoData.totalDevicesTrend : (DemoData.trends[metric] ?? [])) :
            trendStore.values(metric: metric)
        guard let last = values.last else { return .flat }
        let prev = values.count > 1 ? values[values.count - 2] : last
        let diff = last - prev
        if diff == 0 { return .flat }
        if metric == .stale { return diff < 0 ? .up : .down }
        return diff > 0 ? .up : .down
    }

    private func scoreCard(for metric: TrendSeries.Metric) -> some View {
        let values: [Double] = workspace.demoMode ?
            (metric == .activeDevices ? DemoData.totalDevicesTrend : (DemoData.trends[metric] ?? [])) :
            trendStore.values(metric: metric)

        let lastValue = values.last
        let current = lastValue ?? 0
        let prev = values.count > 1 ? values[values.count - 2] : current
        let diff = current - prev

        let valueStr: String = {
            guard let val = lastValue else { return "--" }
            if metric.unit == "%" {
                return "\(String(format: "%.1f", val))%"
            } else {
                return "\(Int(val))"
            }
        }()

        let deltaStr: String = {
            guard lastValue != nil else { return "No Data" }
            let absDiff = abs(diff)
            if metric.unit == "%" {
                return "\(diff >= 0 ? "+" : "−")\(String(format: "%.1f", absDiff))pp"
            } else {
                return "\(diff >= 0 ? "+" : "−")\(Int(absDiff))"
            }
        }()

        let trend: StatTile.Trend = {
            guard lastValue != nil else { return .flat }
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
            NavigationLink(value: OverviewDrillDown.osDistribution) {
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
                .drillDownChrome()
            }
            .buttonStyle(.plain)
            .help("Open macOS distribution details")
            .frame(maxWidth: .infinity)

            NavigationLink(value: OverviewDrillDown.failingRules) {
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
                            Pill(text: "View all 47", tone: .gold)
                        }
                        failingRulesBars
                    }
                }
                .drillDownChrome()
            }
            .buttonStyle(.plain)
            .help("Open failing rule details")
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
                        NavigationLink(value: OverviewDrillDown.securityAgent(a.name)) {
                            agentCard(a)
                                .drillDownChrome()
                        }
                        .buttonStyle(.plain)
                        .help("Open \(a.name) details")
                    }
                }
            }
        }
    }

    private func agentCard(_ a: SecurityAgent) -> some View {
        AgentCardView(agent: a)
    }

    // MARK: Recent activity table

    private var recentActivity: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "Recent Activity")
                    Spacer()
                    Pill(text: "8 of 524", tone: .muted)
                    NavigationLink(value: OverviewDrillDown.recentActivity) {
                        Text("View all")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.Colors.fg)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                Divider().background(Theme.Colors.hairlineStrong)

                Table(DemoData.deviceSample, selection: $activitySelection) {
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
                .contextMenu(forSelectionType: DeviceRow.ID.self) { selection in
                    if let id = selection.first, let device = DemoData.deviceSample.first(where: { $0.id == id }) {
                        Button("Copy Serial Number") {
                            SystemActions.copyToClipboard(device.serial)
                        }
                        Button("Copy User Email") {
                            SystemActions.copyToClipboard(device.user)
                        }
                        if let jamfID = device.numericJamfID, !workspace.org.jamfURL.isEmpty {
                            Button("Open in Jamf Pro") {
                                let jamfURL = workspace.org.jamfURL.trimmingCharacters(in: .init(charactersIn: "/"))
                                let urlString = "\(jamfURL)/computers.html?id=\(jamfID)&o=r"
                                if let url = URL(string: urlString) {
                                    SystemActions.open(url)
                                }
                            }
                        }
                    }
                }
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

    @ViewBuilder
    private func overviewDetail(_ destination: OverviewDrillDown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch destination {
                case .metric(let raw):
                    if let metric = TrendSeries.Metric(rawValue: raw) {
                        metricDetail(metric)
                    }
                case .osDistribution:
                    osDistributionDetail
                case .failingRules:
                    failingRulesDetail
                case .securityAgent(let name):
                    if let agent = DemoData.securityAgents.first(where: { $0.name == name }) {
                        securityAgentDetail(agent)
                    }
                case .recentActivity:
                    recentActivityDetail
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .background(Theme.Colors.winBG)
    }

    private func metricDetail(_ metric: TrendSeries.Metric) -> some View {
        let values = metricValues(metric)
        let current = values.last ?? 0
        let first = values.first ?? current
        let previous = values.count > 1 ? values[values.count - 2] : current
        return VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: metric.displayLabel,
                breadcrumbs: [Breadcrumb(label: "Overview", action: { dismiss() })],
                title: metric.displayLabel,
                subtitle: "\(values.count) summaries · \(workspace.profile)"
            )
            HStack(spacing: 12) {
                StatTile(label: "Current", value: metricValueLabel(current, metric: metric))
                StatTile(label: "Previous", value: metricValueLabel(previous, metric: metric))
                StatTile(label: "Change", value: metricDeltaLabel(current - first, metric: metric),
                         sub: "Since first snapshot")
            }
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Snapshot Values")
                    if values.isEmpty {
                        Text("No trend summaries are available for this metric yet.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    } else {
                        Sparkline(values: values, color: Color(hex: metric.colorHex))
                            .frame(height: 90)
                        HStack {
                            Mono(text: "First \(metricValueLabel(first, metric: metric))")
                            Spacer()
                            Mono(text: "Latest \(metricValueLabel(current, metric: metric))",
                                 color: Theme.Colors.goldBright)
                        }
                    }
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        detailHint(for: metric)
                        Spacer()
                        ForEach(relatedTabs(for: metric), id: \.self) { tab in
                            PNPButton(title: tab.label, icon: tab.sfSymbol, size: .sm) {
                                navigate(to: tab)
                            }
                        }
                    }
                }
            }
        }
    }

    private var osDistributionDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: "macOS Distribution",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { dismiss() })],
                title: "macOS Distribution",
                subtitle: "\(DemoData.osDistribution.reduce(0) { $0 + $1.count }) devices across \(DemoData.osDistribution.count) versions"
            )
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DemoData.osDistribution) { item in
                        detailProgressRow(
                            label: item.version,
                            value: item.pct,
                            trailing: "\(item.count) · \(String(format: "%.1f", item.pct))%",
                            color: Color(hex: item.colorHex)
                        )
                    }
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Text("Use Devices to inspect individual records and filter by OS version.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                        Spacer()
                        PNPButton(title: "Open Devices", icon: Tab.devices.sfSymbol, size: .sm) {
                            navigate(to: .devices)
                        }
                    }
                }
            }
        }
    }

    private var failingRulesDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: "Top Failing Rules",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { dismiss() })],
                title: "Top Failing Rules",
                subtitle: "NIST 800-53r5 Moderate · highest failure counts"
            )
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DemoData.topFailingRules) { rule in
                        detailProgressRow(
                            label: rule.ruleID,
                            value: Double(rule.fails),
                            maxValue: Double(DemoData.topFailingRules.map(\.fails).max() ?? 1),
                            trailing: "\(rule.fails) devices",
                            color: Theme.Colors.gold
                        )
                    }
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Text("Open Health Audit for finding context and remediation guidance.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                        Spacer()
                        PNPButton(title: "Open Health Audit", icon: Tab.audit.sfSymbol, size: .sm) {
                            navigate(to: .audit)
                        }
                    }
                }
            }
        }
    }

    private func securityAgentDetail(_ agent: SecurityAgent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: agent.name,
                breadcrumbs: [Breadcrumb(label: "Overview", action: { dismiss() })],
                title: agent.name,
                subtitle: "\(agent.installed) installed · mapped from \(agent.column)"
            )
            HStack(spacing: 12) {
                StatTile(label: "Coverage", value: "\(String(format: "%.1f", agent.pct))%")
                StatTile(label: "Installed", value: "\(agent.installed)", sub: "of 502 tracked devices")
                StatTile(label: "Trend", value: agent.trend.rawValue.capitalized)
            }
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    detailProgressRow(
                        label: agent.name,
                        value: agent.pct,
                        trailing: "\(String(format: "%.1f", agent.pct))%",
                        color: agent.pct > 90 ? Theme.Colors.ok : agent.pct > 80 ? Theme.Colors.gold : Theme.Colors.warn
                    )
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Text("Open Devices for host-level status, or Config to adjust tracked agent columns.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                        Spacer()
                        PNPButton(title: "Devices", icon: Tab.devices.sfSymbol, size: .sm) {
                            navigate(to: .devices)
                        }
                        PNPButton(title: "Config", icon: Tab.config.sfSymbol, size: .sm) {
                            navigate(to: .config)
                        }
                    }
                }
            }
        }
    }

    private var recentActivityDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: "Recent Activity",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { dismiss() })],
                title: "Recent Activity",
                subtitle: "\(DemoData.deviceSample.count) recent devices from the current snapshot"
            )
            Card(padding: 0) {
                Table(DemoData.deviceSample, selection: $activitySelection) {
                    TableColumn("Device") { d in
                        Text(d.name).font(.system(size: 12.5, weight: .semibold))
                    }
                    TableColumn("Serial") { d in Mono(text: d.serial) }
                    TableColumn("macOS") { d in Mono(text: d.os) }
                    TableColumn("User") { d in
                        Text(d.user).font(.system(size: 12.5)).foregroundStyle(Theme.Colors.fgMuted)
                    }
                    TableColumn("Failed Rules") { d in failurePill(d.fails) }
                    TableColumn("Last Seen") { d in
                        Mono(text: d.lastSeen,
                             color: d.lastSeen.contains("day") ? Theme.Colors.warn : Theme.Colors.fgMuted)
                    }
                }
                .frame(minHeight: 340)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: DeviceRow.ID.self) { selection in
                    if let id = selection.first, let device = DemoData.deviceSample.first(where: { $0.id == id }) {
                        Button("Copy Serial Number") {
                            SystemActions.copyToClipboard(device.serial)
                        }
                        Button("Copy User Email") {
                            SystemActions.copyToClipboard(device.user)
                        }
                        if let jamfID = device.numericJamfID, !workspace.org.jamfURL.isEmpty {
                            Button("Open in Jamf Pro") {
                                let jamfURL = workspace.org.jamfURL.trimmingCharacters(in: .init(charactersIn: "/"))
                                let urlString = "\(jamfURL)/computers.html?id=\(jamfID)&o=r"
                                if let url = URL(string: urlString) {
                                    SystemActions.open(url)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                PNPButton(title: "Open Full Device Inventory", icon: Tab.devices.sfSymbol) {
                    navigate(to: .devices)
                }
            }
        }
    }

    private func detailProgressRow(
        label: String,
        value: Double,
        maxValue: Double = 100,
        trailing: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Colors.fg2)
                .lineLimit(1)
                .frame(width: 260, alignment: .leading)
            GeometryReader { geo in
                let width = maxValue == 0 ? 0 : min(value / maxValue, 1) * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(color).frame(width: width)
                }
            }
            .frame(height: 8)
            Mono(text: trailing, color: Theme.Colors.fg)
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func detailHint(for metric: TrendSeries.Metric) -> some View {
        let text: String = switch metric {
        case .stability:
            "Composite of compliance, patch posture, and stale-device pressure."
        case .activeDevices:
            "Open Devices to inspect records contributing to this count."
        case .compliance:
            "Open Health Audit for controls, findings, and recommendations."
        case .fileVault:
            "Open Devices to inspect FileVault state on individual Macs."
        case .osCurrent:
            "Open Devices to inspect macOS versions and filter inventory."
        case .crowdstrike:
            "Open Devices or Config to review security-agent tracking."
        case .stale:
            "Open Devices to focus on stale inventory records."
        case .patch:
            "Open Devices to review devices with patch failures."
        }
        return Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.Colors.fgMuted)
    }

    private func relatedTabs(for metric: TrendSeries.Metric) -> [Tab] {
        switch metric {
        case .stability:
            return [.trends, .audit]
        case .activeDevices, .fileVault, .osCurrent, .stale, .patch:
            return [.devices]
        case .compliance:
            return [.audit]
        case .crowdstrike:
            return [.devices, .config]
        }
    }

    private func metricValues(_ metric: TrendSeries.Metric) -> [Double] {
        if workspace.demoMode {
            return metric == .activeDevices
                ? DemoData.totalDevicesTrend
                : (DemoData.trends[metric] ?? [])
        }
        return trendStore.values(metric: metric)
    }

    private func metricValueLabel(_ value: Double, metric: TrendSeries.Metric) -> String {
        metric.unit == "%"
            ? "\(String(format: "%.1f", value))%"
            : "\(Int(value.rounded()))"
    }

    private func metricDeltaLabel(_ value: Double, metric: TrendSeries.Metric) -> String {
        let prefix = value >= 0 ? "+" : "-"
        let absValue = abs(value)
        return metric.unit == "%"
            ? "\(prefix)\(String(format: "%.1f", absValue))pp"
            : "\(prefix)\(Int(absValue.rounded()))"
    }

    private func navigate(to tab: Tab) {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
    }
}

private enum OverviewDrillDown: Hashable {
    case metric(String)
    case osDistribution
    case failingRules
    case securityAgent(String)
    case recentActivity
}

private extension View {
    func drillDownChrome() -> some View {
        modifier(DrillDownChromeModifier())
    }
}

private struct DrillDownChromeModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.goldBright)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        isHovering ? Theme.Colors.gold.opacity(0.4) : Theme.Colors.hairlineStrong,
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
    }
}

private struct StatTileHealthModifier: ViewModifier {
    let isDanger: Bool
    let isPrimary: Bool

    func body(content: Content) -> some View {
        content
            .frame(minWidth: isPrimary ? 200 : nil)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(isDanger ? Theme.Colors.danger.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        isDanger ? Theme.Colors.danger.opacity(0.35) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }
}

private struct AgentCardView: View {
    let agent: SecurityAgent
    @State private var isHovering = false

    var body: some View {
        let pct = agent.pct
        let isAtRisk = pct < 80
        let barColor: Color = pct > 90 ? Theme.Colors.ok :
                              pct > 80 ? Theme.Colors.gold : Theme.Colors.warn
        let trackColor: Color = isAtRisk ? Theme.Colors.warn.opacity(0.15) : Color.white.opacity(0.05)
        let gap = max(0, 502 - agent.installed)

        return VStack(alignment: .leading, spacing: 4) {
            Text(agent.name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
            Text("\(String(format: "%.1f", pct))%")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
            HStack(spacing: 6) {
                Mono(text: "\(agent.installed) / 502", size: 10.5)
                if agent.trend == .up {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.ok)
                }
            }
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor).frame(height: 4)
                GeometryReader { geo in
                    Capsule().fill(barColor).frame(width: geo.size.width * pct / 100, height: 4)
                }
                .frame(height: 4)
            }
            .padding(.top, 4)
            if isAtRisk {
                Mono(text: "\(gap) not installed", size: 10, color: Theme.Colors.fgMuted)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(isHovering ? 0.25 : 0), radius: isHovering ? 8 : 0, y: isHovering ? 4 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
