import SwiftUI

struct ConfigView: View {
    @Environment(WorkspaceStore.self) private var workspace

    enum ConfigTab: String, CaseIterable {
        case columns, agents, eas, thresholds, platform, output
        var label: String {
            switch self {
            case .columns:    "Columns"
            case .agents:     "Security Agents"
            case .eas:        "Custom EAs"
            case .thresholds: "Thresholds"
            case .platform:   "Platform API"
            case .output:     "Output"
            }
        }
        var icon: String {
            switch self {
            case .columns:    "internaldrive"
            case .agents:     "shield"
            case .eas:        "sparkles"
            case .thresholds: "bolt"
            case .platform:   "arrow.triangle.branch"
            case .output:     "folder"
            }
        }
    }

    @State private var tab: ConfigTab = .columns

    // Output tab state
    @State private var outputDir: String = "Generated Reports"
    @State private var timestampOutputs: Bool = true
    @State private var autoArchive: Bool = true
    @State private var orgName: String = ""
    @State private var accentColor: String = "#C9970A"
    @State private var accentDark: String = "#8E6B06"

    // Thresholds tab state
    @State private var staleDeviceDays: String = "30"
    @State private var warnDiskPct: String = "80"
    @State private var critDiskPct: String = "90"
    @State private var certWarningDays: String = "90"
    @State private var baselineLabel: String = "NIST 800-53r5 Moderate"
    @State private var failuresCountCol: String = "Compliance - Failed mSCP Results Count - NIST 800-53r5"
    @State private var failuresListCol: String = "Compliance - Failed mSCP Result List - NIST 800-53r5"
    @State private var complianceEnabled: Bool = true

    // Platform tab state
    @State private var platformEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                SegmentedControl(
                    selection: $tab,
                    options: ConfigTab.allCases.map { ($0, $0.label, $0.icon) }
                )
                tabContent
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Workspace · \(workspace.org.profile)",
            title: "config.yaml",
            subtitle: "~/Jamf-Reports/\(workspace.org.profile)/config.yaml · last edited 2 hr ago"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "View YAML", icon: "chevron.left.forwardslash.chevron.right")
                    PNPButton(title: "Run check", icon: "flask")
                    PNPButton(title: "Save", icon: "checkmark", style: .gold)
                }
            )
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .columns:    columnsTab
        case .agents:     agentsTab
        case .eas:        easTab
        case .thresholds: thresholdsTab
        case .platform:   platformTab
        case .output:     outputTab
        }
    }

    // MARK: Columns tab

    private var columnsTab: some View {
        HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader(title: "CSV Column Mappings")
                        Spacer()
                        Pill(
                            text: "\(workspace.columnMappings.filter { $0.status == .ok }.count) OK · "
                                + "\(workspace.columnMappings.filter { $0.status == .warn }.count) WARN",
                            tone: .teal,
                            icon: "checkmark"
                        )
                    }
                    .padding(.bottom, 8)

                    let csvName = "meridian_export_2026-04-25.csv"
                    HStack(spacing: 4) {
                        Text("Mapping logical fields → headers in")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                        Mono(text: csvName, size: 11.5, color: Theme.Colors.fg2)
                    }
                    .padding(.bottom, 12)

                    VStack(spacing: 0) {
                        ForEach(workspace.columnMappings) { mapping in
                            ColumnFieldRow(mapping: mapping)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                validationCard
                scaffoldTipCard
            }
            .frame(width: 240)
        }
    }

    private var validationCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Validation")
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 10) {
                    validationRow(
                        icon: "checkmark.circle.fill",
                        color: Theme.Colors.ok,
                        title: "\(workspace.columnMappings.filter { $0.status == .ok }.count) columns mapped",
                        detail: "All required fields present"
                    )
                    validationRow(
                        icon: "exclamationmark.triangle.fill",
                        color: Theme.Colors.warn,
                        title: nil,
                        monoTitle: "bootstrap_token",
                        titleSuffix: " column not found",
                        detail: "Try \"Bootstrap Token Escrow\" — sheet will skip."
                    )
                    validationRow(
                        icon: "info.circle",
                        color: Theme.Colors.fgMuted,
                        title: nil,
                        monoTitle: "manager",
                        titleSuffix: " intentionally unmapped",
                        detail: "No EA in CSV; supervisor sheet skipped."
                    )
                }

                Divider()
                    .background(Theme.Colors.hairline)
                    .padding(.vertical, 12)

                HStack(spacing: 6) {
                    PNPButton(title: "Re-check", icon: "arrow.clockwise", size: .sm)
                    PNPButton(title: "Open CSV", icon: "arrow.up.right.square", style: .ghost, size: .sm)
                }
            }
        }
    }

    private func validationRow(
        icon: String,
        color: Color,
        title: String?,
        monoTitle: String? = nil,
        titleSuffix: String? = nil,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                } else {
                    HStack(spacing: 0) {
                        if let mono = monoTitle {
                            Mono(text: mono, size: 12, color: Theme.Colors.fg)
                        }
                        if let suffix = titleSuffix {
                            Text(suffix)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.Colors.fg)
                        }
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    private var scaffoldTipCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Tip")
                Text("Run ")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fg2)
                + Text("scaffold")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fg2)
                + Text(" to auto-detect columns from any new CSV export. Existing config is preserved where possible.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fg2)
                PNPButton(title: "Re-scaffold from CSV", icon: "bolt", style: .gold, size: .sm)
            }
        }
    }

    // MARK: Security Agents tab

    private var agentsTab: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Security Agents")
                    Spacer()
                    PNPButton(title: "Add agent", icon: "plus", style: .gold, size: .sm)
                }
                agentsTable
            }
        }
    }

    private var agentsTable: some View {
        VStack(spacing: 0) {
            agentsHeader
            Divider().background(Theme.Colors.hairline)
            ForEach(DemoData.securityAgents) { agent in
                agentRow(agent)
                if agent.id != DemoData.securityAgents.last?.id {
                    Divider().background(Theme.Colors.hairline)
                }
            }
        }
        .background(Color.white.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
    }

    private var agentsHeader: some View {
        HStack(spacing: 0) {
            tableHeaderCell("Agent Name",      width: nil)
            tableHeaderCell("EA Column",       width: nil)
            tableHeaderCell("Connected Value", width: 140)
            tableHeaderCell("Install Rate",    width: 160)
            Spacer().frame(width: 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tableHeaderCell(_ title: String, width: CGFloat?) -> some View {
        Text(title)
            .font(Theme.Fonts.mono(10.5, weight: .semibold))
            .foregroundStyle(Theme.Colors.fgMuted)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
    }

    private func agentRow(_ agent: SecurityAgent) -> some View {
        HStack(spacing: 0) {
            Text(agent.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
            Mono(text: agent.column, size: 11.5, color: Theme.Colors.fg2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Mono(text: "Installed", size: 11.5, color: Theme.Colors.fg2)
                .frame(width: 140, alignment: .leading)
            agentBar(agent.pct)
                .frame(width: 160)
            PNPButton(title: "", icon: "ellipsis", style: .ghost, size: .sm)
                .frame(width: 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func agentBar(_ pct: Double) -> some View {
        let barColor: Color = pct > 90 ? Theme.Colors.ok : Theme.Colors.gold
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.05)).frame(width: 80, height: 4)
                Capsule().fill(barColor).frame(width: 80 * pct / 100, height: 4)
            }
            Text(String(format: "%.0f%%", pct))
                .font(Theme.Fonts.mono(11.5, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Custom EAs tab

    private var easTab: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Custom Extension Attribute Sheets")
                    Spacer()
                    PNPButton(title: "Add EA sheet", icon: "plus", style: .gold, size: .sm)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(workspace.customEAs) { ea in
                        EACard(ea: ea)
                    }
                }
            }
        }
    }

    // MARK: Thresholds tab

    private var thresholdsTab: some View {
        HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Thresholds")
                        .padding(.bottom, 14)
                    thresholdField(
                        label: "Stale device threshold", key: "stale_device_days",
                        value: $staleDeviceDays, unit: "days",
                        help: "Days since last check-in before a device is flagged stale"
                    )
                    thresholdField(
                        label: "Disk usage warning", key: "warning_disk_percent",
                        value: $warnDiskPct, unit: "%",
                        help: "Yellow highlight in Disk Usage sheet"
                    )
                    thresholdField(
                        label: "Disk usage critical", key: "critical_disk_percent",
                        value: $critDiskPct, unit: "%",
                        help: "Red highlight in Disk Usage sheet"
                    )
                    thresholdField(
                        label: "Cert expiry warning", key: "cert_warning_days",
                        value: $certWarningDays, unit: "days",
                        help: "Default expiry warning window for date EAs"
                    )
                }
            }

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Compliance Baseline")
                        .padding(.bottom, 2)
                    FieldLabel(label: "Baseline label")
                    PNPTextField(value: $baselineLabel)
                    FieldLabel(label: "Failures count column")
                    PNPTextField(value: $failuresCountCol, mono: true)
                    FieldLabel(label: "Failed-list column")
                    PNPTextField(value: $failuresListCol, mono: true)

                    Divider().background(Theme.Colors.hairline).padding(.top, 6)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generate compliance sheet")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.Colors.fg)
                            Text("Failed-rule counts per device")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                        PNPToggle(isOn: $complianceEnabled)
                    }
                }
            }
        }
    }

    private func thresholdField(
        label: String, key: String, value: Binding<String>, unit: String, help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label, trailing: key)
            HStack(spacing: 8) {
                PNPTextField(value: value, mono: true)
                    .frame(width: 100)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            FieldHelp(text: help)
        }
        .padding(.bottom, 14)
    }

    // MARK: Platform API tab

    private var platformTab: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeader(title: "Jamf Platform API · Preview")
                    Pill(text: "PREVIEW", tone: .warn)
                }
                Text("Public beta · requires ")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fgMuted)
                + Text("jamf-cli")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
                + Text(" build with ")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fgMuted)
                + Text("pro report")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
                + Text(" commands.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fgMuted)

                Divider().background(Theme.Colors.hairline)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Platform API sheets")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.fg)
                        Text("Blueprints, DDM Status, Compliance benchmarks")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    Spacer()
                    PNPToggle(isOn: $platformEnabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(label: "Compliance benchmarks")
                    HStack(spacing: 6) {
                        Pill(text: "CIS Level 1", tone: .muted)
                        Pill(text: "NIST 800-171r3", tone: .muted)
                        PNPButton(title: "Add benchmark", icon: "plus", style: .ghost, size: .sm)
                    }
                    FieldHelp(text: "Benchmark titles or IDs. Generates per-rule and per-device sheets.")
                }
            }
        }
    }

    // MARK: Output tab

    private var outputTab: some View {
        HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Output Directory")
                        .padding(.bottom, 14)
                    FieldLabel(label: "output_dir")
                    HStack(spacing: 6) {
                        PNPTextField(value: $outputDir, mono: true)
                        PNPButton(title: "", icon: "folder", size: .md)
                    }
                    FieldHelp(text: "Relative paths resolve from config.yaml's folder")

                    Divider().background(Theme.Colors.hairline).padding(.vertical, 14)

                    outputToggleRow(
                        title: "Timestamp output filenames",
                        detail: "_2026-04-25_091418",
                        isOn: $timestampOutputs
                    )
                    Divider().background(Theme.Colors.hairline).padding(.vertical, 10)
                    outputToggleRow(
                        title: "Auto-archive older runs",
                        detail: "Keep latest 10",
                        isOn: $autoArchive
                    )
                }
            }

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Branding")
                    // Logo upload intentionally omitted — removed per design review
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Organisation name")
                        PNPTextField(value: $orgName, placeholder: workspace.org.name)
                    }
                    HStack(spacing: 8) {
                        colorField(label: "Accent color", value: $accentColor, hexColor: Theme.Colors.gold)
                        colorField(label: "Accent dark", value: $accentDark, hexColor: Theme.Colors.goldDim)
                    }
                }
            }
        }
    }

    private func outputToggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.fg)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.Colors.fgMuted)
            }
            Spacer()
            PNPToggle(isOn: isOn)
        }
    }

    private func colorField(label: String, value: Binding<String>, hexColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hexColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                    )
                    .frame(width: 28, height: 28)
                PNPTextField(value: value, mono: true)
            }
        }
    }
}

// MARK: - ColumnFieldRow

private struct ColumnFieldRow: View {
    let mapping: ColumnMapping
    @State private var fieldValue: String

    init(mapping: ColumnMapping) {
        self.mapping = mapping
        self._fieldValue = State(initialValue: mapping.value)
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Mono(text: mapping.key, size: 11.5, color: Theme.Colors.fg2)
                if mapping.required {
                    Text("*")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.goldBright)
                }
            }
            .frame(width: 180, alignment: .leading)

            PNPTextField(
                value: $fieldValue,
                placeholder: mapping.status == .skip ? "(unmapped — feature skipped)" : "",
                mono: true
            )

            statusIcon
                .frame(width: 24)
        }
        .padding(.vertical, 6)
    }

    private var statusIcon: some View {
        Group {
            switch mapping.status {
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.ok)
            case .warn:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
            case .skip:
                Image(systemName: "minus.circle")
                    .foregroundStyle(Theme.Colors.fgMuted)
            case .fail:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.danger)
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }
}

// MARK: - EACard

private struct EACard: View {
    let ea: CustomEA

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ea.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Mono(text: ea.column, size: 11, color: Theme.Colors.fgMuted)
                }
                Spacer()
                Pill(text: ea.type.rawValue, tone: pillTone)
            }

            Text(eaDetail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var pillTone: Pill.Tone {
        switch ea.type {
        case .percentage: .gold
        case .boolean:    .teal
        case .date:       .warn
        default:          .muted
        }
    }

    private var eaDetail: String {
        switch ea.type {
        case .percentage:
            let w = ea.warn.map { "\($0)" } ?? "—"
            let c = ea.crit.map { "\($0)" } ?? "—"
            return "Warning ≥ \(w)% · Critical ≥ \(c)%"
        case .version:
            let v = ea.currentVersions?.joined(separator: ", ") ?? "—"
            return "Current: \(v)"
        case .date:
            let d = ea.warningDays.map { "\($0)" } ?? "—"
            return "Warn within \(d) days · Past = expired"
        case .boolean:
            return "True value: \(ea.trueValue ?? "—")"
        case .text:
            return "Frequency table"
        }
    }
}
