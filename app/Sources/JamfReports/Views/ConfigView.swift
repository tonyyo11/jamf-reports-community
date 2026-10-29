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

    enum ConfigTab: String, CaseIterable {
        case agents, eas, thresholds, platform, output, scoring, fromFile
        var label: String {
            switch self {
            case .agents:     "Security Agents"
            case .eas:        "Custom EAs"
            case .thresholds: "Thresholds"
            case .platform:   "Platform API"
            case .output:     "Output & Branding"
            case .scoring:    "Scoring"
            case .fromFile:   "From config.yaml"
            }
        }
        var icon: String {
            switch self {
            case .agents:     "shield"
            case .eas:        "sparkles"
            case .thresholds: "bolt"
            case .platform:   "arrow.triangle.branch"
            case .output:     "folder"
            case .scoring:    "scalemass"
            case .fromFile:   "doc.text"
            }
        }
        /// Lets the strip fit PageScaffold.minSupportedWidth when the full labels do not.
        var shortLabel: String {
            switch self {
            case .agents:   "Agents"
            case .eas:      "EAs"
            case .platform: "Platform"
            case .output:   "Output"
            case .fromFile: "From file"
            default:        label
            }
        }

        /// The tabs a workspace can use. Jamf School has no security agents, Extension
        /// Attributes, Platform API or score, so it keeps Thresholds, Output and the file view.
        static func offered(school: Bool) -> [ConfigTab] {
            school ? [.thresholds, .output, .fromFile] : allCases
        }
    }

    // MARK: Save-status feedback pill

    enum SaveStatus: Equatable {
        case idle, saving, saved, error(String)
    }

    @State private var tab: ConfigTab = .agents
    @State private var saveStatus: SaveStatus = .idle
    @State private var saveTask: Task<Void, Never>?
    /// Key-path detail from the report engine's strict parse, when it fails
    /// on a file the lenient GUI editor tolerates (#181 recovery card).
    @State private var engineParseDetail: String?
    /// `Line N: …` for each line the YAML reader did not take as written.
    @State private var parseNotes: [String] = []
    @State private var showRestoreConfirm = false
    /// A Save found config.yaml changed since the screen read it, and wrote nothing.
    @State private var changedOnDisk = false
    /// What the last Save left as typed.
    @State private var saveReport: ConfigSaveReport?
    /// What config.yaml holds that the other tabs do not edit, for the From config.yaml tab.
    @State private var fileReading: ConfigFileReading = .sections(ConfigFileSections())
    /// config.yaml exists, whether or not the tab could read it.
    @State private var canRevealFile = false

    var body: some View {
        PageScaffold(spacing: 16) {
            header
            tabStrip
            if let problem = configProblem {
                configRecoveryCard(problem)
            }
            // The From config.yaml tab lists the skipped lines itself.
            let bannerNotes = tab == .fromFile ? [] : parseNotes
            if !workspace.configRepairedKeys.isEmpty || !bannerNotes.isEmpty {
                configHealedKeysCard(workspace.configRepairedKeys, notes: bannerNotes)
            }
            if let notice = Self.saveNotice(changedOnDisk: changedOnDisk, report: saveReport) {
                saveNoticeCard(notice)
            }
            tabContent
        }
        .task(id: workspace.profile) {
            changedOnDisk = false
            saveReport = nil
            do {
                try await workspace.loadConfig()
            } catch {
                workspace.configError = error.localizedDescription
            }
            refreshEngineParseStatus()
        }
        .onChange(of: tab) { _, selected in
            if selected == .fromFile { refreshFileReading() }
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
                + "values back. Rebuild quickly with Adopt EAs in Data Sources."
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
    /// still breaks report generation, so both checks matter. Also lists the
    /// lines the reader did not take as written, for the healed-keys card.
    private func refreshEngineParseStatus() {
        refreshFileReading()
        guard !workspace.demoMode,
              let url = ProfileService.workspaceURL(for: workspace.profile)?
                  .appendingPathComponent("config.yaml"),
              FileManager.default.fileExists(atPath: url.path) else {
            engineParseDetail = nil
            parseNotes = []
            return
        }
        parseNotes = ((try? ConfigLoader.readText(at: url))
            .flatMap { try? YAMLCodec.decode($0) }?.parseNotes ?? []).map(\.display)
        do {
            _ = try ConfigLoader.load(from: url)
            engineParseDetail = nil
        } catch let error as ConfigLoader.LoadError {
            engineParseDetail = error.keyPathDetail ?? error.localizedDescription
        } catch {
            engineParseDetail = error.localizedDescription
        }
    }

    private var configFileURL: URL? {
        ProfileService.workspaceURL(for: workspace.profile)?
            .appendingPathComponent("config.yaml")
    }

    /// Re-reads config.yaml for the From config.yaml tab only; the editors keep their state.
    private func refreshFileReading() {
        fileReading = ConfigFileReading.read(at: configFileURL, demoMode: workspace.demoMode)
        canRevealFile = ConfigFileReading.canReveal(at: configFileURL, demoMode: workspace.demoMode)
    }

    private func revealConfigFile() {
        guard !workspace.demoMode, let url = configFileURL else { return }
        SystemActions.reveal(url)
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
    /// sequence items on load, or read some lines other than as written. Not a
    /// parse failure — the file is still readable. Saving heals the repaired
    /// keys only, so the Save button shows only for them.
    private func configHealedKeysCard(_ keys: [String], notes: [String]) -> some View {
        let text = Self.readerCardText(keys: keys, notes: notes)
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(Theme.Colors.warn)
                        .accessibilityHidden(true)
                    Text(text.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Pill(text: text.pill, tone: .warn)
                }
                Text(text.summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Mono(text: text.detail, size: 11.5, color: Theme.Colors.warnSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(text.detail)
                if !keys.isEmpty {
                    PNPButton(title: "Save now", icon: "checkmark", style: .gold, size: .sm) {
                        save()
                    }
                }
            }
        }
    }

    /// The healed-keys card's text, for repaired keys, `Line N: …` parse notes, or both. Notes
    /// past 20 are counted rather than listed.
    static func readerCardText(
        keys: [String], notes: [String]
    ) -> (title: String, pill: String, summary: String, detail: String) {
        func count(_ n: Int, _ noun: String) -> String? {
            n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
        let shown = notes.prefix(20) + (notes.count > 20 ? ["…and \(notes.count - 20) more"] : [])
        let summary = [
            keys.isEmpty ? nil : "The following YAML keys had malformed sequence items that were "
                + "auto-reattached. The file reads correctly but is still malformed on disk. "
                + "Save from this screen to persist the cleanup.",
            notes.isEmpty ? nil : "The app did not read the lines below as written. "
                + "Correct them in config.yaml.",
        ]
        return (
            title: keys.isEmpty
                ? "Some lines in config.yaml were not read as written"
                : "Config auto-healed on load",
            pill: [count(keys.count, "key"), count(notes.count, "line")].compactMap { $0 }
                .joined(separator: " · "),
            summary: summary.compactMap { $0 }.joined(separator: " "),
            detail: [keys.isEmpty ? nil : keys.joined(separator: ", "),
                     shown.isEmpty ? nil : shown.joined(separator: "\n")]
                .compactMap { $0 }.joined(separator: "\n")
        )
    }

    /// What the last Save could not do, or nil when there is nothing to say.
    static func saveNotice(
        changedOnDisk: Bool, report: ConfigSaveReport?
    ) -> (title: String, lines: [String])? {
        if changedOnDisk {
            return (
                title: "Not saved",
                lines: ["config.yaml changed on disk since this screen loaded it. Reload reads "
                    + "the file again and discards the changes you have not saved here."]
            )
        }
        let lines = report?.notes ?? []
        return lines.isEmpty ? nil : (title: "Saved with notes", lines: lines)
    }

    private func saveNoticeCard(_ notice: (title: String, lines: [String])) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warn)
                        .accessibilityHidden(true)
                    Text(notice.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                }
                ForEach(notice.lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if changedOnDisk {
                    PNPButton(title: "Reload", icon: "arrow.clockwise", size: .sm) { reload() }
                }
            }
        }
    }

    /// Reads config.yaml again, dropping the edits not yet saved; the notice says so.
    private func reload() {
        Task { @MainActor in
            do {
                try await workspace.loadConfig()
            } catch {
                workspace.configError = error.localizedDescription
            }
            changedOnDisk = false
            saveReport = nil
            refreshEngineParseStatus()
        }
    }

    // MARK: Tab strip

    /// Full labels need ~804 pt; the page has 672 at the minimum window with the
    /// sidebar expanded, and a wider row pushes the sidebar off the window.
    private var tabStrip: some View {
        ViewThatFits(in: .horizontal) {
            segments(\.label)
            segments(\.shortLabel)
            ScrollView(.horizontal, showsIndicators: false) { segments(\.shortLabel) }
        }
    }

    private func segments(_ label: KeyPath<ConfigTab, String>) -> some View {
        SegmentedControl(
            selection: Binding(get: { shownTab }, set: { tab = $0 }),
            options: offeredTabs.map { ($0, $0[keyPath: label], $0.icon) }
        )
    }

    // MARK: Header

    private var header: some View {
        PageHeader(
            kicker: "Workspace · \(workspace.profile)",
            title: "config.yaml",
            subtitle: configDisplayPath
        ) {
            AnyView(
                HStack(spacing: 8) {
                    if workspace.hasUnsavedChanges && saveStatus == .idle {
                        Pill(text: "Unsaved changes", tone: .warn, icon: "pencil")
                            .transition(.opacity)
                    }
                    saveStatusPill
                    PNPButton(title: "View YAML", icon: "chevron.left.forwardslash.chevron.right", action: viewYAML)
                        .disabled(workspace.demoMode)
                        .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                    // Demo edits apply on screen but have no file to be saved to.
                    PNPButton(title: "Save", icon: "checkmark", style: .gold, action: save)
                        .disabled(workspace.demoMode)
                        .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                }
            )
        }
    }

    /// The demo's own path, not this Mac's root, which may have been moved.
    private var configDisplayPath: String {
        workspace.demoMode
            ? DemoData.workspaceDisplayPath(profile: workspace.profile, subpath: "config.yaml")
            : WorkspaceRootStore.displayPath(profile: workspace.profile, subpath: "config.yaml")
    }

    private func viewYAML() {
        guard !workspace.demoMode else { return }
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
            // The message goes in the tooltip and a toast: Pill is fixed-size, so a
            // long error here widened the header past the window.
            Pill(text: "save failed", tone: .danger, icon: "exclamationmark.triangle")
                .help(msg)
                .transition(.opacity)
        case .saving:
            Pill(text: "saving…", tone: .muted)
                .transition(.opacity)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Tab routing

    private var offeredTabs: [ConfigTab] {
        ConfigTab.offered(school: workspace.isSchoolWorkspace)
    }

    /// The selected tab, or the first offered one when the workspace does not offer it.
    private var shownTab: ConfigTab {
        offeredTabs.contains(tab) ? tab : offeredTabs[0]
    }

    @ViewBuilder
    private var tabContent: some View {
        switch shownTab {
        case .agents:     AgentsTab()
        case .eas:        EasTab()
        case .thresholds: ThresholdsTab()
        case .platform:   PlatformTab()
        case .output:     OutputTab()
        case .scoring:    ScoringTab()
        case .fromFile:
            ConfigFromFileTab(
                reading: fileReading, isDemo: workspace.demoMode, canReveal: canRevealFile,
                reveal: revealConfigFile, reload: refreshEngineParseStatus)
        }
    }

    // MARK: Button actions

    private func save() {
        guard !workspace.demoMode else { return }
        saveTask?.cancel()
        saveStatus = .saving
        saveTask = Task { @MainActor in
            do {
                saveReport = try await workspace.saveConfig()
                changedOnDisk = false
                // A save rewrites the blocks this screen edits; re-read what the card lists.
                refreshEngineParseStatus()
                withMotionSafeAnimation { saveStatus = .saved }
            } catch ConfigService.ConfigError.changedOnDisk {
                // Nothing was written: the notice says why and offers Reload.
                changedOnDisk = true
                saveStatus = .idle
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                withMotionSafeAnimation { saveStatus = .error(message) }
                workspace.toast = Toast(message: "Save failed: \(message)", style: .danger)
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withMotionSafeAnimation { saveStatus = .idle }
        }
    }
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

    /// Mirrors `agentRow`: same spacing, the same fixed 140 and 36 point columns, so each
    /// title sits over its field.
    private var agentsHeader: some View {
        HStack(spacing: 8) {
            tableHeaderCell("Agent Name",      width: nil)
            tableHeaderCell("EA Column",       width: nil)
            tableHeaderCell("Connected Value", width: 140)
            Color.clear.frame(width: 36, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A fixed-width title when `width` is set, else one that shares the row's spare width.
    /// A `maxWidth` cap, as this had, let the title shrink to its text and drift from its field.
    @ViewBuilder
    private func tableHeaderCell(_ title: String, width: CGFloat?) -> some View {
        let label = Text(title)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(Theme.Text.tertiary(contrast))
        if let width {
            label.frame(width: width, alignment: .leading)
        } else {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
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
            // Left flexible, the menu took an equal share of the row beside the two text
            // fields and drew its chevron at the far edge, pushing the columns out of line
            // with the header.
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(
                "Actions for " + (agent.wrappedValue.name.isEmpty ? "agent" : agent.wrappedValue.name))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// Spoken name of an icon-only remove button: what it removes, by name when it has one.
func removeButtonLabel(noun: String, name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Remove \(noun)" : "Remove \(noun) \(trimmed)"
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
        if workspace.isSchoolWorkspace { schoolBody } else { proBody }
    }

    /// Jamf School reports one date per device, its last check-in, so only the stale
    /// threshold applies.
    private var schoolBody: some View {
        @Bindable var ws = workspace
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "General Thresholds").padding(.bottom, 14)
                thresholdField(
                    label: "Stale device threshold", key: "stale_device_days",
                    value: $ws.configState.staleDeviceDays, unit: "days",
                    help: "A device is stale when its last check-in with Jamf School is more "
                        + "than this many days ago"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var proBody: some View {
        @Bindable var ws = workspace
        return HStack(alignment: .top, spacing: 14) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "General Thresholds").padding(.bottom, 14)
                    thresholdField(
                        label: "Stale device threshold", key: "stale_device_days",
                        value: $ws.configState.staleDeviceDays, unit: "days",
                        help: "A device is flagged stale when a date counted below is more than "
                            + "this many days old"
                    )
                    StaleBasisControls()
                    thresholdField(
                        label: "Check-in overdue", key: "checkin_overdue_days",
                        value: $ws.configState.checkinOverdueDays, unit: "days",
                        help: "Check-in Health counts a Mac overdue after this many days"
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
        workspace.profiles.first(where: { $0.name == workspace.profile })?.auth?.isPlatform == true
    }

    var body: some View {
        @Bindable var ws = workspace
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                // The Platform API Gateway went GA in September 2026.
                HStack(alignment: .center, spacing: 10) {
                    SectionHeader(title: "Jamf Platform API")
                    Pill(text: "GA", tone: .teal)
                }
                (Text("Generally available · reached through ")
                 + Text("jamf-cli").font(.caption.monospaced())
                 + Text(" with a Platform Gateway profile."))
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Divider().background(Theme.Hairline.standard)
                if isPlatformProfile {
                    platformReadyCallout
                } else {
                    platformSetupCallout
                }
                Divider().background(Theme.Hairline.standard)
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Compliance benchmarks")
                    ForEach(ws.configState.complianceBenchmarks.indices, id: \.self) { i in
                        let benchmark = safeElementBinding(
                            $ws.configState.complianceBenchmarks, i, default: "")
                        HStack(spacing: 8) {
                            PNPTextField(value: benchmark)
                            Button(role: .destructive) { ws.removeComplianceBenchmark(at: i) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Theme.Colors.danger)
                                    .frame(minWidth: 24, minHeight: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                removeButtonLabel(noun: "benchmark", name: benchmark.wrappedValue))
                        }
                    }
                    PNPButton(title: "Add benchmark", icon: "plus", style: .ghost, size: .sm, action: { ws.addComplianceBenchmark() })
                    FieldHelp(text: "Exact titles, case-sensitive. Empty collects every benchmark.")
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
                     + "Collect runs the Platform API reports for it.")
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
                Text("Create an integration in Jamf Account under Integrations, then add it "
                     + "with Settings → Add connection and choose Platform API. That routes "
                     + "Jamf Pro API traffic through the gateway and unlocks the Platform "
                     + "commands these sheets use.")
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
                        detail: "_\(ReportEngine.workbookTimestamp())",
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
                            detail: "jamf_cli.require_manifest — hard-fail on tampered "
                                + "(mismatched or corrupt) snapshots; missing/legacy manifests "
                                + "are tolerated",
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
                        // The swatch is the colour the reports will use: a value that is not
                        // #RGB or #RRGGBB reads as the default, as it does in the reports.
                        colorField(
                            label: "Accent color", value: $ws.configState.accentColor,
                            hexColor: Color(hex: BrandingConfig(
                                accentColor: ws.configState.accentColor).sanitizedAccentRGB))
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
