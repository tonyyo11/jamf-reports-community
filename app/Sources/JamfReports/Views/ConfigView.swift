import SwiftUI
import AppKit
import TipKit

/// Bounds-checked binding to an array element by index.
///
/// `ForEach(array.indices, id: \.self)` re-evaluates a row's body for an index
/// that no longer exists during SwiftUI's removal diff. A plain
/// `$array[index]` binding traps (`Array index out of range`) when its getter
/// runs against the shrunken array — the crash seen when deleting a Security
/// Agent / Custom EA / Compliance Benchmark row. This binding returns `default`
/// for an out-of-range read and ignores an out-of-range write, so the
/// disappearing row renders harmlessly instead of crashing.
@MainActor
func safeElementBinding<T>(
    _ array: Binding<[T]>, _ index: Int, default fallback: T
) -> Binding<T> {
    Binding(
        get: { index >= 0 && index < array.wrappedValue.count
            ? array.wrappedValue[index] : fallback },
        set: { newValue in
            if index >= 0 && index < array.wrappedValue.count {
                array.wrappedValue[index] = newValue
            }
        }
    )
}

// MARK: - ConfigView

struct ConfigView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var cli = CLIBridge()

    enum ConfigTab: String, CaseIterable {
        case columns, agents, eas, thresholds, platform, output, scoring
        var label: String {
            switch self {
            case .columns:    "Columns"
            case .agents:     "Security Agents"
            case .eas:        "Custom EAs"
            case .thresholds: "Thresholds"
            case .platform:   "Platform API"
            case .output:     "Output & Branding"
            case .scoring:    "Scoring"
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
            case .scoring:    "scalemass"
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
    @State private var triggerColumnsCheck = false
    /// Key-path detail from the report engine's strict parse, when it fails
    /// on a file the lenient GUI editor tolerates (#181 recovery card).
    @State private var engineParseDetail: String?
    @State private var showRestoreConfirm = false

    var body: some View {
        PageScaffold(spacing: 16) {
            header
            SegmentedControl(
                selection: $tab,
                options: ConfigTab.allCases.map { ($0, $0.label, $0.icon) }
            )
            if let problem = configProblem {
                configRecoveryCard(problem)
            }
            if !workspace.configRepairedKeys.isEmpty {
                configHealedKeysCard(workspace.configRepairedKeys)
            }
            tabContent
        }
        .task(id: workspace.profile) {
            do {
                try await workspace.loadConfig()
            } catch {
                workspace.configError = error.localizedDescription
            }
            refreshEngineParseStatus()
        }
        .confirmationDialog(
            "Restore the default config.yaml?",
            isPresented: $showRestoreConfirm, titleVisibility: .visible
        ) {
            Button("Restore default", role: .destructive) {
                Task {
                    if let failure = await workspace.restoreDefaultConfig() {
                        workspace.toast = Toast(message: failure, style: .danger)
                    }
                    refreshEngineParseStatus()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let summary = workspace.clearedConfigSummary()
            Text(
                (summary.isEmpty
                    ? "This reseeds the default config."
                    : "This clears \(summary).")
                + " Your current file is kept beside the new one as "
                + "config.yaml.broken-<timestamp> — nothing is deleted, so you can copy "
                + "values back. Rebuild quickly with the CSV → EA guide and Columns scaffold."
            )
        }
    }

    /// The first config problem to surface: the GUI editor's load error, or —
    /// when the editor copes but the report engine cannot parse the file —
    /// the engine decoder's key-path detail (#181).
    private var configProblem: String? {
        workspace.configError ?? engineParseDetail
    }

    /// Re-run the engine's strict parse and keep its key-path detail for the
    /// recovery card. The GUI's lenient YAMLCodec can tolerate a file that
    /// still breaks report generation, so both checks matter.
    private func refreshEngineParseStatus() {
        guard !workspace.demoMode,
              let url = ProfileService.workspaceURL(for: workspace.profile)?
                  .appendingPathComponent("config.yaml"),
              FileManager.default.fileExists(atPath: url.path) else {
            engineParseDetail = nil
            return
        }
        do {
            _ = try ConfigLoader.load(from: url)
            engineParseDetail = nil
        } catch let error as ConfigLoader.LoadError {
            engineParseDetail = error.keyPathDetail ?? error.localizedDescription
        } catch {
            engineParseDetail = error.localizedDescription
        }
    }

    private func configRecoveryCard(_ problem: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.danger)
                        .accessibilityHidden(true)
                    Text("Configuration file problem")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                }
                Text(problem)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.Colors.dangerSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Configuration error: \(problem)")
                HStack(spacing: 8) {
                    PNPButton(title: "Open config.yaml", icon: "doc.text", size: .sm) {
                        if let url = ProfileService.workspaceURL(for: workspace.profile)?
                            .appendingPathComponent("config.yaml") {
                            SystemActions.open(url)
                        }
                    }
                    PNPButton(title: "Restore default config…", style: .danger, size: .sm) {
                        showRestoreConfirm = true
                    }
                }
            }
        }
    }

    /// Informational card shown when the YAML parser auto-healed orphaned
    /// sequence items on load. Not a parse failure — the file is still readable
    /// — but the on-disk YAML is malformed until the user saves from this screen.
    private func configHealedKeysCard(_ keys: [String]) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(Theme.Colors.warn)
                        .accessibilityHidden(true)
                    Text("Config auto-healed on load")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Pill(text: "\(keys.count) key\(keys.count == 1 ? "" : "s")", tone: .warn)
                }
                Text("The following YAML keys had malformed sequence items that were "
                    + "auto-reattached. The file reads correctly but is still malformed "
                    + "on disk. Save from this screen to persist the cleanup.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Mono(text: keys.joined(separator: ", "), size: 11.5, color: Theme.Colors.warnSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Healed keys: \(keys.joined(separator: ", "))")
                PNPButton(title: "Save now", icon: "checkmark", style: .gold, size: .sm) {
                    save()
                }
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
                    if workspace.hasUnsavedChanges && saveStatus == .idle {
                        Pill(text: "Unsaved changes", tone: .warn, icon: "pencil")
                            .transition(.opacity)
                    }
                    saveStatusPill
                    PNPButton(title: "View YAML", icon: "chevron.left.forwardslash.chevron.right", action: viewYAML)
                    PNPButton(title: "Run check", icon: "flask") {
                        tab = .columns
                        triggerColumnsCheck = true
                    }
                    PNPButton(title: "Save", icon: "checkmark", style: .gold, action: save)
                }
            )
        }
    }

    private func viewYAML() {
        guard let url = ProfileService.workspaceURL(for: workspace.profile) else {
            workspace.toast = Toast(
                message: "Workspace not found for profile `\(workspace.profile)`.",
                style: .danger
            )
            return
        }
        let config = url.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: config.path) else {
            workspace.toast = Toast(
                message: "config.yaml does not exist yet — save first.",
                style: .danger
            )
            return
        }
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
        case .columns:    ColumnsTab(triggerCheck: $triggerColumnsCheck)
        case .agents:     AgentsTab()
        case .eas:        EasTab()
        case .thresholds: ThresholdsTab()
        case .platform:   PlatformTab()
        case .output:     OutputTab()
        case .scoring:    ScoringTab()
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

    private func shortMessage(_ error: Error) -> String {
        let full = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return full.count > 60 ? String(full.prefix(57)) + "…" : full
    }
}

// MARK: - Columns tab

private struct ColumnsTab: View {
    /// Which device-family column block the editor is showing.
    private enum ColumnFamily: Hashable { case mac, mobile }

    @Binding var triggerCheck: Bool
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var cli = CLIBridge()
    @State private var checkStatus: String? = nil
    @State private var family: ColumnFamily = .mac

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                SegmentedControl(
                    selection: $family,
                    options: [
                        (ColumnFamily.mac, "macOS", "laptopcomputer"),
                        (ColumnFamily.mobile, "Mobile Devices", "ipad"),
                    ]
                )
                TipView(ConfigTips.columnMapping)
                    .frame(maxWidth: 480, alignment: .leading)
                switch family {
                case .mac:    macColumnsCard
                case .mobile: mobileColumnsCard
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                validationCard
                scaffoldTipCard
            }
            .frame(width: 240)
        }
        .onChange(of: triggerCheck) { _, triggered in
            guard triggered else { return }
            triggerCheck = false
            family = .mac
            runCheck()
        }
    }

    // MARK: macOS column mappings (unchanged idiom)

    private var macColumnsCard: some View {
        @Bindable var ws = workspace
        return Card(padding: 18) {
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
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
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
    }

    // MARK: Mobile-device column mappings (opt-in)

    private var mobileColumnsCard: some View {
        @Bindable var ws = workspace
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Mobile CSV Column Mappings")
                    .padding(.bottom, 8)
                Text("Optional — only needed if you report on iOS/iPadOS/tvOS "
                    + "devices. Leave blank for a Mac-only fleet.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)

                VStack(spacing: 0) {
                    ForEach(ConfigState.mobileColumnKeys, id: \.self) { key in
                        MobileColumnFieldRow(
                            key: key,
                            placeholder: Self.mobilePlaceholders[key] ?? "",
                            value: Binding(
                                get: { ws.configState.mobileColumns[key] ?? "" },
                                set: { ws.configState.mobileColumns[key] = $0 }
                            )
                        )
                    }
                }
            }
        }
    }

    /// Native column-header examples shown as placeholders when a mobile
    /// mapping is blank. Mirrors the `mobile_columns` block in
    /// `config.example.yaml`.
    private static let mobilePlaceholders: [String: String] = [
        "device_name": "Display Name",
        "serial_number": "Serial Number",
        "operating_system": "OS Version",
        "last_checkin": "Last Inventory Update",
        "email": "Email Address",
        "model": "Model",
        "device_family": "Device Family",
        "managed": "Managed",
        "supervised": "Supervised",
    ]

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
                        validationRow(icon: "minus.circle", color: Theme.Text.tertiary(contrast),
                                      title: "\(skip) unmapped", detail: "Sheets that use these will be skipped")
                    }
                }
                Divider().background(Theme.Hairline.standard).padding(.vertical, 12)
                if let status = checkStatus {
                    Mono(text: status, size: 10.5, color: Theme.Text.tertiary(contrast))
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
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(Theme.Text.primary)
                Text(detail).font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }

    private var scaffoldTipCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Tip")
                Text(scaffoldTipText)
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
                PNPButton(title: "Re-scaffold from CSV", icon: "bolt", style: .gold, size: .sm,
                          action: runScaffold)
                TipView(ConfigTips.rescaffold)
            }
        }
    }

    private func runCheck() {
        Task {
            checkStatus = "Running check…"
            let csvPath = newestCSVPath()
            let exit: Int32
            do {
                exit = try await cli.check(profile: workspace.profile, csvPath: csvPath) { line in
                    Task { @MainActor in checkStatus = line.text }
                }
            } catch {
                checkStatus = "Check failed: \(error.localizedDescription). Confirm a CSV is in "
                    + "csv-inbox and config.yaml is valid."
                return
            }
            checkStatus = exit == 0
                ? "Check passed · exit 0"
                : CLIBridge.explainExit(exit, operation: "Config check")
        }
    }

    private func openCSV() {
        guard let url = newestCSVURL() else {
            workspace.toast = Toast(
                message: "No CSV export found in the workspace yet.",
                style: .danger
            )
            return
        }
        SystemActions.open(url)
    }

    private var scaffoldTipText: String {
        "Run scaffold to detect column mappings from a new CSV export and merge them into "
            + "profile \(workspace.profile)'s config.yaml. Existing mappings, security agents, "
            + "custom EAs and thresholds are kept — only empty or stale column mappings are "
            + "filled. Re-running as the CSV changes over time is safe."
    }

    private func runScaffold() {
        guard let csvURL = newestCSVURL() else {
            workspace.toast = Toast(
                message: "Drop a CSV export into the workspace before scaffolding.",
                style: .danger
            )
            return
        }
        let profile = workspace.profile
        Task {
            do {
                // MERGE into the existing config (per profile) rather than
                // overwrite: fill empty mappings, repair mappings whose CSV
                // column is gone, keep everything else (agents, custom EAs,
                // thresholds) untouched. ConfigService.save preserves unmanaged keys.
                let sample = try ScaffoldService.readSample(from: csvURL)
                let result = try ScaffoldService.matchColumns(from: csvURL, profile: profile)
                var loaded = try ConfigService.load(profile: profile)
                let isMobile = result.family == .mobile
                let detected = isMobile ? result.mobileColumns : result.columns
                let existing = isMobile ? loaded.state.mobileColumns : loaded.state.columns
                let merge = ScaffoldService.mergeColumns(
                    existing: existing, detected: detected, csvHeaders: sample.headers)
                var report = merge.report
                if isMobile { loaded.state.mobileColumns = merge.merged }
                else { loaded.state.columns = merge.merged }

                // Compliance columns (computer family only) merge the same way —
                // they live in two scalar fields, not the columns dict.
                if !isMobile {
                    let existingCompliance = [
                        "failures_count_column": loaded.state.failuresCountColumn,
                        "failures_list_column": loaded.state.failuresListColumn,
                    ]
                    let cMerge = ScaffoldService.mergeColumns(
                        existing: existingCompliance, detected: result.complianceColumns,
                        csvHeaders: sample.headers)
                    loaded.state.failuresCountColumn =
                        cMerge.merged["failures_count_column"] ?? loaded.state.failuresCountColumn
                    loaded.state.failuresListColumn =
                        cMerge.merged["failures_list_column"] ?? loaded.state.failuresListColumn
                    report.added += cMerge.report.added
                    report.repaired += cMerge.report.repaired
                    report.keptCount += cMerge.report.keptCount
                    report.staleUnresolved += cMerge.report.staleUnresolved
                }
                _ = try ConfigService.save(
                    profile: profile, state: loaded.state, existingDocument: loaded.document)
                let familyLabel = isMobile ? "mobile device export" : "computer export"
                await MainActor.run {
                    workspace.toast = Toast(
                        message: "Merged \(familyLabel) column mappings into \(profile)'s "
                            + "config — \(report.summary). Security agents, custom EAs and "
                            + "thresholds were kept. Review the Columns tab, then Save.",
                        style: .success
                    )
                }
                workspace.reloadFromDisk()
            } catch {
                await MainActor.run {
                    workspace.toast = Toast(
                        message: "Re-scaffold failed for \(profile): \(error.localizedDescription)",
                        style: .danger)
                }
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
    @Environment(\.colorSchemeContrast) private var contrast

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
            Divider().background(Theme.Hairline.standard)
            if ws.configState.securityAgents.isEmpty {
                Text("No security agents configured. Add one to track install rates.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .padding(16)
            } else {
                ForEach(ws.configState.securityAgents.indices, id: \.self) { i in
                    agentRow(i)
                    if i < ws.configState.securityAgents.count - 1 { Divider().background(Theme.Hairline.standard) }
                }
            }
        }
        .background(Color.white.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.Hairline.standard, lineWidth: 0.5)
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
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
    }

    private func agentRow(_ index: Int) -> some View {
        @Bindable var ws = workspace
        // Bounds-checked element binding: a `ForEach(indices, id: \.self)` row can
        // be re-evaluated for a now-deleted index during SwiftUI's removal diff;
        // a raw `$array[index]` subscript traps there. See safeElementBinding.
        let agent = safeElementBinding(
            $ws.configState.securityAgents, index,
            default: ConfigSecurityAgent(name: "", column: "", connectedValue: ""))
        return HStack(spacing: 8) {
            PNPTextField(value: agent.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            PNPTextField(value: agent.column, mono: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PNPTextField(value: agent.connectedValue, mono: true)
                .frame(width: 140, alignment: .leading)
            Menu {
                Button(role: .destructive) { workspace.removeSecurityAgent(at: index) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
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
    @Environment(\.colorSchemeContrast) private var contrast

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
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
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
    @Environment(\.colorSchemeContrast) private var contrast
    let index: Int

    var body: some View {
        @Bindable var ws = workspace
        // Bounds-checked element binding — a deleted row can be re-evaluated for
        // a stale index during SwiftUI's removal diff; a raw `[index]` subscript
        // traps. See safeElementBinding.
        let ea = safeElementBinding(
            $ws.configState.customEAs, index,
            default: ConfigCustomEA(
                name: "", column: "", type: "text", trueValue: "",
                warningThreshold: "", criticalThreshold: "",
                currentVersions: [], warningDays: ""))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Sheet name")
                    PNPTextField(value: ea.name)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "EA Column")
                    PNPTextField(value: ea.column, mono: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Type")
                    Picker("", selection: ea.type) {
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
                .accessibilityLabel("Remove \(ea.wrappedValue.name.isEmpty ? "extension attribute" : ea.wrappedValue.name)")
                .help("Remove this extension attribute mapping.")
            }

            let type = ea.wrappedValue.type
            HStack(spacing: 16) {
                if type == "boolean" {
                    eaField(label: "True value", value: ea.trueValue, help: "Value that means compliant")
                } else if type == "percentage" {
                    eaField(label: "Warning ≥", value: ea.warningThreshold, unit: "%")
                    eaField(label: "Critical ≥", value: ea.criticalThreshold, unit: "%")
                } else if type == "date" {
                    eaField(label: "Warning days", value: ea.warningDays, unit: "days")
                } else if type == "version" {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Current versions")
                        Text("Comma-separated list").font(.caption2).foregroundStyle(Theme.Text.tertiary(contrast))
                        PNPTextField(value: Binding(
                            get: { ea.wrappedValue.currentVersions.joined(separator: ", ") },
                            set: { ea.wrappedValue.currentVersions = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        ), mono: true)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Hairline.strong, lineWidth: 0.5)
        )
    }

    private func eaField(label: String, value: Binding<String>, unit: String? = nil, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label)
            HStack(spacing: 8) {
                PNPTextField(value: value, mono: true).frame(width: 80)
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
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
    @Environment(\.colorSchemeContrast) private var contrast

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

                    Divider().background(Theme.Hairline.standard).padding(.vertical, 14)
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
                        Divider().background(Theme.Hairline.standard).padding(.top, 6)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Generate compliance sheet")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                Text("Failed-rule counts per device")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
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
                Text(unit).font(.footnote).foregroundStyle(Theme.Text.tertiary(contrast))
            }
            FieldHelp(text: help)
        }
        .padding(.bottom, 14)
    }
}

// MARK: - Platform API tab

private struct PlatformTab: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    private var isPlatformProfile: Bool {
        workspace.profiles.first(where: { $0.name == workspace.profile })?.authMethod == "platform"
    }

    var body: some View {
        @Bindable var ws = workspace
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    SectionHeader(title: "Jamf Platform API · Preview")
                    Pill(text: "PREVIEW", tone: .warn)
                }
                (Text("Public beta · requires ")
                 + Text("jamf-cli").font(.caption.monospaced())
                 + Text(" build with ")
                 + Text("pro report").font(.caption.monospaced())
                 + Text(" commands."))
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Divider().background(Theme.Hairline.standard)
                if isPlatformProfile {
                    platformReadyCallout
                } else {
                    platformSetupCallout
                }
                Divider().background(Theme.Hairline.standard)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Platform API sheets")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Blueprints, DDM Status, Compliance benchmarks")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    PNPToggle(isOn: $ws.configState.platformEnabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Compliance benchmarks")
                    ForEach(ws.configState.complianceBenchmarks.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            PNPTextField(value: safeElementBinding(
                                $ws.configState.complianceBenchmarks, i, default: ""))
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

    private var platformReadyCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.ok)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Platform Gateway profile active")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text("Profile \"\(workspace.profile)\" is configured for Platform Gateway auth. "
                     + "Enable the toggle below to include Platform API sheets in generated reports.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.ok.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius)
                .strokeBorder(Theme.Colors.ok.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var platformSetupCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.gold)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Requires a Platform Gateway profile")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                (Text("Run ")
                 + Text("jamf-cli platform setup").font(.caption.monospaced())
                 + Text(" to create a Platform Gateway profile. "
                        + "This routes Pro API traffic through the Jamf Platform Gateway "
                        + "and unlocks Platform API commands used by these sheets."))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                Button {
                    if let url = URL(string: "https://github.com/Jamf-Concepts/jamf-cli/wiki/"
                                    + "Setup-Guide#jamf-pro-quick-start--platform-gateway-recommended") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Setup guide")
                            .font(.caption)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Colors.goldBright)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open jamf-cli platform setup guide in browser")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.gold.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.fieldRadius)
                .strokeBorder(Theme.Colors.gold.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Output tab

private struct OutputTab: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

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

                    Divider().background(Theme.Hairline.standard).padding(.vertical, 14)
                    outputToggleRow(
                        title: "Timestamp output filenames",
                        detail: "_2026-04-25_091418",
                        isOn: $ws.configState.timestampOutputs
                    )
                    Divider().background(Theme.Hairline.standard).padding(.vertical, 10)
                    outputToggleRow(
                        title: "Auto-archive older runs",
                        detail: "Keep latest \(ws.configState.keepLatestRuns)",
                        isOn: $ws.configState.archiveEnabled
                    )
                    Divider().background(Theme.Hairline.standard).padding(.vertical, 10)
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "keep_latest_runs")
                        PNPTextField(value: $ws.configState.keepLatestRuns, mono: true)
                            .frame(width: 80)
                    }
                }
            }

            VStack(spacing: 14) {
                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "jamf-cli Cache")
                        outputToggleRow(
                            title: "Use cached jamf-cli data",
                            detail: "jamf_cli.use_cached_data",
                            isOn: $ws.configState.jamfCLIUseCachedData
                        )
                        Divider().background(Theme.Hairline.standard).padding(.vertical, 10)
                        outputToggleRow(
                            title: "Require snapshot manifest",
                            detail: "jamf_cli.require_manifest — hard-fail on tampered or missing-entry snapshots",
                            isOn: $ws.configState.jamfCLIRequireManifest
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
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Theme.Text.primary)
                Text(detail).font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
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
                            .strokeBorder(Theme.Hairline.strong, lineWidth: 0.5)
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Mono(text: mapping.key, size: 11.5, color: Theme.Text.secondary)
                if mapping.required {
                    Text("*").font(.caption2).foregroundStyle(Theme.Colors.goldBright)
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
                Image(systemName: "minus.circle").foregroundStyle(Theme.Text.tertiary(contrast))
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.danger)
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }
}

// MARK: - MobileColumnFieldRow

/// One row of the Mobile Devices column editor. Same label + TextField idiom
/// as `ColumnFieldRow`, minus the live validation icon — mobile mappings are
/// not exercised by the macOS "Run check" flow.
private struct MobileColumnFieldRow: View {
    let key: String
    let placeholder: String
    @Binding var value: String

    var body: some View {
        HStack(spacing: 12) {
            Mono(text: key, size: 11.5, color: Theme.Text.secondary)
                .frame(width: 180, alignment: .leading)
            PNPTextField(value: $value, placeholder: placeholder, mono: true)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - EACard

private struct EACard: View {
    let ea: CustomEA
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ea.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.Text.primary)
                    Mono(text: ea.column, size: 11, color: Theme.Text.tertiary(contrast))
                }
                Spacer()
                Pill(text: ea.type.rawValue, tone: pillTone)
            }
            Text(eaDetail).font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Hairline.strong, lineWidth: 0.5)
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

// MARK: - Scoring tab

/// Lets the user override the weighted Security Score formula lifted from
/// v3.5. Backed by `@AppStorage(ScoringConfig.storageKey)`. Edits are
/// applied immediately to `SecurityScoreCalculator` callers that read
/// `ScoringConfig.parse(...)` from storage. Tenants without certain agent
/// stacks (e.g. no CrowdStrike) can zero out the matching weight to drop
/// that metric from the score entirely.
private struct ScoringTab: View {
    @AppStorage(ScoringConfig.storageKey) private var raw: String = ""
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(WorkspaceStore.self) private var workspace

    private var config: ScoringConfig {
        raw.isEmpty ? ScoringConfig() : ScoringConfig.parse(raw)
    }

    private func update(_ mutate: (inout SecurityScoreWeights) -> Void) {
        var c = config
        mutate(&c.weights)
        raw = c.serialize()
    }

    var body: some View {
        // Read once per body evaluation — `config` re-parses `raw` on every
        // access, and this view reads it 9 times (8 weight rows + totalWeight).
        let config = self.config
        let totalWeight = Self.totalWeight(config)
        return VStack(alignment: .leading, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionHeader(title: "Security Score Weights")
                        Spacer()
                        Pill(
                            text: "Sum: \(Int(totalWeight))",
                            tone: totalWeight == 100 ? .teal : .gold,
                            icon: totalWeight == 100 ? "checkmark" : "scalemass"
                        )
                        PNPButton(title: "Reset to v3.5 defaults", size: .sm) {
                            raw = ""
                        }
                        .help("Restore the eight default weights from the v3.5 production script.")
                    }
                    Text("These weights drive the Security Score on the Security Posture screen. " +
                         "Set a weight to 0 to drop that metric entirely. Missing metrics in your " +
                         "data are auto-renormalized so the score still scales to 100.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                    VStack(spacing: 6) {
                        weightRow("FileVault Encryption",
                                  value: Binding(get: { Int(config.weights.fileVault) },
                                                 set: { v in update { $0.fileVault = Double(v) } }))
                        weightRow("System Integrity Protection",
                                  value: Binding(get: { Int(config.weights.sip) },
                                                 set: { v in update { $0.sip = Double(v) } }))
                        weightRow("Firewall Enabled",
                                  value: Binding(get: { Int(config.weights.firewall) },
                                                 set: { v in update { $0.firewall = Double(v) } }))
                        weightRow("\(workspace.edrAgentName ?? "EDR Agent") Connected",
                                  value: Binding(get: { Int(config.weights.edrAgent) },
                                                 set: { v in update { $0.edrAgent = Double(v) } }))
                        weightRow("mSCP Compliance",
                                  value: Binding(get: { Int(config.weights.mscp) },
                                                 set: { v in update { $0.mscp = Double(v) } }))
                        weightRow("XProtect Current",
                                  value: Binding(get: { Int(config.weights.xprotect) },
                                                 set: { v in update { $0.xprotect = Double(v) } }))
                        weightRow("CVE Clean",
                                  value: Binding(get: { Int(config.weights.cve) },
                                                 set: { v in update { $0.cve = Double(v) } }))
                        weightRow("Secure Boot (Full)",
                                  value: Binding(get: { Int(config.weights.secureBoot) },
                                                 set: { v in update { $0.secureBoot = Double(v) } }))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Security score weight configuration")
        }
    }

    private static func totalWeight(_ config: ScoringConfig) -> Double {
        let w = config.weights
        return w.fileVault + w.sip + w.firewall + w.edrAgent +
               w.mscp + w.xprotect + w.cve + w.secureBoot
    }

    @ViewBuilder
    private func weightRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg)
            Spacer()
            EditableNumberStepper(value: value, range: 0...100, suffix: "pts")
                .accessibilityLabel("\(label) weight")
                .accessibilityValue("\(value.wrappedValue) points out of 100")
        }
    }
}

