import SwiftUI
import AppKit

struct RunsView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @State private var runs: [RunHistoryService.RunSummary] = []
    @State private var selectedRun: RunHistoryService.RunSummary? = nil
    @State private var logLines: [CLIBridge.LogLine] = []

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
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
                    PNPButton(title: "Copy log", icon: "doc.on.doc") { copyLog() }
                        .disabled(selectedRun == nil)
                    PNPButton(title: "Export", icon: "arrow.down.circle") { exportLog() }
                        .disabled(selectedRun == nil)
                }
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Card(padding: 32) {
            VStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 32)).foregroundStyle(Theme.Colors.fgMuted)
                Text("No run logs yet")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Colors.fg)
                Text("Logs appear here after a scheduled run or a manual \"Run now\".")
                    .font(.system(size: 12)).foregroundStyle(Theme.Colors.fgMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Mono(text: Self.dateFmt.string(from: run.date), size: 10.5)
                Spacer()
                statusPill(for: run.status)
            }
            Text(run.name).font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.Colors.fg : Theme.Colors.fg2)
            if let dur = run.duration {
                Mono(text: dur, size: 10)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.Colors.gold.opacity(0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Theme.Colors.gold.opacity(0.3) : .clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectRun(run) }
    }

    private func statusPill(for s: Schedule.LastStatus) -> some View {
        switch s {
        case .ok:   Pill(text: "OK",   tone: .teal)
        case .warn: Pill(text: "WARN", tone: .warn)
        case .fail: Pill(text: "FAIL", tone: .danger)
        }
    }

    // MARK: - Log viewer

    private var logViewer: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Theme.Colors.gold).font(.system(size: 13))
                    if let run = selectedRun {
                        Mono(text: run.logURL.path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
                        ), size: 12, color: Theme.Colors.fg2)
                    } else {
                        Mono(text: "Select a run to view its log", size: 12, color: Theme.Colors.fgMuted)
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
                        VStack(alignment: .leading, spacing: 4) {
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

    @MainActor
    private func exportLog() {
        guard let run = selectedRun else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = run.logURL.lastPathComponent
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.copyItem(at: run.logURL, to: dest)
        }
    }

    // MARK: - Helpers

    private func logColor(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Colors.fg2
        case .ok:   Theme.Colors.ok
        case .warn: Theme.Colors.warn
        case .fail: Theme.Colors.danger
        }
    }
}
