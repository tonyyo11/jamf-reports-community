import SwiftUI
import Charts

/// Jamf Protect telemetry dashboard. Surfaces overview KPIs, alerts, computer
/// agent health, and insights from `jamf-cli protect *` snapshots. Renders a
/// clear empty state when no Protect data exists (many tenants don't run Protect).
struct ProtectView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot: ProtectDashboardService.Snapshot = .empty
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    kicker: "Protect",
                    title: "Jamf Protect",
                    subtitle: subtitle,
                    lastModified: snapshot.snapshotDate
                )

                if !snapshot.isDetected {
                    emptyState
                } else {
                    if snapshot.totalComputers > 0 || !snapshot.alerts.isEmpty || !snapshot.insights.isEmpty || workspace.demoMode {
                        kpiGrid
                    }
                    if !snapshot.alerts.isEmpty || workspace.demoMode {
                        alertsBySeverityCard
                        recentAlertsCard
                    }
                    if !snapshot.computers.isEmpty || workspace.demoMode {
                        computersCard
                    }
                    if !snapshot.insights.isEmpty || workspace.demoMode {
                        insightsCard
                    }
                }
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
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
        let parts: [String] = [
            snapshot.totalComputers > 0 ? "\(snapshot.totalComputers) computer\(snapshot.totalComputers == 1 ? "" : "s")" : nil,
            !snapshot.alerts.isEmpty ? "\(snapshot.alerts.count) alert\(snapshot.alerts.count == 1 ? "" : "s")" :
                (snapshot.criticalAlerts + snapshot.highAlerts + snapshot.mediumAlerts + snapshot.lowAlerts > 0 ?
                 "\(snapshot.criticalAlerts + snapshot.highAlerts + snapshot.mediumAlerts + snapshot.lowAlerts) alert\(snapshot.criticalAlerts + snapshot.highAlerts + snapshot.mediumAlerts + snapshot.lowAlerts == 1 ? "" : "s")" : nil),
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
        snapshot = workspace.demoMode
            ? Self.demoSnapshot
            : ProtectDashboardService.load(profile: workspace.profile)
    }

    private static let demoSnapshot = ProtectDashboardService.Snapshot(
        isDetected: true,
        overviewItems: [],
        alerts: [],
        computers: [],
        insights: [],
        totalComputers: 12,
        webProtectionActiveCount: 10,
        fullDiskAccessCount: 9,
        connectedCount: 10,
        criticalAlerts: 2,
        highAlerts: 2,
        mediumAlerts: 2,
        lowAlerts: 2,
        failingInsights: 3,
        sourceFile: nil,
        snapshotDate: Date()
    )

    // MARK: - Demo Data Helpers

    private static let demoDemoAlerts: [(severity: String, eventType: String, hostName: String, created: String, status: String)] = [
            ("Critical", "Malware", "MacBook-001", "2024-05-12T09:30:00Z", "Open"),
            ("High", "Suspicious Network", "MacBook-002", "2024-05-12T08:15:00Z", "Investigating"),
            ("Medium", "Policy Violation", "iMac-003", "2024-05-11T16:45:00Z", "Resolved"),
            ("Low", "Anomaly", "MacBook-004", "2024-05-11T14:20:00Z", "Closed"),
            ("Critical", "Ransomware", "MacBook-005", "2024-05-11T11:30:00Z", "Open"),
            ("High", "Data Exfil", "iMac-006", "2024-05-11T10:00:00Z", "Investigating"),
            ("Medium", "Unauthorized Access", "MacBook-007", "2024-05-10T18:30:00Z", "Open"),
            ("Low", "Config Change", "iMac-008", "2024-05-10T15:45:00Z", "Resolved")
        ]

    private static let demoDemoComputers: [(hostName: String, osString: String, planName: String, webProtection: Bool, fullDisk: Bool, connected: Bool, lastConnection: String)] = [
            ("MacBook-001", "macOS 15.4.1", "Standard", true, true, true, "2024-05-12T10:00:00Z"),
            ("MacBook-002", "macOS 15.4.1", "Standard", true, true, true, "2024-05-12T09:45:00Z"),
            ("iMac-003", "macOS 14.7.5", "Standard", true, false, true, "2024-05-12T09:30:00Z"),
            ("MacBook-004", "macOS 15.4.1", "Standard", false, true, false, "2024-05-10T14:20:00Z"),
            ("MacBook-005", "macOS 15.4.1", "Premium", true, true, true, "2024-05-12T10:05:00Z"),
            ("iMac-006", "macOS 14.7.5", "Premium", true, true, true, "2024-05-12T09:50:00Z"),
            ("MacBook-007", "macOS 13.7.10", "Standard", true, false, true, "2024-05-12T08:30:00Z"),
            ("iMac-008", "macOS 15.4.1", "Standard", false, false, false, "2024-05-09T16:15:00Z"),
            ("MacBook-009", "macOS 15.4.1", "Premium", true, true, true, "2024-05-12T10:10:00Z"),
            ("iMac-010", "macOS 14.7.5", "Standard", true, true, true, "2024-05-12T09:25:00Z"),
            ("MacBook-011", "macOS 15.4.1", "Standard", true, true, true, "2024-05-12T10:15:00Z"),
            ("MacBook-012", "macOS 15.4.1", "Premium", true, true, true, "2024-05-12T09:55:00Z")
        ]

    private static let demoDemoInsights: [(label: String, section: String, totalPass: Int, totalFail: Int, enabled: Bool)] = [
            ("Firewall Configuration", "Network Security", 10, 2, true),
            ("FileVault Status", "Data Protection", 12, 0, true),
            ("Gatekeeper Policy", "Application Security", 11, 1, true),
            ("SIP Status", "System Integrity", 12, 0, true),
            ("XProtect Updates", "Malware Protection", 9, 3, false),
            ("Certificate Validation", "PKI", 11, 1, true)
        ]

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

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)], spacing: 16) {
            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Total Computers",
                    value: "\(snapshot.totalComputers)"
                )
            }

            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Web Protection",
                    value: "\(snapshot.webProtectionActiveCount)",
                    sub: "\(snapshot.webProtectionActiveCount) of \(snapshot.totalComputers) (\(String(format: "%.0f%%", snapshot.totalComputers > 0 ? Double(snapshot.webProtectionActiveCount) / Double(snapshot.totalComputers) * 100 : 0)))"
                )
            }

            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Full Disk Access",
                    value: "\(snapshot.fullDiskAccessCount)",
                    sub: "\(snapshot.fullDiskAccessCount) of \(snapshot.totalComputers) (\(String(format: "%.0f%%", snapshot.totalComputers > 0 ? Double(snapshot.fullDiskAccessCount) / Double(snapshot.totalComputers) * 100 : 0)))"
                )
            }

            if snapshot.totalComputers > 0 {
                StatTile(
                    label: "Connected",
                    value: "\(snapshot.connectedCount)",
                    sub: "\(snapshot.connectedCount) of \(snapshot.totalComputers)"
                )
            }

            if !snapshot.alerts.isEmpty {
                StatTile(
                    label: "Critical Alerts",
                    value: "\(snapshot.criticalAlerts)"
                )
            }

            if snapshot.failingInsights > 0 {
                StatTile(
                    label: "Failing Insights",
                    value: "\(snapshot.failingInsights)"
                )
            }
        }
    }

    private var alertsBySeverityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                let totalAlerts = snapshot.criticalAlerts + snapshot.highAlerts + snapshot.mediumAlerts + snapshot.lowAlerts
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
                        if snapshot.criticalAlerts > 0 {
                            alertSeverityBar(label: "Critical", count: snapshot.criticalAlerts, total: totalAlerts, color: Theme.Severity.critical.inApp)
                        }
                        if snapshot.highAlerts > 0 {
                            alertSeverityBar(label: "High", count: snapshot.highAlerts, total: totalAlerts, color: Theme.Severity.high.inApp)
                        }
                        if snapshot.mediumAlerts > 0 {
                            alertSeverityBar(label: "Medium", count: snapshot.mediumAlerts, total: totalAlerts, color: Theme.Severity.medium.inApp)
                        }
                        if snapshot.lowAlerts > 0 {
                            alertSeverityBar(label: "Low", count: snapshot.lowAlerts, total: totalAlerts, color: Theme.Severity.low.inApp)
                        }
                    }
                }
            }
        }
    }

    private func exportAlertSeverityChart() {
        let critical = snapshot.criticalAlerts
        let high = snapshot.highAlerts
        let medium = snapshot.mediumAlerts
        let low = snapshot.lowAlerts
        let total = critical + high + medium + low
        let result = DashboardChartExport.run(
            title: "Alerts by Severity",
            subtitle: "Jamf Protect",
            footnote: "Source: jamf-cli protect alerts · \(total) alert\(total == 1 ? "" : "s")",
            suggestedFilename: DashboardChartExport.filename(for: "protect-alerts-by-severity")
        ) {
            ProtectAlertsSeverityExport(critical: critical, high: high, medium: medium, low: low)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                }
                Spacer()
                Text("\(count)")
                    .font(Theme.Fonts.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fg2)
                    .monospacedDigit()
                Text(String(format: "%.0f%%", pct))
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
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
                SectionHeader(title: "Recent Alerts", trailing: workspace.demoMode ? nil : (snapshot.alerts.count > 50 ? "Showing 50 of \(snapshot.alerts.count)" : nil))

                if workspace.demoMode {
                    VStack(spacing: 0) {
                        ForEach(Array(Self.demoDemoAlerts.enumerated()), id: \.offset) { index, alert in
                            demoAlertRow(alert, isLast: index == Self.demoDemoAlerts.count - 1)
                        }
                    }
                } else {
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
    }

    @ViewBuilder
    private func alertRow(_ alert: ProtectAlertRow, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                severityPill(alert.severity)
                    .frame(width: 72, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.eventType ?? "Unknown")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)

                    if let host = alert.hostName {
                        Text(host)
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let created = alert.created {
                    Text(formatCreatedDate(created))
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .frame(width: 80, alignment: .trailing)
                }

                statusPill(alert.status)
                    .frame(width: 104, alignment: .trailing)
            }
            .padding(.vertical, 8)

            if !isLast {
                Divider()
                    .background(Theme.Colors.hairline)
            }
        }
    }

    @ViewBuilder
    private func demoAlertRow(_ alert: (severity: String, eventType: String, hostName: String, created: String, status: String), isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                severityPill(alert.severity)
                    .frame(width: 72, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.eventType)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)

                    Text(alert.hostName)
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatCreatedDate(alert.created))
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 80, alignment: .trailing)

                statusPill(alert.status)
                    .frame(width: 104, alignment: .trailing)
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
            if sev.contains("critical") { return (Theme.Severity.critical.pillTone, Theme.Severity.critical.systemImage) }
            if sev.contains("high") { return (Theme.Severity.high.pillTone, Theme.Severity.high.systemImage) }
            if sev.contains("medium") || sev.contains("med") { return (Theme.Severity.medium.pillTone, Theme.Severity.medium.systemImage) }
            if sev.contains("low") { return (Theme.Severity.low.pillTone, Theme.Severity.low.systemImage) }
            return (.muted, "circle.fill")
        }()

        return Pill(text: text, tone: tone, icon: icon)
            .accessibilityLabel("\(text) severity")
    }

    private func statusPill(_ status: String?) -> some View {
        let text = status?.capitalized ?? "Unknown"
        let (tone, icon): (Pill.Tone, String) = {
            guard let stat = status?.lowercased() else { return (.muted, "info.circle") }
            if stat.contains("resolved") { return (.teal, "checkmark.circle") }
            if stat.contains("closed") { return (.teal, "checkmark") }
            if stat.contains("open") { return (.warn, "exclamationmark.circle") }
            if stat.contains("investigating") { return (.gold, "magnifyingglass") }
            return (.muted, "info.circle")
        }()

        return Pill(text: text, tone: tone, icon: icon)
    }

    private func severityIcon(for label: String) -> String {
        switch label.lowercased() {
        case "critical": Theme.Severity.critical.systemImage
        case "high": Theme.Severity.high.systemImage
        case "medium": Theme.Severity.medium.systemImage
        case "low": Theme.Severity.low.systemImage
        default: "circle.fill"
        }
    }

    private var computersCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Computers", trailing: workspace.demoMode ? nil : (snapshot.computers.count > 50 ? "Showing 50 of \(snapshot.computers.count)" : nil))

                if workspace.demoMode {
                    VStack(spacing: 0) {
                        ForEach(Array(Self.demoDemoComputers.enumerated()), id: \.offset) { index, computer in
                            demoComputerRow(computer, isLast: index == Self.demoDemoComputers.count - 1)
                        }
                    }
                } else {
                    let displayedComputers = Array(snapshot.computers.prefix(50))

                    if !displayedComputers.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(displayedComputers.enumerated()), id: \.offset) { index, computer in
                                computerRow(computer, isLast: index == displayedComputers.count - 1)
                            }
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)

                    Text(computer.osString ?? "Unknown OS")
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .frame(width: 140, alignment: .leading)

                Text(computer.planName ?? "—")
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 80, alignment: .leading)

                booleanPill(computer.webProtectionActive, trueLabel: "Active", falseLabel: "Inactive")
                    .frame(width: 64, alignment: .center)
                    .accessibilityLabel("Web Protection \(computer.webProtectionActive == true ? "active" : "inactive")")

                booleanPill(computer.fullDiskAccess, trueLabel: "Yes", falseLabel: "No")
                    .frame(width: 48, alignment: .center)
                    .accessibilityLabel("Full Disk Access \(computer.fullDiskAccess == true ? "granted" : "denied")")

                connectionPill(computer.connectionStatus)
                    .frame(width: 88, alignment: .center)

                if let lastConnection = computer.lastConnection {
                    Text(formatCreatedDate(lastConnection))
                        .font(Theme.Fonts.mono(9.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
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

    @ViewBuilder
    private func demoComputerRow(_ computer: (hostName: String, osString: String, planName: String, webProtection: Bool, fullDisk: Bool, connected: Bool, lastConnection: String), isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(computer.hostName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)

                    Text(computer.osString)
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .frame(width: 140, alignment: .leading)

                Text(computer.planName)
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 80, alignment: .leading)

                demoBooleanPill(computer.webProtection, trueLabel: "Active", falseLabel: "Inactive")
                    .frame(width: 64, alignment: .center)
                    .accessibilityLabel("Web Protection \(computer.webProtection ? "active" : "inactive")")

                demoBooleanPill(computer.fullDisk, trueLabel: "Yes", falseLabel: "No")
                    .frame(width: 48, alignment: .center)
                    .accessibilityLabel("Full Disk Access \(computer.fullDisk ? "granted" : "denied")")

                Pill(
                    text: computer.connected ? "Online" : "Offline",
                    tone: computer.connected ? .teal : .warn
                )
                .frame(width: 88, alignment: .center)
                .accessibilityLabel("\(computer.connected ? "Online" : "Offline") connection status")

                Text(formatCreatedDate(computer.lastConnection))
                    .font(Theme.Fonts.mono(9.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 80, alignment: .trailing)
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

    private func demoBooleanPill(_ value: Bool, trueLabel: String, falseLabel: String) -> some View {
        return Pill(
            text: value ? trueLabel : falseLabel,
            tone: value ? .teal : .muted,
            icon: value ? "checkmark" : "xmark"
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
                    if workspace.demoMode {
                        ForEach(Array(Self.demoDemoInsights.enumerated()), id: \.offset) { index, insight in
                            demoInsightRow(insight)
                        }
                    } else {
                        ForEach(Array(snapshot.insights.enumerated()), id: \.offset) { index, insight in
                            insightRow(insight)
                        }
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg)

                Spacer()

                if let enabled = insight.enabled {
                    Pill(text: enabled ? "Enabled" : "Disabled", tone: enabled ? .teal : .muted)
                }
            }

            if let section = insight.section {
                Text(section)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }

            if total > 0 {
                HStack(spacing: 4) {
                    Text("Pass: \(pass)")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.teal)

                    Text("•")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.hairlineStrong)

                    Text("Fail: \(fail)")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(fail > 0 ? Theme.Colors.warn : Theme.Colors.fgMuted)

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

    @ViewBuilder
    private func demoInsightRow(_ insight: (label: String, section: String, totalPass: Int, totalFail: Int, enabled: Bool)) -> some View {
        let pass = insight.totalPass
        let fail = insight.totalFail
        let total = pass + fail

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(insight.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg)

                Spacer()

                Pill(text: insight.enabled ? "Enabled" : "Disabled", tone: insight.enabled ? .teal : .muted)
            }

            Text(insight.section)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Colors.fgMuted)

            if total > 0 {
                HStack(spacing: 4) {
                    Text("Pass: \(pass)")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.teal)

                    Text("•")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.hairlineStrong)

                    Text("Fail: \(fail)")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(fail > 0 ? Theme.Colors.warn : Theme.Colors.fgMuted)

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
        .accessibilityLabel("\(insight.label), \(pass) pass, \(fail) fail")
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

        let now = Date()
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

// MARK: - Helper extension for service access in view
private extension ProtectDashboardService {
    /// Expose the connection check for use in view logic
    static func isConnected(_ status: String?) -> Bool {
        guard let status else { return false }
        let lower = status.lowercased()
        return lower.contains("connected") || lower.contains("online")
    }
}

// MARK: - Export-only chart

/// Light-mode export rendering of the Protect alert severity bars. Hardcodes
/// light-mode-legible severity colors (red/orange/gold/teal) — the
/// in-dashboard view uses Theme tokens which read poorly on the light export
/// canvas.
private struct ProtectAlertsSeverityExport: View {
    let critical: Int
    let high: Int
    let medium: Int
    let low: Int

    private struct Row: Identifiable {
        let label: String
        let count: Int
        let color: Color
        var id: String { label }
    }

    private var rows: [Row] {
        [
            Row(label: "Critical", count: critical, color: Theme.Severity.critical.export),
            Row(label: "High",     count: high,     color: Theme.Severity.high.export),
            Row(label: "Medium",   count: medium,   color: Theme.Severity.medium.export),
            Row(label: "Low",      count: low,      color: Theme.Severity.low.export)
        ].filter { $0.count > 0 }
    }

    private var total: Int { critical + high + medium + low }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                let pct = total > 0 ? Double(row.count) / Double(total) * 100 : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x111827))
                        Spacer(minLength: 6)
                        Text("\(row.count)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", pct))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: 0xE2E8F0))
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
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x475569))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}