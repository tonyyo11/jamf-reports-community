import SwiftUI

struct SourcesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var csvFiles: [InboxFile] = []
    @State private var families: [SnapshotFamily] = []
    @State private var inboxWatcher = CSVInboxService.DirectoryWatcher()
    @State private var pendingClearFile: InboxFile?
    @State private var pendingClearProfile: String?
    @State private var showClearConfirm = false
    @State private var clearError: String?
    @State private var showClearError = false
    @State private var resolutionError: String?

    private struct CLICommand: Identifiable {
        let id = UUID()
        let label: String
        let status: String
    }

    private struct CLICommandDefinition {
        let label: String
        let cacheNames: [String]
    }

    private let cliCommandDefinitions: [CLICommandDefinition] = [
        .init(label: "pro overview",                cacheNames: ["overview"]),
        .init(
            label: "pro computers list",
            cacheNames: ["computers-list", "computers_list"]
        ),
        .init(label: "pro report ea-results --all", cacheNames: ["ea-results", "ea_results"]),
        .init(label: "pro report patch-status",     cacheNames: ["patch-status", "patch_status"]),
        .init(label: "pro report app-status",       cacheNames: ["app-status", "app_status"]),
        .init(label: "pro report update-status",    cacheNames: ["update-status", "update_status"]),
        .init(
            label: "protect overview",
            cacheNames: ["protect-overview", "protect_overview"]
        ),
    ]

    private var cliCommands: [CLICommand] {
        cliCommandDefinitions.map { definition in
            CLICommand(label: definition.label, status: cacheStatus(for: definition.cacheNames))
        }
    }

    private var cachedCLICommandCount: Int {
        cliCommandDefinitions.filter { latestCacheDate(for: $0.cacheNames) != nil }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                
                if let error = resolutionError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.danger)
                        Text(error)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.Colors.danger)
                        Spacer()
                    }
                    .padding(12)
                    .background(Theme.Colors.danger.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(alignment: .top, spacing: 14) {
                    cliCard
                    csvCard
                }
                familiesCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .onAppear {
            reload()
            inboxWatcher.start(profile: workspace.profile) {
                reload()
            }
        }
        .onChange(of: workspace.profile) { _, _ in
            pendingClearFile = nil
            pendingClearProfile = nil
            showClearConfirm = false
            reload()
            inboxWatcher.start(profile: workspace.profile) {
                reload()
            }
        }
        .onDisappear {
            inboxWatcher.stop()
        }
        .confirmationDialog(
            "Clear \"\(pendingClearFile?.name ?? "")\"?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear inbox file", role: .destructive) {
                clearPendingFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the CSV file from disk.")
        }
        .alert("Clear Inbox Error", isPresented: $showClearError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clearError ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "Inputs to the workbook", tone: .gold)
            Text("Data Sources")
                .font(Theme.Fonts.serif(26, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text("Live API · cached snapshots · CSV inboxes · historical archives")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
    }

    private var cliCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.Colors.gold)
                        .font(.system(size: 16))
                    SectionHeader(title: "jamf-cli · live")
                    Spacer()
                    Pill(
                        text: cachedCLICommandCount == 0
                            ? "No cache"
                            : "\(cachedCLICommandCount) cached",
                        tone: cachedCLICommandCount == 0 ? .muted : .teal
                    )
                }
                HStack(spacing: 4) {
                    Text("jamf-cli profile")
                    Text(workspace.profile).foregroundStyle(Theme.Colors.goldBright)
                    scopeChip(for: workspace.profile)
                    Text("· cache \(cliCacheDisplayPath)")
                }
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Colors.fgMuted)

                VStack(spacing: 0) {
                    ForEach(Array(cliCommands.enumerated()), id: \.element.id) { idx, c in
                        HStack {
                            Mono(text: c.label, color: Theme.Colors.fg2)
                            Spacer()
                            Text(c.status)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                        .padding(.vertical, 6)
                        if idx < cliCommands.count - 1 {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var csvCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.Colors.tealBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "CSV inbox")
                    Spacer()
                    Pill(text: "\(csvFiles.count) FILES", tone: .muted)
                }
                Mono(text: "~/Jamf-Reports/\(workspace.profile)/csv-inbox/")

                if csvFiles.isEmpty {
                    emptyCSVState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(csvFiles.enumerated()), id: \.element.id) { idx, f in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(
                                        f.status == .pending
                                            ? Theme.Colors.gold
                                            : Theme.Colors.fgMuted
                                    )
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Mono(text: f.name, color: Theme.Colors.fg2)
                                    Mono(
                                        text: "\(FileDisplay.date(f.mtime)) · \(f.size)",
                                        size: 10.5
                                    )
                                }
                                Spacer()
                                Pill(text: f.status.rawValue, tone: tone(for: f.status))
                                Menu {
                                    Button(role: .destructive) {
                                        pendingClearFile = f
                                        pendingClearProfile = workspace.profile
                                        showClearConfirm = true
                                    } label: {
                                        Label("Clear inbox file", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(Theme.Colors.fgMuted)
                                        .font(.system(size: 14))
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 8)
                            if idx < csvFiles.count - 1 {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }

                PNPButton(title: "Open in Finder", icon: "folder", size: .sm) {
                    let url = (ProfileService.workspaceURL(for: workspace.profile)
                                ?? FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent("Jamf-Reports"))
                        .appendingPathComponent("csv-inbox", isDirectory: true)
                    SystemActions.openFolder(url)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var familiesCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive").foregroundStyle(Theme.Colors.fgMuted)
                        .font(.system(size: 16))
                    SectionHeader(title: "Snapshot Archive Families")
                    Spacer()
                    PNPButton(title: "Open in Finder", icon: "folder", size: .sm) {
                        let url = (try? WorkspacePaths.historicalDir(for: workspace.profile))
                                    ?? (ProfileService.workspaceURL(for: workspace.profile)
                                        ?? FileManager.default.homeDirectoryForCurrentUser
                                            .appendingPathComponent("Jamf-Reports"))
                                        .appendingPathComponent("snapshots", isDirectory: true)
                        SystemActions.openFolder(url)
                    }
                }
                if families.isEmpty {
                    emptyFamiliesState
                } else {
                    Table(families) {
                        TableColumn("Family") { f in
                            Text(f.name)
                                .font(Theme.Fonts.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.goldBright)
                        }
                        TableColumn("Globs") { f in Mono(text: f.glob) }
                        TableColumn("Snapshots") { f in Mono(text: "\(f.snapshotCount)") }
                        TableColumn("Latest") { f in
                            Mono(text: f.latestDate.map(FileDisplay.date) ?? "—")
                        }
                        TableColumn("Storage") { f in Mono(text: FileDisplay.size(f.totalBytes)) }
                        TableColumn("Used By") { f in
                            Text(f.usedBy.isEmpty ? "—" : f.usedBy)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                    }
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var emptyCSVState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No CSV files in the inbox.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
            Text("Drop Jamf exports here before running a CSV-assisted report.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .padding(.vertical, 10)
    }

    private var emptyFamiliesState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No snapshot families yet.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
            Text("Historical trend snapshots will appear after collection or CSV archival runs.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private func reload() {
        csvFiles = CSVInboxService().list(profile: workspace.profile)
        families = SnapshotArchiveService().families(profile: workspace.profile)
        
        do {
            _ = try WorkspacePaths.dataDir(for: workspace.profile)
            _ = try WorkspacePaths.historicalDir(for: workspace.profile)
            _ = try WorkspacePaths.outputDir(for: workspace.profile)
            resolutionError = nil
        } catch {
            resolutionError = error.localizedDescription
        }
    }

    private func clearPendingFile() {
        guard let file = pendingClearFile,
              let profile = pendingClearProfile else {
            return
        }

        do {
            try CSVInboxService().clear(file, profile: profile)
            pendingClearFile = nil
            pendingClearProfile = nil
            if profile == workspace.profile {
                reload()
            }
        } catch {
            clearError = error.localizedDescription
            showClearError = true
        }
    }

    /// Read-only scope chip. Editing scope is deferred — see TODO(W22) below.
    @ViewBuilder
    private func scopeChip(for profile: String) -> some View {
        let scope = ProfileService.scope(for: profile)
        // TODO(W22): expose scope toggle in SettingsView / profile detail sheet
        Pill(
            text: scope.displayName,
            tone: scope == .fullAdmin ? .warn : .muted
        )
    }

    private func tone(for status: InboxFileStatus) -> Pill.Tone {
        switch status {
        case .pending: .gold
        case .consumed: .teal
        case .archived: .muted
        }
    }

    private func cacheStatus(for cacheNames: [String]) -> String {
        guard let date = latestCacheDate(for: cacheNames) else { return "not cached" }
        return "cached \(FileDisplay.date(date))"
    }

    private func latestCacheDate(for cacheNames: [String]) -> Date? {
        guard let root = WorkspacePathGuard.root(for: workspace.profile) else { return nil }
        let configured = (try? WorkspacePaths.dataDir(for: workspace.profile))
            ?? root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        
        guard let validatedDataDir = WorkspacePathGuard.validate(configured, under: root) else {
            return nil
        }

        let dates = cacheNames.flatMap { cacheName in
            cacheDates(for: cacheName, dataDir: validatedDataDir, root: root)
        }
        return dates.max()
    }

    private var cliCacheDisplayPath: String {
        guard let root = WorkspacePathGuard.root(for: workspace.profile),
              let dataDir = try? WorkspacePaths.dataDir(for: workspace.profile) else {
            return "~/Jamf-Reports/\(workspace.profile)/jamf-cli-data/"
        }
        let rootPath = root.path
        let dataPath = dataDir.path
        if dataPath.hasPrefix(rootPath + "/") {
            let suffix = String(dataPath.dropFirst(rootPath.count + 1))
            return "~/Jamf-Reports/\(workspace.profile)/\(suffix)/"
        }
        return dataPath + "/"
    }

    private func cacheDates(for cacheName: String, dataDir: URL, root: URL) -> [Date] {
        let directory = dataDir.appendingPathComponent(cacheName, isDirectory: true)
        var candidates: [URL] = []
        if let validatedDirectory = WorkspacePathGuard.validate(directory, under: root),
           let files = try? FileManager.default.contentsOfDirectory(
            at: validatedDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
           ) {
            candidates.append(contentsOf: files)
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(
                contentsOf: files.filter {
                    $0.lastPathComponent.hasPrefix("\(cacheName)_")
                        && $0.pathExtension.lowercased() == "json"
                }
            )
        }

        return candidates.compactMap { candidate in
            guard candidate.pathExtension.lowercased() == "json",
                  !candidate.lastPathComponent.contains(".partial"),
                  let validated = WorkspacePathGuard.validate(candidate, under: root),
                  let values = try? validated.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else {
                return nil
            }
            return values.contentModificationDate
        }
    }
}
