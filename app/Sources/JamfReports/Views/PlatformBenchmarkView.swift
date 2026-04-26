import SwiftUI

struct PlatformBenchmarkView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var candidates: [PlatformBenchmarkService.BenchmarkCandidate] = []
    @State private var selectedID: String?

    private var selected: PlatformBenchmarkService.BenchmarkCandidate? {
        candidates.first { $0.id == selectedID } ?? candidates.first
    }

    private var summary: PlatformBenchmarkService.BenchmarkSummary? {
        selected.flatMap { PlatformBenchmarkService.summary(for: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 14) {
                    benchmarkList
                    summaryCard
                }
                detailTables
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
            kicker: "Jamf Platform",
            title: "Benchmark Discovery",
            subtitle: "~/Jamf-Reports/\(workspace.profile)/jamf-cli-data/"
        ) {
            AnyView(
                PNPButton(title: "Refresh", icon: "arrow.clockwise", size: .sm) {
                    refresh()
                }
            )
        }
    }

    private var benchmarkList: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Cached Benchmarks", trailing: "\(candidates.count)")
                if candidates.isEmpty {
                    emptyState("No Platform compliance benchmark cache files found.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            benchmarkButton(candidate)
                            if index < candidates.count - 1 {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 310, maxWidth: 380)
    }

    private func benchmarkButton(_ candidate: PlatformBenchmarkService.BenchmarkCandidate) -> some View {
        let isSelected = candidate.id == selected?.id
        return Button {
            selectedID = candidate.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checklist.checked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.Colors.goldBright : Theme.Colors.fgMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Mono(text: "\(candidate.ruleCount) rules · \(candidate.failingDeviceCount) devices", size: 10.5)
                }
                Spacer()
                Pill(text: candidate.sourceCount == 2 ? "rules + devices" : "partial",
                     tone: candidate.sourceCount == 2 ? .teal : .warn)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .background(isSelected ? Theme.Colors.gold.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var summaryCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: selected?.name ?? "No benchmark selected")
                if let summary {
                    HStack(spacing: 10) {
                        StatTile(label: "Rules", value: "\(summary.totalRules)", sub: "\(summary.rulesWithFailures) with failures")
                        StatTile(label: "Devices", value: "\(summary.devicesReturned)", sub: "\(summary.devicesWithFailures) with failures")
                        StatTile(label: "Avg Pass", value: percent(summary.averagePassRate), sub: "Rule pass rate")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sourceLine("Rules", url: summary.candidate.ruleSnapshotURL)
                        sourceLine("Devices", url: summary.candidate.deviceSnapshotURL)
                    }
                } else {
                    emptyState("Select a cached benchmark to inspect parsed rule and device summaries.")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var detailTables: some View {
        if let summary {
            HStack(alignment: .top, spacing: 14) {
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Top Failing Rules")
                        rows(summary.topRules) { rule in
                            HStack {
                                Text(rule.rule)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Colors.fg2)
                                    .lineLimit(1)
                                Spacer()
                                Mono(text: "\(rule.failed) failed")
                                Mono(text: percent(rule.passRate), color: Theme.Colors.goldBright)
                            }
                        }
                    }
                }
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Top Failing Devices")
                        rows(summary.topDevices) { device in
                            HStack {
                                Text(device.device)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Colors.fg2)
                                    .lineLimit(1)
                                Spacer()
                                Mono(text: "\(device.rulesFailed) failed")
                                Mono(text: percent(device.compliance), color: Theme.Colors.goldBright)
                            }
                        }
                    }
                }
            }
        }
    }

    private func rows<Item: Identifiable, Content: View>(
        _ items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                emptyState("No rows found in this snapshot.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    content(item)
                        .padding(.vertical, 7)
                    if index < items.count - 1 {
                        Divider().background(Theme.Colors.hairline)
                    }
                }
            }
        }
    }

    private func sourceLine(_ label: String, url: URL?) -> some View {
        HStack(spacing: 6) {
            Pill(text: label, tone: .muted)
            Mono(text: url?.path ?? "not cached")
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Colors.fgMuted)
            .padding(.vertical, 8)
    }

    private func refresh() {
        candidates = PlatformBenchmarkService.discover(profile: workspace.profile)
        if selectedID == nil || !candidates.contains(where: { $0.id == selectedID }) {
            selectedID = candidates.first?.id
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int((value * 100).rounded()))%"
    }
}
