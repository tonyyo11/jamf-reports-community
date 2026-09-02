import SwiftUI
import AppKit

struct BackupsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var bridge = CLIBridge()
    @State private var backups: [BackupRecord] = []
    @State private var selectedBackups = Set<BackupRecord.ID>()
    @State private var backupLabel = ""
    @State private var backupOutput: [CLIBridge.LogLine] = []
    @State private var diffOutput: [CLIBridge.LogLine] = []
    @State private var diffGroups: [BackupDiffModel.Group] = []
    @State private var diffHeadline = ""
    @State private var diffRawText = ""
    @State private var diffParseFailed = false
    @State private var diffMode: DiffMode = .summary
    @State private var backupExitCode: Int32?
    @State private var diffExitCode: Int32?
    @State private var isRunningBackup = false
    @State private var isRunningDiff = false
    @State private var showingDiff = false
    @State private var errorMessage: String?
    @State private var pendingDelete: BackupRecord?
    @State private var showDeleteConfirm = false

    private var backupsDirectory: URL {
        let root = ProfileService.workspaceURL(for: workspace.profile)
            ?? ProfileService.workspacesRoot().appendingPathComponent(workspace.profile)
        return root.appendingPathComponent("backups", isDirectory: true)
    }

    private var latestBackup: BackupRecord? {
        backups.first
    }

    private var diffSelectionHint: String {
        switch selectedBackups.count {
        case 0: "Command-click to select multiple"
        case 1: "Select 1 more to diff"
        case 2: "Ready to diff"
        default: "Select exactly 2 to diff"
        }
    }

    private var shouldShowBackupLogBody: Bool {
        isRunningBackup || !backupOutput.isEmpty || backupExitCode != nil
    }

    var body: some View {
        PageScaffold(spacing: 16) {
            header
            summary
            errorBanner
            backupsTable
            logCard
        }
        .sheet(isPresented: $showingDiff) {
            diffSheet
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Backup", role: .destructive) {
                if let b = pendingDelete { Task { await deleteBackup(b) } }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .task(id: workspace.profile) {
            // Sweep abandoned .tmp-* staging dirs (interrupted backups) before
            // listing — production accumulated one that was months old.
            if !workspace.demoMode {
                let removed = BackupMaintenance.cleanStaleTempDirs(profile: workspace.profile)
                if !removed.isEmpty {
                    workspace.toast = Toast(
                        message: "Removed \(removed.count) abandoned backup staging folder\(removed.count == 1 ? "" : "s")",
                        style: .success
                    )
                }
            }
            reload()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Configuration Backups",
            title: "\(backups.count) backup\(backups.count == 1 ? "" : "s")",
            subtitle: WorkspaceRootStore.displayPath(profile: workspace.profile,
                                                     subpath: "backups") + "/"
        ) {
            AnyView(
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        backupLabelField
                        PNPButton(title: "Reveal in Finder", icon: "folder") {
                            SystemActions.openFolder(backupsDirectory)
                        }
                        .help("Open the backups directory for this workspace in Finder.")
                        Mono(
                            text: diffSelectionHint,
                            size: 10.5,
                            color: selectedBackups.count == 2 ? Theme.Colors.ok : Theme.Text.tertiary(contrast)
                        )
                        PNPButton(
                            title: isRunningDiff ? "Diffing..." : "Diff Selected",
                            icon: "arrow.left.arrow.right",
                            style: .neutral
                        ) {
                            diffSelected()
                        }
                        .disabled(workspace.demoMode || isRunningBackup || isRunningDiff || selectedBackups.count != 2)
                        .help(workspace.demoMode ? "Available in live mode only" : "")
                        PNPButton(
                            title: isRunningBackup ? "Backing Up..." : "New Backup",
                            icon: "externaldrive.badge.plus",
                            style: .gold
                        ) {
                            runBackup()
                        }
                        .disabled(workspace.demoMode || isRunningBackup || isRunningDiff)
                        .help(workspace.demoMode ? "Available in live mode only" : "")
                    }
                }
            )
        }
    }

    private var backupLabelField: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Text.tertiary(contrast))
            TextField("Label", text: $backupLabel)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(Theme.Text.primary)
        }
        .padding(.horizontal, 10)
        .frame(width: 160, height: 30)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                .strokeBorder(Theme.Hairline.strong, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            InlineBanner(icon: "exclamationmark.triangle.fill", tone: .warn) {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
            }
        }
    }

    private var backupsTable: some View {
        Card(padding: 0) {
            if backups.isEmpty {
                emptyState
            } else {
                Table(backups, selection: $selectedBackups) {
                    TableColumn("Backup") { backup in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.label.isEmpty ? backup.name : backup.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Text.primary)
                            if backup.label.isEmpty {
                                Text("No label set")
                                    .font(Theme.Fonts.mono(10.5))
                                    .foregroundStyle(Theme.Text.tertiary(contrast).opacity(0.65))
                            } else {
                                Mono(text: backup.name, size: 10.5)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(backup.accessibilityLabel)
                    }
                    TableColumn("Created") { backup in
                        Mono(text: backup.createdLabel)
                    }
                    TableColumn("Files") { backup in
                        Mono(text: "\(backup.fileCount)")
                    }
                    TableColumn("Size") { backup in
                        Mono(text: backup.sizeLabel)
                    }
                    TableColumn("") { backup in
                        HStack(spacing: 6) {
                            PNPButton(title: "Reveal", icon: "folder", size: .sm) {
                                SystemActions.reveal(backup.url)
                            }
                            PNPButton(title: "Diff Latest", icon: "arrow.left.arrow.right", size: .sm) {
                                diff(backup, against: latestBackup)
                            }
                            .disabled(workspace.demoMode || isRunningDiff || latestBackup?.id == backup.id)
                            .help(workspace.demoMode ? "Available in live mode only" : "")
                            PNPButton(title: "Delete", icon: "trash", style: .danger, size: .sm) {
                                pendingDelete = backup
                                showDeleteConfirm = true
                            }
                            .disabled(workspace.demoMode || isRunningBackup)
                            .help(workspace.demoMode ? "Available in live mode only" : "Delete this backup")
                            .accessibilityHint("Shows a confirmation dialog to delete this backup")
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { SystemActions.reveal(backup.url) }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                pendingDelete = backup
                                showDeleteConfirm = true
                            }
                        }
                    }
                }
                .frame(minHeight: 390)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "externaldrive",
            title: "No backups yet",
            message: "Backups are created by scheduled or manual backup runs. "
                + "Create a restore point before making config changes.",
            primaryAction: EmptyStateAction(
                label: "New Backup",
                icon: "externaldrive.badge.plus"
            ) { runBackup() }
        )
        .disabled(workspace.demoMode || isRunningBackup)
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(20)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(label: "Backups", value: "\(backups.count)", sub: "Configuration snapshots")
            StatTile(label: "Disk used", value: FileDisplay.size(totalBytes), sub: "JSON backup files")
            StatTile(label: "Latest", value: latestBackup?.createdLabel ?? "None", sub: latestBackup?.name ?? "No backup")
            StatTile(label: "Selected", value: "\(selectedBackups.count)", sub: "Choose two to diff")
        }
    }

    private var totalBytes: Int64 {
        backups.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var logCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(Theme.Colors.gold)
                    Mono(text: isRunningBackup ? "Backup running" : "Backup output", color: Theme.Text.secondary)
                    if !shouldShowBackupLogBody {
                        Mono(text: "No output yet.", size: 10.5)
                    }
                    Spacer()
                    if let backupExitCode {
                        Pill(text: "EXIT \(backupExitCode)", tone: backupExitCode == 0 ? .teal : .danger)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if shouldShowBackupLogBody {
                    Divider().background(Theme.Hairline.strong)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(backupOutput) { line in
                            Text(line.text)
                                .font(Theme.Fonts.mono(11.5))
                                .foregroundStyle(color(for: line.level))
                        }
                    }
                    .padding(14)
                }
            }
            .background(Theme.Colors.codeBG)
        }
    }

    private var diffSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionHeader(title: "Backup Diff")
                Spacer()
                if let diffExitCode {
                    Pill(text: "EXIT \(diffExitCode)", tone: diffExitCode == 0 ? .teal : .danger)
                }
                PNPButton(title: "Copy", icon: "doc.on.doc", size: .sm) {
                    copyDiffToPasteboard()
                }
                .disabled(diffOutput.isEmpty)
                .accessibilityLabel("Copy the whole diff to the clipboard")
                PNPButton(title: "Done", size: .sm) {
                    showingDiff = false
                }
                .keyboardShortcut(.cancelAction)
            }
            if !diffParseFailed && !diffGroups.isEmpty {
                HStack(spacing: 10) {
                    Text(diffHeadline)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.secondary)
                    Spacer()
                    SegmentedControl(
                        selection: $diffMode,
                        options: [(DiffMode.summary, "Summary", nil), (DiffMode.raw, "Raw", nil)]
                    )
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if isRunningDiff && diffGroups.isEmpty && diffRawText.isEmpty {
                        Text("Running diff\u{2026}")
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else if diffMode == .summary && !diffParseFailed {
                        diffSummaryBody
                    } else {
                        diffRawBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Selection belongs on the container: a per-Text modifier scopes
                // each drag to one line, which is why select-all never worked.
                .textSelection(.enabled)
            }
            .background(Theme.Colors.codeBG, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(22)
        .frame(width: 760, height: 520)
        .background(Theme.Surface.base)
    }

    private enum DiffMode: Hashable { case summary, raw }

    @ViewBuilder
    private var diffSummaryBody: some View {
        if diffGroups.isEmpty {
            Text("No differences between these backups.")
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .padding(8)
        } else {
            ForEach(diffGroups) { group in
                DiffGroupView(group: group)
            }
        }
    }

    @ViewBuilder
    private var diffRawBody: some View {
        if diffRawText.isEmpty {
            ForEach(diffOutput) { line in
                DiffLineView(text: line.text, fallbackColor: color(for: line.level))
            }
        } else {
            if diffParseFailed {
                Text("Could not read this as a structured diff \u{2014} showing raw output.")
                    .font(Theme.Fonts.mono(11.5))
                    .foregroundStyle(Theme.Colors.warn)
                    .padding(.horizontal, 6)
            }
            Text(diffRawText)
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Decode the captured payload into the collapsed view. A payload that
    /// isn't the expected JSON array falls back to Raw rather than rendering an
    /// empty summary, which would read as "no differences".
    private func applyDiffPayload(_ payload: Data) {
        diffRawText = String(data: payload, encoding: .utf8) ?? ""
        guard let items = BackupDiffModel.parse(payload) else {
            diffParseFailed = true
            diffGroups = []
            diffHeadline = ""
            diffMode = .raw
            return
        }
        diffParseFailed = false
        diffGroups = BackupDiffModel.group(items)
        diffHeadline = BackupDiffModel.headline(items)
        diffMode = .summary
    }

    /// Copies whatever the operator is looking at: the collapsed summary is
    /// what goes in a ticket, the raw payload is what goes to a script.
    private func copyDiffToPasteboard() {
        let text = diffMode == .summary && !diffParseFailed
            ? BackupDiffModel.plainText(diffGroups)
            : diffRawText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runBackup() {
        let profile = workspace.profile
        let label = backupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        backupOutput.removeAll()
        backupExitCode = nil
        errorMessage = nil
        isRunningBackup = true
        Task {
            let exit: Int32
            do {
                exit = try await bridge.backup(profile: profile, label: label.isEmpty ? nil : label) { line in
                    Task { @MainActor in backupOutput.append(line) }
                }
            } catch {
                backupExitCode = -1
                isRunningBackup = false
                errorMessage = "Backup failed: \(error.localizedDescription)"
                return
            }
            backupExitCode = exit
            isRunningBackup = false
            if exit == 0 {
                backupLabel = ""
                reload()
            } else {
                errorMessage = CLIBridge.explainExit(exit, operation: "Backup for \(profile)")
            }
        }
    }

    private func diffSelected() {
        let selected = backups.filter { selectedBackups.contains($0.id) }
            .sorted { $0.created < $1.created }
        guard selected.count == 2 else { return }
        diff(selected[0], against: selected[1])
    }

    private func diff(_ backup: BackupRecord, against latest: BackupRecord?) {
        guard let latest, latest.id != backup.id else { return }
        diffOutput.removeAll()
        diffGroups = []
        diffHeadline = ""
        diffRawText = ""
        diffParseFailed = false
        diffMode = .summary
        diffExitCode = nil
        errorMessage = nil
        showingDiff = true
        isRunningDiff = true
        Task {
            let result: (exitCode: Int32, payload: Data)
            do {
                result = try await bridge.diffBackups(
                    profile: workspace.profile,
                    left: backup.url,
                    right: latest.url
                ) { line in
                    Task { @MainActor in diffOutput.append(line) }
                }
            } catch {
                diffExitCode = -1
                isRunningDiff = false
                errorMessage = "Backup diff failed: \(error.localizedDescription)"
                return
            }
            applyDiffPayload(result.payload)
            diffExitCode = result.exitCode
            isRunningDiff = false
            if result.exitCode != 0 {
                errorMessage = CLIBridge.explainExit(result.exitCode, operation: "Backup diff")
            }
        }
    }

    private func reload() {
        backups = BackupLibrary().list(profile: workspace.profile)
        selectedBackups = selectedBackups.intersection(Set(backups.map(\.id)))
    }

    @MainActor
    private func deleteBackup(_ backup: BackupRecord) async {
        do {
            try FileManager.default.removeItem(at: backup.url)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func color(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Text.secondary
        case .ok: Theme.Colors.ok
        case .warn: Theme.Colors.warn
        case .fail: Theme.Colors.danger
        }
    }
}

private struct DiffLineView: View {
    let text: String
    let fallbackColor: Color
    @Environment(\.colorSchemeContrast) private var contrast

    private var kind: DiffKind {
        if text.hasPrefix("@@") { return .hunk }
        if text.hasPrefix("+++") || text.hasPrefix("---") { return .fileHeader }
        if text.hasPrefix("+") { return .addition }
        if text.hasPrefix("-") { return .deletion }
        return .unchanged
    }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.mono(11.5))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
    }

    private var foreground: Color {
        switch kind {
        case .addition: Theme.Colors.ok
        case .deletion: Theme.Colors.danger
        case .hunk: Theme.Colors.goldBright
        case .fileHeader: Theme.Text.secondary
        case .unchanged: text.hasPrefix("[") ? fallbackColor : Theme.Text.tertiary(contrast)
        }
    }

    private var background: Color {
        switch kind {
        case .addition: Theme.Colors.ok.opacity(0.10)
        case .deletion: Theme.Colors.danger.opacity(0.10)
        case .hunk: Theme.Colors.gold.opacity(0.10)
        case .fileHeader, .unchanged: .clear
        }
    }

    private enum DiffKind {
        case addition, deletion, unchanged, hunk, fileHeader
    }
}

private struct BackupLibrary {
    func list(profile: String) -> [BackupRecord] {
        guard let root = WorkspacePathGuard.root(for: profile) else { return [] }
        let backupsRoot = root.appendingPathComponent("backups", isDirectory: true)
        guard let validatedRoot = WorkspacePathGuard.validate(backupsRoot, under: root),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: validatedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { record(from: $0, root: root) }
            .sorted { $0.created > $1.created }
    }

    private func record(from url: URL, root: URL) -> BackupRecord? {
        guard let dir = WorkspacePathGuard.validate(url, under: root) else { return nil }
        let manifest = readManifest(dir.appendingPathComponent("manifest.json"), root: root)
        let stats = directoryStats(dir, root: root)
        let created = manifest.created
            ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
        return BackupRecord(
            name: dir.lastPathComponent,
            label: manifest.label,
            created: created,
            sizeBytes: manifest.sizeBytes ?? stats.sizeBytes,
            fileCount: manifest.fileCount ?? stats.fileCount,
            url: dir
        )
    }

    private func readManifest(_ url: URL, root: URL) -> BackupManifest {
        guard let file = WorkspacePathGuard.validate(url, under: root),
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BackupManifest()
        }
        return BackupManifest(
            label: object["label"] as? String ?? "",
            created: parseDate(object["created_at"] as? String),
            fileCount: object["file_count"] as? Int,
            sizeBytes: object["size_bytes"] as? Int64
        )
    }

    private func directoryStats(_ url: URL, root: URL) -> (fileCount: Int, sizeBytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var fileCount = 0
        var sizeBytes: Int64 = 0
        for case let item as URL in enumerator {
            guard WorkspacePathGuard.validate(item, under: root) != nil,
                  let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            fileCount += 1
            sizeBytes += Int64(values.fileSize ?? 0)
        }
        return (fileCount, sizeBytes)
    }

    private func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private struct BackupManifest {
        var label = ""
        var created: Date?
        var fileCount: Int?
        var sizeBytes: Int64?
    }
}

/// One collapsed group of identical changes: the resource and object count,
/// the leaf changes themselves, and the affected object names behind a
/// disclosure so a 47-object group stays one line until asked.
private struct DiffGroupView: View {
    let group: BackupDiffModel.Group
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showNames = false

    private func variantLabel(_ variant: BackupDiffModel.Variant) -> String {
        let shown = variant.names.prefix(3).joined(separator: ", ")
        let rest = variant.names.count - min(3, variant.names.count)
        return rest > 0 ? "\(shown) +\(rest) more" : shown
    }

    @ViewBuilder
    private func changeRow(_ change: BackupDiffModel.Change) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(change.path.isEmpty ? "(value)" : change.path)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Text.secondary)
            Text(change.old ?? "—")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.danger)
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Text(change.new ?? "—")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.ok)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.resource)
                    .font(Theme.Fonts.mono(11.5).weight(.semibold))
                    .foregroundStyle(Theme.Colors.goldBright)
                Text(group.change)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(group.names.count == 1 ? "1 object" : "\(group.names.count) objects")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.secondary)
            }

            // Members share one change: render it once.
            ForEach(Array(group.changes.enumerated()), id: \.offset) { _, change in
                changeRow(change).padding(.leading, 12)
            }

            // Members changed the same field to different values: name the field
            // once, then one line per value, rather than one card per object.
            if !group.variants.isEmpty {
                Text(group.fields.map { $0.isEmpty ? "(value)" : $0 }.joined(separator: ", "))
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.secondary)
                    .padding(.leading, 12)
                ForEach(Array(group.variants.enumerated()), id: \.offset) { _, variant in
                    HStack(alignment: .top, spacing: 6) {
                        // Cap the inline name list: a variant can legitimately
                        // cover a hundred-plus objects, and joining those into
                        // one line would clip to meaningless text. The full list
                        // is under "Show objects".
                        Text(variantLabel(variant))
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .frame(maxWidth: 220, alignment: .leading)
                        Text(
                            variant.changes.map { $0.new ?? $0.old ?? "—" }
                                .joined(separator: "; ")
                        )
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.Colors.ok)
                    }
                    .padding(.leading, 24)
                }
            }

            if group.truncated {
                Text("… more changes in this object than shown; use Raw for the full payload")
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .padding(.leading, 12)
            }
            // Only when the value really is an unreadable blob. A short scalar
            // swap renders as a normal before/after row and needs no excuse.
            if group.opaque {
                Text("value replaced — too long to show inline; use Raw")
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .padding(.leading, 12)
            }

            Button {
                showNames.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showNames ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(showNames ? "Hide objects" : "Show objects")
                        .font(Theme.Fonts.mono(10.5))
                }
                .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .accessibilityLabel(showNames
                ? "Hide the objects changed in \(group.resource)"
                : "Show the objects changed in \(group.resource)")

            if showNames {
                Text(group.names.joined(separator: ", "))
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Text.secondary)
                    .padding(.leading, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
