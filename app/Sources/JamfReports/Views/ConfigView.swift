import SwiftUI
import AppKit

// MARK: - ConfigView

struct ConfigView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var cli = CLIBridge()

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

    // MARK: Save-status feedback pill

    enum SaveStatus: Equatable {
        case idle, saving, saved, error(String)
    }

    @State private var tab: ConfigTab = .columns
    @State private var saveStatus: SaveStatus = .idle
    @State private var saveTask: Task<Void, Never>?

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
        .task(id: workspace.profile) {
            do {
                try await workspace.loadConfig()
            } catch {
                workspace.configError = error.localizedDescription
            }
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(
            kicker: "Workspace · \(workspace.profile)",
            title: "config.yaml",
            subtitle: "~/Jamf-Reports/\(workspace.profile)/config.yaml"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    saveStatusPill
                    PNPButton(title: "View YAML", icon: "chevron.left.forwardslash.chevron.right", action: viewYAML)
                    PNPButton(title: "Run check", icon: "flask", action: runCheck)
                    PNPButton(title: "Save", icon: "checkmark", style: .gold, action: save)
                }
            )
        }
    }

    private func viewYAML() {
        guard let url = ProfileService.workspaceURL(for: workspace.profile) else { return }
        let config = url.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        SystemActions.open(config)
    }

    @ViewBuilder
    private var saveStatusPill: some View {
        switch saveStatus {
        case .saved:
            Pill(text: "saved", tone: .teal, icon: "checkmark")
                .transition(.opacity)
        case .error(let msg):
            Pill(text: "error: \(msg)", tone: .danger)
                .transition(.opacity)
        case .saving:
            Pill(text: "saving…", tone: .muted)
                .transition(.opacity)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Tab routing

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .columns:    ColumnsTab()
        case .agents:     AgentsTab()
        case .eas:        EasTab()
        case .thresholds: ThresholdsTab()
        case .platform:   PlatformTab()
        case .output:     OutputTab()
        }
    }

    // MARK: Button actions

    private func save() {
        saveTask?.cancel()
        saveStatus = .saving
        saveTask = Task { @MainActor in
            do {
                try await workspace.saveConfig()
                withAnimation { saveStatus = .saved }
            } catch {
                withAnimation { saveStatus = .error(shortMessage(error)) }
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { saveStatus = .idle }
        }
    }

    private func runCheck() {
        Task {
            _ = await cli.check(profile: workspace.profile, csvPath: nil) { _ in }
        }
    }

    private func shortMessage(_ error: Error) -> String {
        let full = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return full.count > 60 ? String(full.prefix(57)) + "…" : full
    }
}

// MARK: - Columns tab

private struct ColumnsTab: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var cli = CLIBridge()
    @State private var checkStatus: String? = nil

    var body: some View {
        @Bindable var ws = workspace
        HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader(title: "CSV Column Mappings")
                        Spacer()
                        Pill(
                            text: "\(ws.columnMappings.filter { $0.status == .ok }.count) OK · "
                                + "\(ws.columnMappings.filter { $0.status == .warn }.count) WARN",
                            tone: .teal,
                            icon: "checkmark"
                        )
                    }
                    .padding(.bottom, 8)

                    HStack(spacing: 4) {
                        Text("Mapping logical fields → column headers in your CSV export")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    .padding(.bottom, 12)

                    VStack(spacing: 0) {
                        ForEach(ws.columnMappings.indices, id: \.self) { i in
                            ColumnFieldRow(
                                mapping: ws.columnMappings[i],
                                value: Binding(
                                    get: { ws.columnMappings[i].value },
                                    set: { ws.columnMappings[i].value = $0 }
                                )
                            )
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
                let ok   = workspace.columnMappings.filter { $0.status == .ok }.count
                let warn = workspace.columnMappings.filter { $0.status == .warn }.count
                let skip = workspace.columnMappings.filter { $0.status == .skip }.count
                VStack(alignment: .leading, spacing: 10) {
                    validationRow(icon: "checkmark.circle.fill", color: Theme.Colors.ok,
                                  title: "\(ok) columns mapped", detail: "Required fields present")
                    if warn > 0 {
                        validationRow(icon: "exclamationmark.triangle.fill", color: Theme.Colors.warn,
                                      title: "\(warn) warnings", detail: "Run check for details")
                    }
                    if skip > 0 {
                        validationRow(icon: "minus.circle", color: Theme.Colors.fgMuted,
                                      title: "\(skip) unmapped", detail: "Sheets that use these will be skipped")
                    }
                }
                Divider().background(Theme.Colors.hairline).padding(.vertical, 12)
                if let status = checkStatus {
                    Mono(text: status, size: 10.5, color: Theme.Colors.fgMuted)
                        .lineLimit(2)
                        .padding(.bottom, 6)
                }
                HStack(spacing: 6) {
                    PNPButton(title: "Re-check", icon: "arrow.clockwise", size: .sm, action: runCheck)
                    PNPButton(title: "Open CSV", icon: "arrow.up.right.square", style: .ghost, size: .sm, action: openCSV)
                }
            }
        }
    }

    private func validationRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Colors.fg)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    private var scaffoldTipCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Tip")
                (Text("Run ") + Text("scaffold").font(Theme.Fonts.mono(11)) +
                 Text(" to auto-detect columns from a new CSV export. Existing config is preserved."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fg2)
                PNPButton(title: "Re-scaffold from CSV", icon: "bolt", style: .gold, size: .sm, action: runScaffold)
            }
        }
    }

    private func runCheck() {
        Task {
            checkStatus = "Running check…"
            let csvPath = newestCSVPath()
            let exit = await cli.check(profile: workspace.profile, csvPath: csvPath) { line in
                Task { @MainActor in checkStatus = line.text }
            }
            checkStatus = exit == 0 ? "Check passed · exit 0" : "Check failed · exit \(exit)"
        }
    }

    private func openCSV() {
        guard let url = newestCSVURL() else { return }
        SystemActions.open(url)
    }

    private func runScaffold() {
        guard let command = cli.resolveJRCCommand(),
              let wsURL = ProfileService.workspaceURL(for: workspace.profile) else { return }
        guard let csvURL = newestCSVURL() else { return }
        let configOut = wsURL.appendingPathComponent("config.yaml")
        let args = command.arguments + [
            "scaffold",
            "--csv", csvURL.path,
            "--out", configOut.path,
        ]
        Task {
            let exit = await cli.run(executable: command.executable, arguments: args) { _ in }
            if exit == 0 {
                workspace.reloadFromDisk()
            }
        }
    }

    private func newestCSVURL() -> URL? {
        guard let wsURL = ProfileService.workspaceURL(for: workspace.profile) else { return nil }
        let inbox = wsURL.appendingPathComponent("csv-inbox")
        let dir = FileManager.default.fileExists(atPath: inbox.path) ? inbox : wsURL
        return (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "csv" }
        .max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                         .contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                         .contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    private func newestCSVPath() -> String? { newestCSVURL()?.path }
}

// MARK: - Agents tab

private struct AgentsTab: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        @Bindable var ws = workspace
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Security Agents")
                    Spacer()
                    PNPButton(title: "Add agent", icon: "plus", style: .gold, size: .sm, action: { ws.addSecurityAgent() })
                }
                agentsTable
            }
        }
    }

    private var agentsTable: some View {
        @Bindable var ws = workspace
        return VStack(spacing: 0) {
            agentsHeader
            Divider().background(Theme.Colors.hairline)
            if ws.configState.securityAgents.isEmpty {
                Text("No security agents configured. Add one to track install rates.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .padding(16)
            } else {
                ForEach(ws.configState.securityAgents.indices, id: \.self) { i in
                    agentRow(i)
                    if i < ws.configState.securityAgents.count - 1 { Divider().background(Theme.Colors.hairline) }
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

    private func agentRow(_ index: Int) -> some View {
        @Bindable var ws = workspace
        return HStack(spacing: 8) {
            PNPTextField(value: $ws.configState.securityAgents[index].name)
                .frame(maxWidth: .infinity, alignment: .leading)
            PNPTextField(value: $ws.configState.securityAgents[index].column, mono: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PNPTextField(value: $ws.configState.securityAgents[index].connectedValue, mono: true)
                .frame(width: 140, alignment: .leading)
            Menu {
                Button(role: .destructive) { workspace.removeSecurityAgent(at: index) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 36, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Custom EAs tab

private struct EasTab: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        @Bindable var ws = workspace
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Custom Extension Attribute Sheets")
                    Spacer()
                    PNPButton(title: "Add EA sheet", icon: "plus", style: .gold, size: .sm, action: { ws.addCustomEA() })
                }
                if ws.configState.customEAs.isEmpty {
                    Text("No custom EA sheets configured.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    VStack(spacing: 12) {
                        ForEach(ws.configState.customEAs.indices, id: \.self) { i in
                            EACardEdit(index: i)
                        }
                    }
                }
            }
        }
    }
}

private struct EACardEdit: View {
    @Environment(WorkspaceStore.self) private var workspace
    let index: Int

    var body: some View {
        @Bindable var ws = workspace
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Sheet name")
                    PNPTextField(value: $ws.configState.customEAs[index].name)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "EA Column")
                    PNPTextField(value: $ws.configState.customEAs[index].column, mono: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Type")
                    Picker("", selection: $ws.configState.customEAs[index].type) {
                        Text("Boolean").tag("boolean")
                        Text("Percentage").tag("percentage")
                        Text("Version").tag("version")
                        Text("Text").tag("text")
                        Text("Date").tag("date")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                Button(role: .destructive) { workspace.removeCustomEA(at: index) } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.Colors.danger)
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
            }

            let type = ws.configState.customEAs[index].type
            HStack(spacing: 16) {
                if type == "boolean" {
                    eaField(label: "True value", value: $ws.configState.customEAs[index].trueValue, help: "Value that means compliant")
                } else if type == "percentage" {
                    eaField(label: "Warning ≥", value: $ws.configState.customEAs[index].warningThreshold, unit: "%")
                    eaField(label: "Critical ≥", value: $ws.configState.customEAs[index].criticalThreshold, unit: "%")
                } else if type == "date" {
                    eaField(label: "Warning days", value: $ws.configState.customEAs[index].warningDays, unit: "days")
                } else if type == "version" {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Current versions")
                        Text("Comma-separated list").font(.system(size: 10)).foregroundStyle(Theme.Colors.fgMuted)
                        PNPTextField(value: Binding(
                            get: { ws.configState.customEAs[index].currentVersions.joined(separator: ", ") },
                            set: { ws.configState.customEAs[index].currentVersions = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        ), mono: true)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
    }

    private func eaField(label: String, value: Binding<String>, unit: String? = nil, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label)
            HStack(spacing: 8) {
                PNPTextField(value: value, mono: true).frame(width: 80)
                if let unit {
                    Text(unit).font(.system(size: 11)).foregroundStyle(Theme.Colors.fgMuted)
                }
            }
            if let help {
                FieldHelp(text: help)
            }
        }
    }
}

// MARK: - Thresholds tab

private struct ThresholdsTab: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        @Bindable var ws = workspace
        HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "General Thresholds").padding(.bottom, 14)
                    thresholdField(
                        label: "Stale device threshold", key: "stale_device_days",
                        value: $ws.configState.staleDeviceDays, unit: "days",
                        help: "Days since last check-in before a device is flagged stale"
                    )
                    thresholdField(
                        label: "Check-in overdue", key: "checkin_overdue_days",
                        value: $ws.configState.checkinOverdueDays, unit: "days",
                        help: "Yellow highlight on Check-in Health sheet"
                    )
                    thresholdField(
                        label: "Cert expiry warning", key: "cert_warning_days",
                        value: $ws.configState.certWarningDays, unit: "days",
                        help: "Default expiry warning window for date EAs"
                    )

                    Divider().background(Theme.Colors.hairline).padding(.vertical, 14)
                    SectionHeader(title: "Disk Usage").padding(.bottom, 14)
                    thresholdField(
                        label: "Disk usage warning", key: "warning_disk_percent",
                        value: $ws.configState.warningDiskPercent, unit: "%",
                        help: "Yellow highlight in Disk Usage sheet"
                    )
                    thresholdField(
                        label: "Disk usage critical", key: "critical_disk_percent",
                        value: $ws.configState.criticalDiskPercent, unit: "%",
                        help: "Red highlight in Disk Usage sheet"
                    )
                }
            }

            VStack(spacing: 14) {
                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Compliance Baseline").padding(.bottom, 2)
                        FieldLabel(label: "Baseline label")
                        PNPTextField(value: $ws.configState.baselineLabel)
                        FieldLabel(label: "Failures count column")
                        PNPTextField(value: $ws.configState.failuresCountColumn, mono: true)
                        FieldLabel(label: "Failed-list column")
                        PNPTextField(value: $ws.configState.failuresListColumn, mono: true)
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
                            PNPToggle(isOn: $ws.configState.complianceEnabled)
                        }
                    }
                }

                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "jamf-cli Errors").padding(.bottom, 2)
                        thresholdField(
                            label: "Profile error critical", key: "profile_error_critical",
                            value: $ws.configState.profileErrorCritical, unit: "errors",
                            help: "Red highlight on Profile Status sheet"
                        )
                        thresholdField(
                            label: "Profile error warning", key: "profile_error_warning",
                            value: $ws.configState.profileErrorWarning, unit: "errors",
                            help: "Yellow highlight on Profile Status sheet"
                        )
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
                PNPTextField(value: value, mono: true).frame(width: 100)
                Text(unit).font(.system(size: 12)).foregroundStyle(Theme.Colors.fgMuted)
            }
            FieldHelp(text: help)
        }
        .padding(.bottom, 14)
    }
}

// MARK: - Platform API tab

private struct PlatformTab: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        @Bindable var ws = workspace
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeader(title: "Jamf Platform API · Preview")
                    Pill(text: "PREVIEW", tone: .warn)
                }
                (Text("Public beta · requires ")
                 + Text("jamf-cli").font(Theme.Fonts.mono(11))
                 + Text(" build with ")
                 + Text("pro report").font(Theme.Fonts.mono(11))
                 + Text(" commands."))
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
                    PNPToggle(isOn: $ws.configState.platformEnabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Compliance benchmarks")
                    ForEach(ws.configState.complianceBenchmarks.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            PNPTextField(value: $ws.configState.complianceBenchmarks[i])
                            Button(role: .destructive) { ws.removeComplianceBenchmark(at: i) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Theme.Colors.danger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    PNPButton(title: "Add benchmark", icon: "plus", style: .ghost, size: .sm, action: { ws.addComplianceBenchmark() })
                    FieldHelp(text: "Benchmark titles or IDs. Generates per-rule and per-device sheets.")
                }
            }
        }
    }
}

// MARK: - Output tab

private struct OutputTab: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        @Bindable var ws = workspace
        HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Output Directory").padding(.bottom, 14)
                    FieldLabel(label: "output_dir")
                    HStack(spacing: 6) {
                        PNPTextField(value: $ws.configState.outputDir, mono: true)
                        PNPButton(title: "", icon: "folder", size: .md) {
                            pickFolder { ws.configState.outputDir = $0 }
                        }
                    }
                    FieldHelp(text: "Relative paths resolve from config.yaml's folder")
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "archive_dir")
                        HStack(spacing: 6) {
                            PNPTextField(value: $ws.configState.archiveDir, mono: true)
                            PNPButton(title: "", icon: "folder", size: .md) {
                                pickFolder { ws.configState.archiveDir = $0 }
                            }
                        }
                        FieldHelp(text: "Optional. Leave blank to use 'archive' next to output_dir.")
                    }
                    .padding(.top, 14)

                    Divider().background(Theme.Colors.hairline).padding(.vertical, 14)
                    outputToggleRow(
                        title: "Timestamp output filenames",
                        detail: "_2026-04-25_091418",
                        isOn: $ws.configState.timestampOutputs
                    )
                    Divider().background(Theme.Colors.hairline).padding(.vertical, 10)
                    outputToggleRow(
                        title: "Auto-archive older runs",
                        detail: "Keep latest \(ws.configState.keepLatestRuns)",
                        isOn: $ws.configState.archiveEnabled
                    )
                    Divider().background(Theme.Colors.hairline).padding(.vertical, 10)
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "keep_latest_runs")
                        PNPTextField(value: $ws.configState.keepLatestRuns, mono: true)
                            .frame(width: 80)
                    }
                    Divider().background(Theme.Colors.hairline).padding(.vertical, 10)
                    outputToggleRow(
                        title: "Export PPTX Summary",
                        detail: "PowerPoint executive summary deck",
                        isOn: $ws.configState.exportPptx
                    )
                }
            }

            // Branding: keys ARE in config.example.yaml and DEFAULT_CONFIG.
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Branding")
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Organisation name")
                        PNPTextField(value: $ws.configState.orgName, placeholder: ws.org.name)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Logo path")
                        PNPTextField(value: $ws.configState.logoPath, mono: true)
                    }
                    HStack(spacing: 8) {
                        colorField(label: "Accent color", value: $ws.configState.accentColor,
                                   hexColor: Theme.Colors.gold)
                        colorField(label: "Accent dark", value: $ws.configState.accentDark,
                                   hexColor: Theme.Colors.goldDim)
                    }
                }
            }
        }
    }

    private func pickFolder(completion: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in completion(url.path) }
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
    @Binding var value: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Mono(text: mapping.key, size: 11.5, color: Theme.Colors.fg2)
                if mapping.required {
                    Text("*").font(.system(size: 10)).foregroundStyle(Theme.Colors.goldBright)
                }
            }
            .frame(width: 180, alignment: .leading)

            PNPTextField(
                value: $value,
                placeholder: mapping.status == .skip ? "(unmapped — feature skipped)" : "",
                mono: true
            )

            statusIcon.frame(width: 24)
        }
        .padding(.vertical, 6)
    }

    private var statusIcon: some View {
        Group {
            switch mapping.status {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.ok)
            case .warn:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Colors.warn)
            case .skip:
                Image(systemName: "minus.circle").foregroundStyle(Theme.Colors.fgMuted)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.danger)
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
                    Text(ea.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.fg)
                    Mono(text: ea.column, size: 11, color: Theme.Colors.fgMuted)
                }
                Spacer()
                Pill(text: ea.type.rawValue, tone: pillTone)
            }
            Text(eaDetail).font(.system(size: 11.5)).foregroundStyle(Theme.Colors.fgMuted)
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
            return "Warning ≥ \(ea.warn.map { "\($0)" } ?? "—")% · Critical ≥ \(ea.crit.map { "\($0)" } ?? "—")%"
        case .version:
            return "Current: \(ea.currentVersions?.joined(separator: ", ") ?? "—")"
        case .date:
            return "Warn within \(ea.warningDays.map { "\($0)" } ?? "—") days · Past = expired"
        case .boolean:
            return "True value: \(ea.trueValue ?? "—")"
        case .text:
            return "Frequency table"
        }
    }
}
