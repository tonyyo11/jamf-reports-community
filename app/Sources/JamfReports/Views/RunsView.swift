import SwiftUI
import AppKit

struct RunsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var runs: [RunHistoryService.RunSummary] = []
    @State private var selectedRun: RunHistoryService.RunSummary? = nil
    @State private var logLines: [CLIBridge.LogLine] = []
    @State private var showExportError = false
    @State private var exportError: String? = nil

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if runs.isEmpty {
                    emptyState
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        runsList.frame(width: 260)
                        logViewer
                    }
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .task(id: workspace.profile) { reload() }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    // MARK: - Header

    private var header: some View {
        let kickerText: String
        if let r = selectedRun {
            kickerText = "Run · \(Self.dateFmt.string(from: r.date)) · \(r.name)"
        } else {
            kickerText = "Run History · \(workspace.profile)"
        }
        return PageHeader(
            kicker: kickerText,
            title: "Run History",
            subtitle: "\(runs.count) log\(runs.count == 1 ? "" : "s") · \(workspace.profile)"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") { reload() }
                        .help("Reload run logs from disk")
                    PNPButton(title: "Reveal", icon: "folder") { revealLog() }
                        .help("Reveal the selected log in Finder, or open the run history folder")
                    PNPButton(title: "Copy log", icon: "doc.on.doc") { copyLog() }
                        .disabled(selectedRun == nil)
                        .help(selectedRun == nil ? "Select a run to copy its log" : "Copy full log text to clipboard")
                    PNPButton(title: "Export", icon: "arrow.down.circle") { exportLog() }
                        .disabled(selectedRun == nil)
                        .help(selectedRun == nil ? "Select a run to export its log" : "Save log file to a chosen location")
                }
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "terminal",
                title: "No run logs yet",
                message: "Logs appear here after a scheduled run or a manual \"Run now\"."
            )
        }
    }

    // MARK: - Runs list

    private var runsList: some View {
        Card(padding: 8) {
            VStack(spacing: 2) {
                ForEach(runs) { run in
                    runListItem(run)
                }
            }
        }
    }

    private func runListItem(_ run: RunHistoryService.RunSummary) -> some View {
        let selected = selectedRun?.id == run.id
        return runListItemContent(run, selected: selected)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(runListItemBackground(selected: selected))
            .overlay(runListItemBorder(selected: selected))
            .contentShape(Rectangle())
            .onTapGesture { selectRun(run) }
            .contextMenu { runListItemContextMenu(run) }
            .accessibilityLabel(runListItemAccessibilityLabel(run))
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func runListItemContent(
        _ run: RunHistoryService.RunSummary,
        selected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Mono(text: Self.dateFmt.string(from: run.date), size: 10.5)
                Spacer()
                statusPill(for: run.status)
            }
            Text(run.name).font(.footnote.weight(.medium))
                .foregroundStyle(selected ? Theme.Colors.fg : Theme.Colors.fg2)
            if let dur = run.duration {
                Mono(text: dur, size: 10)
            }
        }
    }

    private func runListItemBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Theme.Colors.gold.opacity(0.12) : .clear)
    }

    private func runListItemBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                selected ? Theme.Colors.gold.opacity(0.3) : .clear,
                lineWidth: 0.5
            )
    }

    @ViewBuilder
    private func runListItemContextMenu(_ run: RunHistoryService.RunSummary) -> some View {
        Button {
            let text = RunHistoryService.loadLog(run.logURL).map(\.text).joined(separator: "\n")
            SystemActions.copyToClipboard(text)
        } label: {
            Label("Copy log", systemImage: "doc.on.doc")
        }
        Button {
            exportLogFile(run.logURL)
        } label: {
            Label("Export log…", systemImage: "arrow.down.circle")
        }
        Divider()
        Button {
            SystemActions.reveal(run.logURL)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
    }

    private func runListItemAccessibilityLabel(
        _ run: RunHistoryService.RunSummary
    ) -> String {
        var label = "\(run.name), \(Self.dateFmt.string(from: run.date)), "
        label += "status \(run.status.rawValue)"
        if let duration = run.duration {
            label += ", duration \(duration)"
        }
        return label
    }

    private func statusPill(for s: Schedule.LastStatus) -> some View {
        switch s {
        case .ok:      Pill(text: "OK",      tone: .teal,   icon: "checkmark")
            .accessibilityLabel("Status: OK")
        case .warn:    Pill(text: "WARN",    tone: .warn,   icon: "exclamationmark")
            .accessibilityLabel("Status: Warning")
        case .fail:    Pill(text: "FAIL",    tone: .danger, icon: "xmark")
            .accessibilityLabel("Status: Failed")
        case .partial: Pill(text: "PARTIAL", tone: .warn,   icon: "exclamationmark.triangle.fill")
            .accessibilityLabel("Status: Partial")
        }
    }

    // MARK: - Log viewer

    private var logViewer: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Theme.Colors.gold).font(.system(size: 13))
                        .accessibilityHidden(true)
                    if let run = selectedRun {
                        Mono(text: run.logURL.path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
                        ), size: 12, color: Theme.Colors.fg2)
                        .accessibilityAddTraits(.updatesFrequently)
                    } else {
                        Mono(text: "Select a run to view its log", size: 12, color: Theme.Text.tertiary(contrast))
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Spacer()
                    if let run = selectedRun, let code = run.exitCode {
                        Pill(text: "EXIT \(code)", tone: code == 0 ? .teal : .danger)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().background(Theme.Colors.hairlineStrong)

                ScrollView {
                    if logLines.isEmpty {
                        Mono(text: selectedRun == nil ? "—" : "Empty log", size: 11.5)
                            .padding(14)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                            ForEach(logLines) { line in
                                Text(line.text)
                                    .font(Theme.Fonts.mono(11.5))
                                    .foregroundStyle(logColor(for: line.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(14)
                    }
                }
                .background(Theme.Colors.codeBG)
            }
            .background(Theme.Colors.codeBG)
        }
    }

    // MARK: - Actions

    private func reload() {
        runs = RunHistoryService.list(profile: workspace.profile)
        if let first = runs.first { selectRun(first) } else { selectedRun = nil; logLines = [] }
    }

    private func selectRun(_ run: RunHistoryService.RunSummary) {
        selectedRun = run
        logLines = RunHistoryService.loadLog(run.logURL)
    }

    private func copyLog() {
        let text = logLines.map(\.text).joined(separator: "\n")
        SystemActions.copyToClipboard(text)
    }

    private func revealLog() {
        if let run = selectedRun {
            SystemActions.reveal(run.logURL)
        } else if let logsDir = try? WorkspacePaths.runHistoryDir(for: workspace.profile) {
            SystemActions.openFolder(logsDir)
        }
    }

    @MainActor
    private func exportLog() {
        guard let run = selectedRun else { return }
        exportLogFile(run.logURL)
    }

    @MainActor
    private func exportLogFile(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                // Redact secrets before writing the export. The raw .log file
                // at `url` is intentionally left untouched on disk — that's
                // the audit trail. Only the exported copy is sanitized so a
                // misbehaving subprocess or future debug-mode flag cannot
                // exfiltrate Bearer tokens / OAuth secrets via accidental
                // shared file. Matches the clipboard path (copyLog).
                let text = RunsView.renderExport(from: url)
                try text.write(to: dest, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in
                    exportError = "Could not export \(url.lastPathComponent): \(error.localizedDescription)"
                    showExportError = true
                }
            }
        }
    }

    /// Render a log file URL as the redacted plain-text payload an export
    /// should produce. Same shape as `copyLog` (one line per text). Extracted
    /// to a static helper so tests can drive the redaction path without
    /// having to instantiate a SwiftUI view or call the NSSavePanel.
    static func renderExport(from url: URL) -> String {
        RunHistoryService.loadLog(url).map(\.text).joined(separator: "\n")
    }

    // MARK: - Helpers

    private func logColor(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Colors.fg2
        case .ok:   Theme.Colors.ok
        case .warn: Theme.Colors.warnSoft
        case .fail: Theme.Colors.dangerSoft
        }
    }
}
