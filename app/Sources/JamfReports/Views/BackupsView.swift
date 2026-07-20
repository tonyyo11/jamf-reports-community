import SwiftUI

struct BackupsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var bridge = CLIBridge()
    @State private var backups: [BackupRecord] = []
    @State private var selectedBackups = Set<BackupRecord.ID>()
    @State private var backupLabel = ""
    @State private var backupOutput: [CLIBridge.LogLine] = []
    @State private var diffOutput: [CLIBridge.LogLine] = []
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
            subtitle: "~/Jamf-Reports/\(workspace.profile)/backups/"
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
            HStack {
                SectionHeader(title: "Backup Diff")
                Spacer()
                if let diffExitCode {
                    Pill(text: "EXIT \(diffExitCode)", tone: diffExitCode == 0 ? .teal : .danger)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if diffOutput.isEmpty {
                        Text("No diff output.")
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        ForEach(diffOutput) { line in
                            DiffLineView(text: line.text, fallbackColor: color(for: line.level))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Colors.codeBG, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(22)
        .frame(width: 760, height: 520)
        .background(Theme.Surface.base)
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
        diffExitCode = nil
        errorMessage = nil
        showingDiff = true
        isRunningDiff = true
        Task {
            let exit: Int32
            do {
                exit = try await bridge.diffBackups(
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
            diffExitCode = exit
            isRunningDiff = false
            if exit != 0 {
                errorMessage = CLIBridge.explainExit(exit, operation: "Backup diff")
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
            .textSelection(.enabled)
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
