import SwiftUI
import Charts

struct JamfSchoolStatusView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var summary: JamfSchoolSnapshotSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                countRow
                trendChart
                cacheLocations
                historyCard
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
        }
        .task(id: workspace.profile) {
            reload()
        }
    }

    private var activeSummary: JamfSchoolSnapshotSummary {
        summary ?? JamfSchoolSnapshotService.load(profile: workspace.profile)
    }

    private var header: some View {
        let loaded = activeSummary
        return PageHeader(
            kicker: loaded.hasData ? "Jamf School cache" : "Jamf School cache missing",
            title: "Jamf School Status",
            subtitle: subtitle(for: loaded)
        ) {
            AnyView(
                PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                    reload()
                }
            )
        }
    }

    private var countRow: some View {
        let loaded = activeSummary
        return HStack(spacing: 12) {
            countTile(.overview, summary: loaded)
            countTile(.devices, summary: loaded)
            countTile(.apps, summary: loaded)
            countTile(.profiles, summary: loaded)
            countTile(.classes, summary: loaded)
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        let loaded = activeSummary
        let seriesData = Dictionary(
            grouping: loaded.history.filter { $0.capturedAt > .distantPast },
            by: \.kind
        ).filter { $0.value.count > 1 }
        if !seriesData.isEmpty {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionHeader(title: "Resource Count Trends")
                        Spacer()
                        Pill(text: "\(loaded.history.count) snapshots", tone: .muted)
                    }
                    Chart {
                        ForEach(JamfSchoolResourceCount.Kind.allCases) { kind in
                            if let entries = seriesData[kind] {
                                ForEach(entries.sorted { $0.capturedAt < $1.capturedAt }) { entry in
                                    LineMark(
                                        x: .value("Date", entry.capturedAt),
                                        y: .value(kind.title, entry.count),
                                        series: .value("Kind", kind.title)
                                    )
                                    .interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                                }
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

    private var cacheLocations: some View {
        let directories = activeSummary.cacheDirectories
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Discovered Cache Directories")
                    Spacer()
                    Pill(text: "\(directories.count)", tone: directories.isEmpty ? .warn : .teal)
                }

                if directories.isEmpty {
                    Text("No profile-local Jamf School cache directories were found.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(directories.enumerated()), id: \.element.path) { index, directory in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.gold)
                                Mono(text: displayPath(directory), color: Theme.Colors.fg2)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            if index < directories.count - 1 {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        let history = Array(activeSummary.history.prefix(16))
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "Historical Snapshot Counts")
                    Spacer()
                    Pill(text: "\(activeSummary.history.count) snapshots", tone: .muted)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                Divider().background(Theme.Colors.hairlineStrong)

                if history.isEmpty {
                    emptyHistory
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.element.id) { index, snapshot in
                            historyRow(snapshot)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                            if index < history.count - 1 {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyHistory: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.warn)
            Text("Collect Jamf School snapshots before this screen can show trend history.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.fgMuted)
            Spacer()
        }
        .padding(18)
    }

    private func countTile(
        _ kind: JamfSchoolResourceCount.Kind,
        summary: JamfSchoolSnapshotSummary
    ) -> some View {
        let latest = summary.latestCount(for: kind)
        return StatTile(
            label: kind.title,
            value: latest.map { "\($0.count)" } ?? "0",
            sub: latest.map { shortDate($0.capturedAt) } ?? "No cache"
        )
    }

    private func historyRow(_ snapshot: JamfSchoolResourceCount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: snapshot.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.gold)
                .frame(width: 18)
            Text(snapshot.kind.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
                .frame(width: 80, alignment: .leading)
            Mono(text: "\(snapshot.count)", color: Theme.Colors.fg)
                .frame(width: 56, alignment: .trailing)
            Mono(text: shortDate(snapshot.capturedAt))
                .frame(width: 132, alignment: .leading)
            Mono(text: displayPath(snapshot.source))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func reload() {
        summary = JamfSchoolSnapshotService.load(profile: workspace.profile)
    }

    private func subtitle(for summary: JamfSchoolSnapshotSummary) -> String {
        if summary.hasData {
            return "\(summary.profile) · \(summary.history.count) cached JSON snapshot(s)"
        }
        return "\(summary.profile) · looking under ~/Jamf-Reports/\(summary.profile)/"
    }

    private func icon(for kind: JamfSchoolResourceCount.Kind) -> String {
        switch kind {
        case .overview: "list.bullet.rectangle"
        case .devices: "ipad"
        case .apps: "app.badge"
        case .profiles: "slider.horizontal.3"
        case .classes: "person.3"
        }
    }

    private func shortDate(_ date: Date) -> String {
        guard date > .distantPast else { return "Unknown date" }
        return Self.dateFormatter.string(from: date)
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
