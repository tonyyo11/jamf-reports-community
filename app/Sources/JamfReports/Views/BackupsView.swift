import SwiftUI

struct BackupsView: View {
    @Environment(WorkspaceStore.self) private var workspace
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

    private var backupsDirectory: URL {
        let root = ProfileService.workspaceURL(for: workspace.profile)
            ?? ProfileService.workspacesRoot().appendingPathComponent(workspace.profile)
        return root.appendingPathComponent("backups", isDirectory: true)
    }

    private var latestBackup: BackupRecord? {
        backups.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                errorBanner
                backupsTable
                summary
                logCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .sheet(isPresented: $showingDiff) {
            diffSheet
        }
        .task(id: workspace.profile) {
            reload()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Configuration Backups",
            title: "\(backups.count) backups",
            subtitle: "~/Jamf-Reports/\(workspace.profile)/backups/"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    backupLabelField
                    PNPButton(title: "Reveal in Finder", icon: "folder") {
                        SystemActions.openFolder(backupsDirectory)
                    }
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
            )
        }
    }

    private var backupLabelField: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.fgMuted)
            TextField("Label", text: $backupLabel)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.fg)
        }
        .padding(.horizontal, 10)
        .frame(width: 160, height: 30)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.fg2)
                Spacer()
            }
            .padding(12)
            .background(Theme.Colors.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Colors.warn.opacity(0.35), lineWidth: 0.5)
            )
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
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Mono(text: backup.name, size: 10.5)
                        }
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
                        }
                    }
                }
                .frame(minHeight: 390)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Colors.gold)
            Text("No backups yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
            Text("Run New Backup to create the first configuration snapshot.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
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
                    Mono(text: isRunningBackup ? "jrc backup running" : "jrc backup output", color: Theme.Colors.fg2)
                    Spacer()
                    if let backupExitCode {
                        Pill(text: "EXIT \(backupExitCode)", tone: backupExitCode == 0 ? .teal : .danger)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().background(Theme.Colors.hairlineStrong)
                VStack(alignment: .leading, spacing: 4) {
                    if backupOutput.isEmpty {
                        Text("No output yet.")
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    } else {
                        ForEach(backupOutput) { line in
                            Text(line.text)
                                .font(Theme.Fonts.mono(11.5))
                                .foregroundStyle(color(for: line.level))
                        }
                    }
                }
                .padding(14)
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
                            .foregroundStyle(Theme.Colors.fgMuted)
                    } else {
                        ForEach(diffOutput) { line in
                            Text(line.text)
                                .font(Theme.Fonts.mono(11.5))
                                .foregroundStyle(color(for: line.level))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Colors.codeBG, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(22)
        .frame(width: 760, height: 520)
        .background(Theme.Colors.winBG)
    }

    private func runBackup() {
        let profile = workspace.profile
        let label = backupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        backupOutput.removeAll()
        backupExitCode = nil
        errorMessage = nil
        isRunningBackup = true
        Task {
            let exit = await bridge.backup(profile: profile, label: label.isEmpty ? nil : label) { line in
                Task { @MainActor in backupOutput.append(line) }
            }
            backupExitCode = exit
            isRunningBackup = false
            if exit == 0 {
                backupLabel = ""
                reload()
            } else {
                errorMessage = "Backup failed for \(profile) with exit \(exit)."
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
            let exit = await bridge.diffBackups(
                profile: workspace.profile,
                left: backup.url,
                right: latest.url
            ) { line in
                Task { @MainActor in diffOutput.append(line) }
            }
            diffExitCode = exit
            isRunningDiff = false
            if exit != 0 {
                errorMessage = "Backup diff failed with exit \(exit)."
            }
        }
    }

    private func reload() {
        backups = BackupLibrary().list(profile: workspace.profile)
        selectedBackups = selectedBackups.intersection(Set(backups.map(\.id)))
    }

    private func color(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Colors.fg2
        case .ok: Theme.Colors.ok
        case .warn: Theme.Colors.warn
        case .fail: Theme.Colors.danger
        }
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
