import SwiftUI
import Charts

/// Jamf Protect telemetry dashboard. Surfaces overview KPIs, alerts, computer
/// agent health, and insights from `jamf-cli protect *` snapshots. Renders a
/// clear empty state when no Protect data exists (many tenants don't run Protect).
struct ProtectView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: ProtectDashboardService.Snapshot = .empty
    /// The `dataSource` `snapshot` was read for; the content waits for it to match.
    @State private var loadedSource: String?
    @State private var reloads = 0
    @State private var experimentalFeatures = ExperimentalFeatureService()
    @State private var selectedTimelineDevice: String?
    @State private var connectedProducts = ConnectedProducts.none
    @State private var showingConnect = false
    @State private var proMatch = ProMatchState.pending

    /// The "Jamf Pro match" card ("Jamf School match" on a School workspace): nothing until the
    /// match has run, then either the result or the reason there is none.
    private enum ProMatchState {
        case pending, noInventory(ProtectProCorrelation.Inventory), ready(ProtectProCorrelation)
    }

    /// Protect is connected to this workspace (`protect.enabled` with a profile). Before 2.10
    /// the screen decided from snapshots on disk alone, so an unconnected workspace was told
    /// to run jamf-cli commands that write nothing into it.
    private var protectConnected: Bool {
        workspace.demoMode || connectedProducts.protectProfile != nil
    }

    /// The demo shows the deep dive: its data is populated, and a locked card on
    /// top of it read as a feature the demo tenant could not have.
    private var deepDiveEnabled: Bool {
        workspace.demoMode || experimentalFeatures.isEnabled(.protect)
    }

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Protect",
                title: "Jamf Protect",
                subtitle: subtitle,
                // The demo dataset is fixed; an age measured from today would grow
                // for as long as the demo stays open.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate,
                trailing: { AnyView(deepDiveEnabled ? AnyView(ExperimentalBadge()) : AnyView(EmptyView())) }
            )

            if loadedSource != dataSource {
                ScreenLoadingCard(what: "Jamf Protect data")
            } else {
                // Shared StaleDataBanner surfaces snapshot freshness above the main content.
                // Suppressed in demo mode (the demo dataset is intentionally static and
                // not user-perceivably "stale"). Renders nothing when source is .fresh.
                if !workspace.demoMode && protectConnected {
                    StaleDataBanner(source: snapshot.cacheSource)
                    // A tenant that doesn't run Protect at all has no expected
                    // kinds — every one of them would render a false-alarm "never"
                    // chip. Only assert expectations once Protect is detected;
                    // present-kind chips still show either way.
                    FreshnessChipRow(
                        sourceDates: snapshot.sourceDates,
                        expectedKinds: snapshot.isDetected ? [
                            "protect-overview", "protect-alerts", "protect-computers",
                            "protect-insights", "protect-plans",
                        ] : []
                    )
                }

                if !snapshot.unreadableKinds.isEmpty { unreadableBanner }
                if !protectConnected && !snapshot.isDetected && snapshot.unreadableKinds.isEmpty {
                    notConnectedState
                } else {
                    if !deepDiveEnabled { lockedDeepDiveState }
                    if snapshot.isDetected {
                        dataSections
                    } else if snapshot.unreadableKinds.isEmpty {
                        emptyState
                    }
                }
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onChange(of: dataSource) { _, _ in
            // The picked device belongs to the old source; a real host name must not outlive it.
            selectedTimelineDevice = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    private var subtitle: String? {
        guard snapshot.isDetected else { return nil }
        let severityAlertCount = snapshot.highAlerts + snapshot.mediumAlerts
            + snapshot.lowAlerts + snapshot.informationalAlerts
        // Protect covers 12 of the demo fleet's 524 Macs; say it is a pilot rather
        // than leave the gap to read as missing data.
        let computers = snapshot.totalComputers
        let computersPart: String? = computers == 0 ? nil : (workspace.demoMode
            ? "Pilot: \(computers) of \(DemoData.totalDevices) Macs"
            : "\(computers) computer\(computers == 1 ? "" : "s")")
        let parts: [String] = [
            computersPart,
            !snapshot.alerts.isEmpty ? "\(snapshot.alerts.count) alert\(snapshot.alerts.count == 1 ? "" : "s")" :
                (severityAlertCount > 0 ?
                 "\(severityAlertCount) alert\(severityAlertCount == 1 ? "" : "s")" : nil),
            !snapshot.insights.isEmpty ? "\(snapshot.insights.count) insight\(snapshot.insights.count == 1 ? "" : "s")" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Data loading

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { snapshot = .empty; connectedProducts = .none }
        // The demo's rows are drawn by the same code as a live tenant's, and its
        // counts are taken from those rows.
        if workspace.demoMode {
            snapshot = DemoData.protectSnapshot
            connectedProducts = .none
        } else {
            let profile = workspace.profile
            guard let loaded = await ScreenLoad.paint(
                stillCurrent: { source == dataSource },
                read: { (ProtectDashboardService.load(profile: profile),
                         ConnectedProducts.read(profile: profile)) }
            ) else { return }
            snapshot = loaded.0
            connectedProducts = loaded.1
        }
        loadedSource = source
        await loadProMatch(source: source)
    }

    /// The `computers` snapshot can be about 13 MB, so the match runs after the screen paints.
    private func loadProMatch(source: String) async {
        proMatch = .pending
        guard !snapshot.computers.isEmpty else { return }
        let protect = snapshot.computers
        let profile = workspace.profile
        let demo = workspace.demoMode
        let school = workspace.isSchoolWorkspace
        guard let result = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: { ProtectProCorrelation.load(
                protect: protect, profile: profile, demoMode: demo, school: school) }
        ) else { return }
        proMatch = result.map(ProMatchState.ready)
            ?? .noInventory(school ? .jamfSchool : .jamfPro)
    }

    // MARK: - Sections

    @ViewBuilder
    private var dataSections: some View {
        if snapshot.totalComputers > 0 || !snapshot.alerts.isEmpty
            || !snapshot.insights.isEmpty {
            kpiGrid
        }
        if !snapshot.alerts.isEmpty {
            alertsBySeverityCard
            recentAlertsCard
        }
        if deepDiveEnabled {
            if !snapshot.alerts.isEmpty {
                killChainStageCard
                deviceTimelineCard
            }
            if !snapshot.computers.isEmpty {
                agentVersionCard
            }
        }
        if !snapshot.computers.isEmpty {
            computersCard
            proMatchCard
        }
        if !snapshot.insights.isEmpty {
            insightsCard
        }
        if !snapshot.plans.isEmpty {
            plansCard
        }
    }

    /// A newest file is there but cannot be read: the rows it would hold are unknown, not zero.
    private var unreadableBanner: some View {
        InlineBanner(icon: "exclamationmark.triangle.fill", tone: .warn) {
            Text("Could not be read: "
                + snapshot.unreadableKinds.map { $0.replacingOccurrences(of: "protect-", with: "") }
                    .joined(separator: ", ")
                + ". Refresh to collect it again; the file is named in Settings › Logging.")
        }
    }

    /// Connected, nothing collected yet: Protect follows each Jamf Pro or Jamf School collect.
    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "shield.lefthalf.filled",
                title: "No Jamf Protect data yet",
                message: "Jamf Protect is connected. Its data arrives with the next collect: "
                    + "Refresh on the Overview, or the next scheduled run."
            )
        }
    }

    private var notConnectedState: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                EmptyStateView(
                    systemImage: "shield.lefthalf.filled",
                    title: "Jamf Protect is not connected",
                    message: "Connect Jamf Protect to this workspace with an API client from "
                        + "the Protect console. Its alerts, computers and insights are then "
                        + "collected with the workspace's data."
                )
                PNPButton(title: "Connect Jamf Protect", icon: "link", style: .gold) {
                    showingConnect = true
                }
            }
        }
        .sheet(isPresented: $showingConnect, onDismiss: { reloads += 1 }) {
            ProductConnectSheetView(profileSlug: workspace.profile)
        }
    }

    private var lockedDeepDiveState: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.title3)
                        .foregroundStyle(Theme.Colors.goldBright)
                    Text("Experimental — Protect Deep Dive")
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.fg)
                }
                Text("Kill-chain stage breakdown, per-device alert timeline, and endpoint agent version distribution.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.fgMuted)
                Text("Requires a configured Jamf Protect tenant. Enable in Settings → Experimental Features.")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                if let url = ExperimentalFeatureService.Feature.protect.discussionURL {
                    Link("Learn more \u{2192}", destination: url)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.gold)
                }
            }
        }
    }

    private var killChainStageCard: some View {
        let buckets = ProtectDashboardService.killChainBuckets(snapshot.alerts)
        let total = buckets.reduce(0) { $0 + $1.count }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Kill-Chain Stage")
                if total == 0 {
                    Text("No alert event types to bucket.")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    VStack(spacing: 6) {
                        ForEach(buckets.prefix(8), id: \.stage) { bucket in
                            killChainBar(stage: bucket.stage, count: bucket.count, total: total)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func killChainBar(stage: String, count: Int, total: Int) -> some View {
        let pct = total > 0 ? Double(count) / Double(total) * 100 : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg2)
                    .monospacedDigit()
                Text(String(format: "%.0f%%", pct))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .frame(width: 48, alignment: .trailing)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Colors.hairline)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Colors.goldBright)
                        .frame(width: max(2, geometry.size.width * pct / 100), height: 6)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage): \(count) of \(total), \(Int(pct)) percent")
    }

    private var agentVersionCard: some View {
        let versions = ProtectDashboardService.agentVersionDistribution(snapshot.computers)
        let total = versions.reduce(0) { $0 + $1.count }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Endpoint Agent Versions")
                if total == 0 {
                    Text("No Protect computers reporting agent version.")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    VStack(spacing: 6) {
                        ForEach(versions.prefix(8), id: \.version) { entry in
                            killChainBar(stage: entry.version, count: entry.count, total: total)
                        }
                    }
                }
            }
        }
    }

    private var deviceTimelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Per-Device Alert Timeline")
                let devices = uniqueDeviceIdentifiers
                if devices.isEmpty {
                    Text("No devices with alert history.")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    Picker("Device", selection: Binding(
                        get: { selectedTimelineDevice ?? devices.first ?? "" },
                        set: { selectedTimelineDevice = $0 }
                    )) {
                        ForEach(devices, id: \.self) { device in
                            Text(device).tag(device)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Choose device for alert timeline")
                    let device = selectedTimelineDevice ?? devices.first ?? ""
                    let timeline = ProtectDashboardService.alertTimeline(
                        for: device, in: snapshot.alerts
                    )
                    if timeline.isEmpty {
                        Text("No alerts for \(device).")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(timeline.enumerated()), id: \.offset) { index, alert in
                                alertRow(alert, isLast: index == timeline.count - 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var uniqueDeviceIdentifiers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for alert in snapshot.alerts {
            let key = alert.hostName?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !key.isEmpty, !seen.contains(key.lowercased()) else { continue }
            seen.insert(key.lowercased())
            ordered.append(key)
        }
        return ordered.sorted()
    }

    /// Tiles with and without a caption share a row, so the grid evens each row's height.
    private var kpiGrid: some View {
        EqualHeightTileGrid(minTileWidth: 220) {
            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Total Computers",
                    value: "\(snapshot.totalComputers)",
                    fillsHeight: true
                )
            }

            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Web Protection",
                    value: "\(snapshot.webProtectionActiveCount)",
                    sub: "\(snapshot.webProtectionActiveCount) of \(snapshot.totalComputers) (\(String(format: "%.0f%%", snapshot.totalComputers > 0 ? Double(snapshot.webProtectionActiveCount) / Double(snapshot.totalComputers) * 100 : 0)))",
                    fillsHeight: true
                )
            }

            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Full Disk Access",
                    value: "\(snapshot.fullDiskAccessCount)",
                    sub: "\(snapshot.fullDiskAccessCount) of \(snapshot.totalComputers) (\(String(format: "%.0f%%", snapshot.totalComputers > 0 ? Double(snapshot.fullDiskAccessCount) / Double(snapshot.totalComputers) * 100 : 0)))",
                    fillsHeight: true
                )
            }

            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Connected",
                    value: "\(snapshot.connectedCount)",
                    sub: "\(snapshot.connectedCount) of \(snapshot.totalComputers)",
                    fillsHeight: true
                )
            }

            if !snapshot.alerts.isEmpty {
                StatTile(
                    label: "High Alerts",
                    value: "\(snapshot.highAlerts)",
                    fillsHeight: true
                )
            }

            if snapshot.failingInsights > 0 {
                StatTile(
                    label: "Failing Insights",
                    value: "\(snapshot.failingInsights)",
                    fillsHeight: true
                )
            }
        }
    }

    private var alertsBySeverityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                let totalAlerts = snapshot.highAlerts + snapshot.mediumAlerts
                    + snapshot.lowAlerts + snapshot.informationalAlerts
                HStack {
                    SectionHeader(title: "Alerts by Severity")
                    if totalAlerts > 0 {
                        PNPButton(
                            title: "Export PNG",
                            icon: "square.and.arrow.down",
                            style: .neutral,
                            size: .sm,
                            action: exportAlertSeverityChart
                        )
                        .accessibilityLabel("Export alerts by severity chart as PNG")
                        .help("Save the alerts by severity bar chart as a PNG image")
                    }
                }
                if totalAlerts > 0 {
                    VStack(spacing: 6) {
                        if snapshot.highAlerts > 0 {
                            alertSeverityBar(label: "High", count: snapshot.highAlerts, total: totalAlerts, color: Theme.Severity.high.inApp)
                        }
                        if snapshot.mediumAlerts > 0 {
                            alertSeverityBar(label: "Medium", count: snapshot.mediumAlerts, total: totalAlerts, color: Theme.Severity.medium.inApp)
                        }
                        if snapshot.lowAlerts > 0 {
                            alertSeverityBar(label: "Low", count: snapshot.lowAlerts, total: totalAlerts, color: Theme.Severity.low.inApp)
                        }
                        if snapshot.informationalAlerts > 0 {
                            alertSeverityBar(
                                label: "Informational", count: snapshot.informationalAlerts,
                                total: totalAlerts, color: Theme.Severity.informational.inApp
                            )
                        }
                    }
                }
            }
        }
    }

    private func exportAlertSeverityChart() {
        let high = snapshot.highAlerts
        let medium = snapshot.mediumAlerts
        let low = snapshot.lowAlerts
        let informational = snapshot.informationalAlerts
        let total = high + medium + low + informational
        let result = DashboardChartExport.run(
            title: "Alerts by Severity",
            subtitle: "Jamf Protect",
            footnote: "Source: jamf-cli protect alerts · \(total) alert\(total == 1 ? "" : "s")",
            suggestedFilename: DashboardChartExport.filename(for: "protect-alerts-by-severity", profile: workspace.profile)
        ) {
            ProtectAlertsSeverityExport(
                high: high, medium: medium, low: low, informational: informational
            )
        }
        if case .failure(let error) = result {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    @ViewBuilder
    private func alertSeverityBar(label: String, count: Int, total: Int, color: Color) -> some View {
        let pct = total > 0 ? Double(count) / Double(total) * 100 : 0

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    let icon = severityIcon(for: label)
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                    Text(label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                }
                Spacer()
                Text("\(count)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg2)
                    .monospacedDigit()
                Text(String(format: "%.0f%%", pct))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .frame(width: 48, alignment: .trailing)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Colors.hairline)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, geometry.size.width * pct / 100), height: 6)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) severity alerts: \(count) of \(total) total, \(Int(pct)) percent")
    }

    private var recentAlertsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Recent Alerts",
                    trailing: snapshot.alerts.count > 50
                        ? "Showing 50 of \(snapshot.alerts.count)" : nil)

                let sortedAlerts = snapshot.alerts
                    .sorted { ($0.created ?? "") > ($1.created ?? "") }
                    .prefix(50)

                if !sortedAlerts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(sortedAlerts.enumerated()), id: \.offset) { index, alert in
                            alertRow(alert, isLast: index == sortedAlerts.count - 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func alertRow(_ alert: ProtectAlertRow, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Pills keep their full width, so each column fits its longest label:
                // INFORMATIONAL here, AUTO RESOLVED in the status column.
                severityPill(alert.severity)
                    .frame(width: 124, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.eventType ?? "Unknown")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)

                    if let host = alert.hostName {
                        Text(host)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let created = alert.created {
                    Text(formatCreatedDate(created))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(width: 80, alignment: .trailing)
                }

                statusPill(alert.status)
                    .frame(width: 128, alignment: .trailing)
            }
            .padding(.vertical, 8)

            if !isLast {
                Divider()
                    .background(Theme.Colors.hairline)
            }
        }
    }

    private func severityPill(_ severity: String?) -> some View {
        let text = severity?.capitalized ?? "Unknown"
        let (tone, icon): (Pill.Tone, String) = {
            guard let sev = severity?.lowercased() else { return (.muted, "circle.fill") }
            if sev.contains("high") { return (Theme.Severity.high.pillTone, Theme.Severity.high.systemImage) }
            if sev.contains("medium") || sev.contains("med") { return (Theme.Severity.medium.pillTone, Theme.Severity.medium.systemImage) }
            if sev.contains("low") { return (Theme.Severity.low.pillTone, Theme.Severity.low.systemImage) }
            if sev.hasPrefix("info") {
                let info = Theme.Severity.informational
                return (info.pillTone, info.systemImage)
            }
            return (.muted, "circle.fill")
        }()

        return Pill(text: text, tone: tone, icon: icon)
            .accessibilityLabel("\(text) severity")
    }

    private func statusPill(_ status: String?) -> some View {
        let text = Self.statusLabel(status)
        let (tone, icon): (Pill.Tone, String) = {
            guard let stat = status?.lowercased() else { return (.muted, "info.circle") }
            switch stat {
            case "new": return (.warn, "exclamationmark.circle")
            case "inprogress": return (.gold, "magnifyingglass")
            case "resolved", "autoresolved": return (.teal, "checkmark.circle")
            default: return (.muted, "info.circle")
            }
        }()

        return Pill(text: text, tone: tone, icon: icon)
    }

    /// Status pill text: New/InProgress/Resolved/AutoResolved (Protect's real
    /// ALERT_STATUS values) get a spaced display form; anything else passes
    /// through unchanged; empty/nil is "Unknown".
    nonisolated static func statusLabel(_ status: String?) -> String {
        guard let status, !status.isEmpty else { return "Unknown" }
        switch status.lowercased() {
        case "new": return "New"
        case "inprogress": return "In Progress"
        case "resolved": return "Resolved"
        case "autoresolved": return "Auto Resolved"
        default: return status
        }
    }

    private func severityIcon(for label: String) -> String {
        switch label.lowercased() {
        case "high": Theme.Severity.high.systemImage
        case "medium": Theme.Severity.medium.systemImage
        case "low": Theme.Severity.low.systemImage
        case "informational": Theme.Severity.informational.systemImage
        default: "circle.fill"
        }
    }

    private var computersCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Computers",
                    trailing: snapshot.computers.count > 50
                        ? "Showing 50 of \(snapshot.computers.count)" : nil)

                let displayedComputers = Array(snapshot.computers.prefix(50))

                if !displayedComputers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(displayedComputers.enumerated()), id: \.offset
                        ) { index, computer in
                            computerRow(computer, isLast: index == displayedComputers.count - 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func computerRow(_ computer: ProtectComputerRow, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(computer.hostName ?? "Unknown")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)

                    Text(computer.osString ?? "Unknown OS")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                .frame(width: 140, alignment: .leading)

                Text(computer.planName ?? "—")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .frame(width: 80, alignment: .leading)

                // INACTIVE fits the 92 pt column. UNKNOWN, which both columns can show, is wider
                // than the 56 pt Full Disk Access column and overhangs it; `Pill` is fixed-size,
                // so nothing truncates.
                booleanPill(computer.webProtectionActive, trueLabel: "Active", falseLabel: "Inactive")
                    .frame(width: 92, alignment: .center)
                    .accessibilityLabel("Web Protection " + Self.spokenState(
                        computer.webProtectionActive, trueWord: "active", falseWord: "inactive"))

                booleanPill(computer.fullDiskAccess, trueLabel: "Yes", falseLabel: "No")
                    .frame(width: 56, alignment: .center)
                    .accessibilityLabel("Full Disk Access " + Self.spokenState(
                        computer.fullDiskAccess, trueWord: "granted", falseWord: "denied"))

                connectionPill(computer.connectionStatus)
                    .frame(width: 88, alignment: .center)

                if let lastConnection = computer.lastConnection {
                    Text(formatCreatedDate(lastConnection))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(width: 80, alignment: .trailing)
                }
            }
            .padding(.vertical, 8)

            if !isLast {
                Divider()
                    .background(Theme.Colors.hairline)
            }
        }
    }

    // MARK: - Jamf Pro (or Jamf School) match

    private static let proMatchRowLimit = 50

    @ViewBuilder
    private var proMatchCard: some View {
        switch proMatch {
        case .pending:
            EmptyView()
        case .noInventory(let inventory):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "\(inventory.product) match")
                    matchExperimentalNote(inventory)
                    Text(Self.noInventoryText(inventory))
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        case .ready(let match):
            let product = match.inventory.product
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "\(product) match")
                    matchExperimentalNote(match.inventory)
                    Text(Self.matchSummary(match))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                    ForEach(Self.matchNotes(match), id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Text(Self.matchFootnote)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                    if !match.notInPro.isEmpty {
                        unmatchedList(
                            title: "Not in \(product)", total: match.notInPro.count,
                            rows: match.notInPro.prefix(Self.proMatchRowLimit).map {
                                ($0.hostName ?? "Unknown", $0.serial ?? "—")
                            })
                    }
                    if !match.proWithoutProtect.isEmpty {
                        unmatchedList(
                            title: "\(product) Macs without Protect",
                            total: match.proWithoutProtect.count,
                            rows: match.proWithoutProtect.prefix(Self.proMatchRowLimit).map {
                                ($0.displayName, $0.serial.isEmpty ? "—" : $0.serial)
                            })
                    }
                }
            }
        }
    }

    private func unmatchedList(
        title: String, total: Int, rows: [(name: String, serial: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(
                title: title,
                trailing: total > rows.count ? "Showing \(rows.count) of \(total)" : nil,
                style: .headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    Text(row.name)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)
                    Spacer()
                    Text(row.serial)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    @ViewBuilder
    private func matchExperimentalNote(_ inventory: ProtectProCorrelation.Inventory) -> some View {
        if inventory == .jamfSchool {
            Text(Self.schoolMatchExperimentalText)
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    nonisolated static let schoolMatchExperimentalText =
        "Experimental: Jamf Protect with Jamf School."

    nonisolated static func noInventoryText(
        _ inventory: ProtectProCorrelation.Inventory
    ) -> String {
        "Collect \(inventory.product) inventory to match Protect computers to "
            + "\(inventory.product)."
    }
    nonisolated static let matchFootnote =
        "Matched by hardware UUID or serial number, never by name."

    nonisolated static func matchSummary(_ match: ProtectProCorrelation) -> String {
        let many = match.protectCount != 1
        return "\(match.matched) of \(match.protectCount) Protect computer\(many ? "s" : "") "
            + "match\(many ? "" : "es") a \(match.inventory.product) computer."
    }

    /// One line per nonzero count, singular or plural.
    nonisolated static func matchNotes(_ match: ProtectProCorrelation) -> [String] {
        func protectLine(_ count: Int, one: String, many: String) -> String? {
            count == 0 ? nil : "\(count) Protect computer\(count == 1 ? " " + one : "s " + many)"
        }
        let proCount = match.proWithoutProtect.count
        let product = match.inventory.product
        return [
            protectLine(match.notInPro.count, one: "has no \(product) record.",
                        many: "have no \(product) record."),
            proCount == 0 ? nil : "\(proCount) \(product) Mac\(proCount == 1 ? " has" : "s have") "
                + "no Protect record.",
            protectLine(match.ambiguous,
                        one: "matches more than one \(product) computer and is not counted.",
                        many: "match more than one \(product) computer and are not counted."),
            protectLine(match.noIdentifier, one: "reports no UUID or serial.",
                        many: "report no UUID or serial."),
        ].compactMap { $0 }
    }

    private func booleanPill(_ value: Bool?, trueLabel: String, falseLabel: String) -> some View {
        let state = Self.statePill(value, trueLabel: trueLabel, falseLabel: falseLabel)
        return Pill(text: state.text, tone: state.tone, icon: state.icon)
    }

    /// Protect omits a field it has no value for, so nil is "not reported", not the negative label.
    static func statePill(
        _ value: Bool?, trueLabel: String, falseLabel: String
    ) -> (text: String, tone: Pill.Tone, icon: String?) {
        switch value {
        case true?: return (trueLabel, .teal, "checkmark")
        case false?: return (falseLabel, .muted, "xmark")
        // No icon: the word alone is wider than the narrow Full Disk Access column.
        case nil: return ("Unknown", .muted, nil)
        }
    }

    /// VoiceOver wording for the same tri-state.
    static func spokenState(_ value: Bool?, trueWord: String, falseWord: String) -> String {
        switch value {
        case true?: return trueWord
        case false?: return falseWord
        case nil: return "unknown"
        }
    }

    private func connectionPill(_ status: String?) -> some View {
        let isConnected = ProtectDashboardService.isConnected(status)
        return Pill(
            text: isConnected ? "Online" : "Offline",
            tone: isConnected ? .teal : .warn
        )
        .accessibilityLabel("\(isConnected ? "Online" : "Offline") connection status")
    }

    private var insightsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Insights")

                VStack(spacing: 8) {
                    ForEach(Array(snapshot.insights.enumerated()), id: \.offset) { index, insight in
                        insightRow(insight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func insightRow(_ insight: ProtectInsightRow) -> some View {
        let pass = insight.totalPass ?? 0
        let fail = insight.totalFail ?? 0
        let total = pass + fail

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(insight.label ?? "Unknown Insight")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)

                Spacer()

                if let enabled = insight.enabled {
                    Pill(text: enabled ? "Enabled" : "Disabled", tone: enabled ? .teal : .muted)
                }
            }

            if let section = insight.section {
                Text(section)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }

            if total > 0 {
                HStack(spacing: 4) {
                    Text("Pass: \(pass)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Colors.teal)

                    Text("•")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Colors.hairlineStrong)

                    Text("Fail: \(fail)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(fail > 0 ? Theme.Colors.warn : Theme.Text.tertiary(contrast))

                    Spacer()

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.Colors.hairline)
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.Colors.teal)
                                .frame(width: max(2, geometry.size.width * Double(pass) / Double(total)), height: 4)
                        }
                    }
                    .frame(width: 60, height: 4)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(insight.label ?? "Unknown insight"), \(pass) pass, \(fail) fail")
    }

    // MARK: - Plans

    private var plansCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Plans")
                    Spacer()
                    Pill(text: "\(snapshot.plans.count) plan\(snapshot.plans.count == 1 ? "" : "s")",
                         tone: .muted)
                }
                VStack(spacing: 8) {
                    ForEach(Array(snapshot.plans.enumerated()), id: \.offset) { _, plan in
                        planRow(plan)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func planRow(_ plan: ProtectPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(plan.name ?? "Unnamed Plan")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
            }
            HStack(spacing: 10) {
                if let level = plan.logLevel, !level.isEmpty {
                    planTag("Log: \(level)")
                }
                planTag(plan.autoUpdate == true ? "Auto-update on" : "Auto-update off")
                planTag(Self.telemetryTag(plan.telemetry))
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(plan.name ?? "Unnamed plan"), \(Self.telemetryTag(plan.telemetry))")
    }

    /// Plan card telemetry tag: the assigned configuration's name, or "No telemetry".
    nonisolated static func telemetryTag(_ telemetry: String?) -> String {
        guard let telemetry, !telemetry.isEmpty else { return "No telemetry" }
        return "Telemetry: \(telemetry)"
    }

    private func planTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(Theme.Text.tertiary(contrast))
    }

    // MARK: - Utilities

    private func formatCreatedDate(_ dateString: String) -> String {
        let date: Date
        if let parsedDate = Self.isoFractionalFormatter.date(from: dateString) {
            date = parsedDate
        } else {
            // Fallback for simpler ISO format
            guard let fallbackDate = Self.isoFormatter.date(from: dateString) else {
                return "Unknown"
            }
            date = fallbackDate
        }

        // Demo ages are measured from the demo's own "now", not today's date.
        let now = workspace.demoMode ? DemoData.referenceDate : Date()
        let daysSince = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0

        if daysSince >= 60 {
            // For spans ≥60 days, use absolute date
            return Self.dayFormatter.string(from: date)
        } else {
            // For spans <60 days, use relative formatting
            return Self.relativeFormatter.localizedString(for: date, relativeTo: now)
        }
    }

    // Built once: this runs per table row. Each is configured at creation and never mutated
    // after, so sharing is safe.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // A formatter built per call read the zone at that moment; this one follows changes.
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Export-only chart

/// Light-mode export rendering of the Protect alert severity bars. Hardcodes
/// light-mode-legible severity colors (orange/gold/teal/gray) — the
/// in-dashboard view uses Theme tokens which read poorly on the light export
/// canvas.
private struct ProtectAlertsSeverityExport: View {
    let high: Int
    let medium: Int
    let low: Int
    let informational: Int

    private struct Row: Identifiable {
        let label: String
        let count: Int
        let color: Color
        var id: String { label }
    }

    private var rows: [Row] {
        [
            Row(label: "High",          count: high,          color: Theme.Severity.high.export),
            Row(label: "Medium",        count: medium,        color: Theme.Severity.medium.export),
            Row(label: "Low",           count: low,           color: Theme.Severity.low.export),
            Row(label: "Informational", count: informational,
                color: Theme.Severity.informational.export)
        ].filter { $0.count > 0 }
    }

    private var total: Int { high + medium + low + informational }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                let pct = total > 0 ? Double(row.count) / Double(total) * 100 : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Chart.textPrimary)
                        Spacer(minLength: 6)
                        Text("\(row.count)")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(Theme.Chart.textPrimary)
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", pct))
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Chart.textSecondary)
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.Chart.borders)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(row.color)
                                .frame(width: max(2, geo.size.width * pct / 100))
                        }
                    }
                    .frame(height: 10)
                }
            }
            if total > 0 {
                HStack {
                    Spacer()
                    Text("Total: \(total) alert\(total == 1 ? "" : "s")")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(Theme.Chart.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}