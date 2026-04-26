import SwiftUI
import Charts

struct JamfProtectStatusView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot: JamfProtectSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let snapshot, snapshot.hasData {
                    metricsGrid(snapshot)
                    trendChart(snapshot)
                    historyList(snapshot)
                    rootsList(snapshot)
                } else {
                    emptyState
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .task(id: workspace.profile) {
            reload()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: newestSnapshotLabel,
            title: "Jamf Protect",
            subtitle: "Cached Protect snapshots for profile \(workspace.profile)"
        ) {
            AnyView(
                PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                    reload()
                }
            )
        }
    }

    private var newestSnapshotLabel: String {
        guard let date = snapshot?.newestSnapshotDate else {
            return "Protect cache"
        }
        return "Newest snapshot · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func reload() {
        snapshot = JamfProtectSnapshotService.load(profile: workspace.profile)
    }

    private func metricsGrid(_ snapshot: JamfProtectSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            ForEach(snapshot.metrics) { metric in
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Kicker(text: metric.label)
                        Text(metric.value)
                            .font(Theme.Fonts.serif(32, weight: .bold))
                            .foregroundStyle(Theme.Colors.fg)
                            .monospacedDigit()
                        Text(metric.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trendChart(_ snapshot: JamfProtectSnapshot) -> some View {
        let series = Dictionary(grouping: snapshot.history.filter { $0.count != nil }, by: \.kind)
            .filter { $0.value.count > 1 }
        if !series.isEmpty {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionHeader(title: "Snapshot Count Trends")
                        Spacer()
                        Pill(text: "\(snapshot.history.count) snapshots", tone: .muted)
                    }
                    Chart {
                        ForEach(Array(series.keys.sorted()), id: \.self) { kind in
                            ForEach(series[kind]!.sorted { $0.date < $1.date }) { entry in
                                LineMark(
                                    x: .value("Date", entry.date),
                                    y: .value(kind, entry.count ?? 0),
                                    series: .value("Category", kind)
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks { AxisValueLabel().font(Theme.Fonts.mono(10)) }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                            AxisValueLabel().font(Theme.Fonts.mono(10))
                        }
                    }
                    .chartLegend(position: .bottom)
                    .frame(height: 200)
                }
            }
        }
    }

    private func historyList(_ snapshot: JamfProtectSnapshot) -> some View {
        let recent = Array(snapshot.history.prefix(12))
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Snapshot History")
                    Spacer()
                    Pill(text: "\(snapshot.history.count) files", tone: .muted)
                }
                if recent.isEmpty {
                    Text("No timestamped Protect snapshots found.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recent) { entry in
                            historyRow(entry)
                            if entry.id != recent.last?.id {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: JamfProtectSnapshot.HistoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fg)
                Text(entry.source.lastPathComponent)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(entry.summary)
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Colors.fg2)
            Text(entry.date.formatted(date: .numeric, time: .shortened))
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
                .frame(width: 132, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    private func rootsList(_ snapshot: JamfProtectSnapshot) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "Cache Roots")
                    Spacer()
                    Pill(text: "\(snapshot.dataRoots.count) checked", tone: .muted)
                }
                ForEach(snapshot.dataRoots, id: \.path) { root in
                    Text(root.path)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var emptyState: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(Theme.Colors.goldBright)
                    SectionHeader(title: "No Protect Cache Found")
                }
                Text("Expected cached JSON under ~/Jamf-Reports/\(workspace.profile)/jamf-cli-data or related Protect cache folders.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                PNPButton(title: "Reload", icon: "arrow.clockwise") {
                    reload()
                }
            }
        }
    }
}
