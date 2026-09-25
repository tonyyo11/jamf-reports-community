import SwiftUI
import Charts

/// Jamf Protect telemetry dashboard. Surfaces overview KPIs, alerts, computer
/// agent health, and insights from `jamf-cli protect *` snapshots. Renders a
/// clear empty state when no Protect data exists (many tenants don't run Protect).
struct ProtectView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: ProtectDashboardService.Snapshot = .empty
    @State private var hasLoaded = false
    @State private var experimentalFeatures = ExperimentalFeatureService()
    @State private var selectedTimelineDevice: String?

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

            // Shared StaleDataBanner surfaces snapshot freshness above the main content.
            // Suppressed in demo mode (the demo dataset is intentionally static and
            // not user-perceivably "stale"). Renders nothing when source is .fresh.
            if !workspace.demoMode {
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

            if !deepDiveEnabled {
                lockedDeepDiveState
            }
            if !snapshot.isDetected {
                emptyState
            } else {
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
                }
                if !snapshot.insights.isEmpty {
                    insightsCard
                }
                if !snapshot.plans.isEmpty {
                    plansCard
                }
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

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

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    private func reload() {
        // The demo's rows are drawn by the same code as a live tenant's, and its
        // counts are taken from those rows.
        snapshot = workspace.demoMode
            ? DemoData.protectSnapshot
            : ProtectDashboardService.load(profile: workspace.profile)
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "shield.lefthalf.filled",
                title: "No Jamf Protect data detected",
                message: "No Jamf Protect data detected in this workspace. Run the following commands to collect Protect telemetry:",
                commands: [
                    "`jamf-cli protect overview`",
                    "`jamf-cli protect alerts list`",
                    "`jamf-cli protect computers list`",
                    "`jamf-cli protect insights list`"
                ]
            )
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

                // Wide enough for INACTIVE and YES, the longest labels these pills show.
                booleanPill(computer.webProtectionActive, trueLabel: "Active", falseLabel: "Inactive")
                    .frame(width: 92, alignment: .center)
                    .accessibilityLabel("Web Protection \(computer.webProtectionActive == true ? "active" : "inactive")")

                booleanPill(computer.fullDiskAccess, trueLabel: "Yes", falseLabel: "No")
                    .frame(width: 56, alignment: .center)
                    .accessibilityLabel("Full Disk Access \(computer.fullDiskAccess == true ? "granted" : "denied")")

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

    private func booleanPill(_ value: Bool?, trueLabel: String, falseLabel: String) -> some View {
        let isTrue = value == true
        return Pill(
            text: isTrue ? trueLabel : falseLabel,
            tone: isTrue ? .teal : .muted,
            icon: isTrue ? "checkmark" : "xmark"
        )
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let date: Date
        if let parsedDate = formatter.date(from: dateString) {
            date = parsedDate
        } else {
            // Fallback for simpler ISO format
            formatter.formatOptions = [.withInternetDateTime]
            guard let fallbackDate = formatter.date(from: dateString) else {
                return "Unknown"
            }
            date = fallbackDate
        }

        // Demo ages are measured from the demo's own "now", not today's date.
        let now = workspace.demoMode ? DemoData.referenceDate : Date()
        let daysSince = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0

        if daysSince >= 60 {
            // For spans ≥60 days, use absolute date
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        } else {
            // For spans <60 days, use relative formatting
            let relativeFormatter = RelativeDateTimeFormatter()
            relativeFormatter.unitsStyle = .abbreviated
            return relativeFormatter.localizedString(for: date, relativeTo: now)
        }
    }
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