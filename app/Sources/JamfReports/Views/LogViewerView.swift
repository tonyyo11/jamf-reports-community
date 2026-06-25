import SwiftUI
import AppKit

/// Snapshot+refresh viewer over the app's OSLog entries (this session), embedded in
/// Settings → Diagnostics. Loads on appear and on manual Refresh — no continuous polling.
/// Filter by minimum level, time window, and free-text search (which also matches the
/// `[category]` prefix). Export is `LogRedactor`-scrubbed.
struct LogViewerView: View {
    @State private var entries: [LogEntry] = []
    @State private var search = ""
    @State private var minLevel: LogEntry.Level = .info
    @State private var windowHours = 4
    @State private var loadError: String?
    @State private var isLoading = false

    private var filtered: [LogEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.message.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if let loadError {
                ErrorStateView(
                    title: "Couldn't read the log store",
                    message: loadError,
                    retry: { Task { await load() } }
                )
            } else if filtered.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text.magnifyingglass",
                    title: "No matching log entries",
                    message: "The local store keeps debug/info only while verbose logging is on. "
                        + "Turn on “Persist verbose logs” above, reproduce the issue, then Refresh."
                )
            } else {
                logRows
            }
        }
        .task { await load() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Level", selection: $minLevel) {
                Text("Debug").tag(LogEntry.Level.debug)
                Text("Info").tag(LogEntry.Level.info)
                Text("Notice").tag(LogEntry.Level.notice)
                Text("Error").tag(LogEntry.Level.error)
            }
            .labelsHidden()
            .frame(width: 120)
            Picker("Window", selection: $windowHours) {
                Text("1h").tag(1); Text("4h").tag(4); Text("24h").tag(24)
            }
            .labelsHidden()
            .frame(width: 100)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(isLoading)
            Button { export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(filtered.isEmpty)
        }
    }

    private var logRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filtered) { entry in
                    Text("\(time(entry.date))  [\(entry.category)]  \(entry.message)")
                        .font(Theme.Fonts.mono(11.5))
                        .foregroundStyle(color(for: entry.level))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
        .frame(minHeight: 220, maxHeight: 360)
        .background(Theme.Colors.codeBG)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        let since = Date().addingTimeInterval(-Double(windowHours) * 3600)
        let lvl = minLevel
        do {
            entries = try await Task.detached { try LogStoreReader.recent(minLevel: lvl, since: since) }.value
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func export() {
        let body = filtered.map { "\(time($0.date)) [\($0.category)] \($0.message)" }.joined(separator: "\n")
        let scrubbed = LogRedactor.redact(body)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jamf-reports-logs.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(scrubbed.utf8).write(to: url, options: .atomic)
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .error, .fault: return Theme.Colors.dangerSoft
        case .notice: return Theme.Colors.warnSoft
        case .debug: return Theme.Colors.fgMuted
        case .info: return Theme.Colors.fg2
        }
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
