import SwiftUI

struct UnifiedHistoryView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var index: UnifiedHistoryService.ProfileIndex?
    @State private var kind: UnifiedHistoryService.ArtifactKind? = nil

    private var filteredArtifacts: [UnifiedHistoryService.Artifact] {
        guard let kind else { return index?.artifacts ?? [] }
        return index?.artifacts.filter { $0.kind == kind } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryRow
                artifactsCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .task { refresh() }
    }

    private var header: some View {
        PageHeader(
            kicker: "Historical State",
            title: "Unified Artifact Index",
            subtitle: index?.workspaceURL.path ?? "~/Jamf-Reports/\(workspace.profile)/"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "All", icon: "tray.full", size: .sm) { kind = nil }
                    PNPButton(title: "Refresh", icon: "arrow.clockwise", size: .sm) { refresh() }
                }
            )
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            ForEach(index?.summaries ?? []) { summary in
                Button {
                    kind = summary.kind
                } label: {
                    StatTile(
                        label: summary.kind.rawValue,
                        value: "\(summary.count)",
                        sub: "\(formatBytes(summary.byteCount)) · latest \(formatDate(summary.latest))"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var artifactsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: kind?.rawValue ?? "All Artifacts", trailing: "\(filteredArtifacts.count)")
                    Spacer()
                    if let kind {
                        Pill(text: kind.rawValue, tone: .gold, icon: kind.icon)
                    }
                }
                if filteredArtifacts.isEmpty {
                    Text("No artifacts found for this profile.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredArtifacts.prefix(80).enumerated()), id: \.element.id) { row, artifact in
                            artifactRow(artifact)
                            if row < min(filteredArtifacts.count, 80) - 1 {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func artifactRow(_ artifact: UnifiedHistoryService.Artifact) -> some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.goldBright)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg)
                    .lineLimit(1)
                Mono(text: artifact.url.deletingLastPathComponent().path, size: 10.5)
            }
            Spacer()
            Pill(text: artifact.family, tone: .muted)
            Mono(text: formatBytes(artifact.byteCount))
            Mono(text: formatDate(artifact.modifiedAt))
        }
        .padding(.vertical, 7)
    }

    private func refresh() {
        index = UnifiedHistoryService.index(profile: workspace.profile)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "n/a" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
