import Charts
import SwiftUI

struct FleetOverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [FleetProfileOverview] = []
    @State private var isLoading = false
    @State private var issuesOnly: Bool = false

    private var visibleRows: [FleetProfileOverview] {
        issuesOnly ? rows.filter { fleetProfileHasIssue($0.summary) } : rows
    }

    private var profileKey: String {
        "\(workspace.demoMode)|" + workspace.initializedProfiles.map(\.name).joined(separator: "|")
    }

    private var totalDevices: Int {
        rows.reduce(0) { $0 + ($1.summary?.totalDevices ?? 0) }
    }

    private var averageStability: Double? {
        let values = rows.compactMap { $0.summary?.stabilityIndex }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var latestRunDate: String {
        rows.compactMap { $0.summary?.date }.max() ?? "No successful runs"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summaryStrip
                    issuesFilter
                    profileGrid
                }
                .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                    leading: Theme.Metrics.pagePadH,
                                    bottom: Theme.Metrics.pagePadBottom,
                                    trailing: Theme.Metrics.pagePadH))
            }
            .navigationDestination(for: String.self) { profile in
                if let row = rows.first(where: { $0.profile == profile }) {
                    profileDetail(row)
                }
            }
        }
        .task(id: profileKey) {
            await load()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Multi-Profile Fleet",
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
            title: "Fleet Overview",
            subtitle: "Aggregated trend summaries across initialized profiles"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await load() }
                    }
                }
            )
        }
    }

    private func navigateToOverview() {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": Tab.overview.rawValue]
        )
    }

    private var issueCount: Int {
        rows.filter { fleetProfileHasIssue($0.summary) }.count
    }

    private var stabilitySpark: [Double] {
        rows.compactMap { $0.summary?.stabilityIndex }
    }

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            StatTile(label: "Profiles", value: "\(rows.count)", sub: "Initialized workspaces")
                .overlay(alignment: .topTrailing) {
                    if issueCount > 0 {
                        Pill(text: "\(issueCount) Issue\(issueCount == 1 ? "" : "s")", tone: .danger)
                            .padding(8)
                    }
                }
            StatTile(label: "Devices", value: "\(totalDevices)", sub: "Latest successful summaries")
            StatTile(
                label: "Stability",
                value: stabilityLabel(averageStability),
                sub: "Average index",
                sparkValues: stabilitySpark.isEmpty ? nil : stabilitySpark,
                sparkColor: Theme.Colors.teal
            )
            latestRunTile
        }
    }

    private var latestRunTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: "Latest Run")
            Text(latestRunDate)
                .font(Theme.Fonts.mono(18, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("Most recent summary across all profiles")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.winBG2)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }

    private var issuesFilter: some View {
        HStack {
            Toggle("Issues Only", isOn: $issuesOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.fg2)
            Spacer()
        }
    }

    private var profileGrid: some View {
        Group {
            if visibleRows.isEmpty && issuesOnly {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Theme.Colors.teal)
                        Text("No profiles with issues — fleet looks healthy")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    .padding(.vertical, 48)
                    Spacer()
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(visibleRows) { row in
                        NavigationLink(value: row.profile) {
                            FleetProfileCard(row: row)
                                .fleetDrillDownChrome()
                        }
                        .buttonStyle(.plain)
                        .help("Open \(row.profile) fleet details")
                    }
                }
            }
        }
    }

    private func profileDetail(_ row: FleetProfileOverview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    kicker: row.profile,
                    breadcrumbs: [Breadcrumb(label: "Fleet", action: { dismiss() })],
                    title: row.profile,
                    subtitle: row.summary.map { "Latest summary \($0.date)" }
                        ?? "No successful summary found for this profile"
                )

                HStack(spacing: 12) {
                    StatTile(
                        label: "Devices",
                        value: row.summary.map { "\($0.totalDevices)" } ?? "--",
                        sub: "Latest successful summary"
                    )
                    StatTile(
                        label: "Stability",
                        value: stabilityLabel(row.summary?.stabilityIndex),
                        sub: "Composite index"
                    )
                    StatTile(
                        label: "Stale",
                        value: row.summary.map { "\($0.staleCount)" } ?? "--",
                        sub: "30d+ since contact"
                    )
                    StatTile(
                        label: "Patch",
                        value: row.summary.map { "\(String(format: "%.1f", $0.patchPct))%" } ?? "--",
                        sub: "Patch compliance"
                    )
                }

                stabilityTrendCard(for: row)

                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            SectionHeader(title: "Summary Details")
                            Spacer()
                            Pill(
                                text: row.summary == nil ? "No Data" : stabilityLabel(row.summary?.stabilityIndex),
                                tone: stabilityTone(row.summary?.stabilityIndex)
                            )
                        }

                        if let summary = row.summary {
                            VStack(spacing: 10) {
                                profileMetricRow("Compliance", value: summary.compliancePct)
                                profileMetricRow("FileVault", value: summary.fileVaultPct)
                                profileMetricRow("Current macOS", value: summary.osCurrentPct)
                                profileMetricRow("CrowdStrike", value: summary.crowdstrikePct)
                                profileMetricRow("Patch", value: summary.patchPct)
                                profileMetricRow("Stale", value: stalePercent(summary), inverse: true)
                            }
                        } else {
                            Text("Run a schedule or generate a report for this workspace to create its first summary.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider().background(Theme.Colors.hairline)

                        HStack {
                            Text("Switch to this workspace and open the relevant surface.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                            Spacer()
                            PNPButton(title: "Overview", icon: Tab.overview.sfSymbol, size: .sm) {
                                open(row.profile, tab: .overview)
                            }
                            PNPButton(title: "Devices", icon: Tab.devices.sfSymbol, size: .sm) {
                                open(row.profile, tab: .devices)
                            }
                            PNPButton(title: "Runs", icon: Tab.runs.sfSymbol, size: .sm) {
                                open(row.profile, tab: .runs)
                            }
                            PNPButton(title: "Schedules", icon: Tab.schedules.sfSymbol, size: .sm) {
                                open(row.profile, tab: .schedules)
                            }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .background(Theme.Colors.winBG)
    }

    private func stabilityTrendPoints(_ summaries: [DailySummary]) -> [StabilityTrendPoint] {
        summaries.compactMap { summary in
            guard let value = summary.stabilityIndex else { return nil }
            let date = summary.parsedDate
            guard date != .distantPast else { return nil }
            return StabilityTrendPoint(date: date, value: value)
        }
    }

    private func stabilityTrendCard(for row: FleetProfileOverview) -> some View {
        let points = stabilityTrendPoints(row.summaries)
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Stability Trend")
                    Spacer()
                    if !points.isEmpty {
                        Pill(text: "\(points.count) snapshot\(points.count == 1 ? "" : "s")",
                             tone: .muted)
                    }
                }
                if points.isEmpty {
                    stabilityEmptyState
                } else {
                    stabilityChart(points: points)
                }
            }
        }
    }

    private var stabilityEmptyState: some View {
        VStack(spacing: 6) {
            Kicker(text: "No stability history yet")
            Text("Generate a report to start tracking trends")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private func stabilityChart(points: [StabilityTrendPoint]) -> some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Stability", point.value)
                )
                .foregroundStyle(LinearGradient(
                    colors: [Theme.Colors.teal.opacity(0.35), Theme.Colors.teal.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Stability", point.value)
                )
                .foregroundStyle(Theme.Colors.teal)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                               centered: false)
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                AxisValueLabel(horizontalSpacing: 6) {
                    if let pct = value.as(Double.self) {
                        Text("\(Int(pct))%")
                            .font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private func profileMetricRow(_ label: String, value: Double?, inverse: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(width: 112, alignment: .leading)
            GeometryReader { geo in
                let normalized = max(0, min(value ?? 0, 100)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(inverse ? Theme.Colors.warn : Theme.Colors.teal)
                        .frame(width: geo.size.width * normalized)
                }
            }
            .frame(height: 8)
            Mono(text: value.map { "\(String(format: "%.1f", $0))%" } ?? "--",
                 color: Theme.Colors.fg)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func stalePercent(_ summary: DailySummary) -> Double {
        guard summary.totalDevices > 0 else { return 0 }
        return (Double(summary.staleCount) / Double(summary.totalDevices)) * 100
    }

    private func open(_ profile: String, tab: Tab) {
        workspace.setProfile(profile)
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
    }

    private func load() async {
        isLoading = true
        workspace.globalStatus = "Aggregating multi-profile summaries..."
        defer { 
            isLoading = false
            workspace.globalStatus = nil
        }

        if workspace.demoMode {
            rows = demoRows()
            return
        }

        let profiles = workspace.initializedProfiles
        rows = await Task.detached(priority: .utility) {
            profiles.map { profile in
                let summaries = (try? WorkspacePaths.summariesDir(for: profile.name))
                    .map { SummaryJSONParser.parseDirectory($0) } ?? []
                return FleetProfileOverview(
                    profile: profile.name,
                    summary: summaries.last,
                    summaries: summaries
                )
            }
        }.value
        
        if !rows.isEmpty {
            workspace.toast = Toast(message: "Fleet data refreshed", style: .success)
        }
    }

    private func demoRows() -> [FleetProfileOverview] {
        let baseStability = DemoData.stabilityTrend.last ?? 0
        let baseDevices = Int((DemoData.totalDevicesTrend.last ?? 0).rounded())
        return workspace.initializedProfiles.enumerated().map { idx, profile in
            let offset = Double(idx * 4)
            let summary = DailySummary(
                date: DemoData.trendDates[safe: max(DemoData.trendDates.count - 1 - idx, 0)] ?? "2026-04-20",
                totalDevices: max(baseDevices - idx * 37, 0),
                fileVaultPct: 94 - offset,
                compliancePct: max((baseStability - offset), 0),
                staleCount: 18 + idx * 4,
                osCurrentPct: 72 - offset,
                crowdstrikePct: 93 - offset,
                patchPct: 84 - offset
            )
            return FleetProfileOverview(
                profile: profile.name,
                summary: summary,
                summaries: [summary]
            )
        }
    }
}

private struct FleetProfileOverview: Identifiable, Sendable {
    var id: String { profile }
    let profile: String
    let summary: DailySummary?
    var summaries: [DailySummary] = []

    var hasIssue: Bool { fleetProfileHasIssue(summary) }
}

private struct StabilityTrendPoint: Identifiable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

private struct FleetProfileCard: View {
    let row: FleetProfileOverview

    private var stability: Double? {
        row.summary?.stabilityIndex
    }

    private var hasIssue: Bool { fleetProfileHasIssue(row.summary) }
    private var hasNoSummary: Bool { row.summary == nil }

    var body: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                if hasIssue && !hasNoSummary {
                    Rectangle()
                        .fill(Theme.Colors.warn)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                }
                cardContent
            }
        }
        .overlay {
            if hasNoSummary {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        Theme.Colors.hairlineStrong,
                        style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])
                    )
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Kicker(text: "Profile")
                    Text(row.profile)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)
                }
                Spacer()
                Pill(
                    text: stability.map { stabilityLabel($0) } ?? "No Data",
                    tone: stabilityTone(stability)
                )
                .contentTransition(.numericText())
            }

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Kicker(text: "Devices")
                        Text(row.summary.map { "\($0.totalDevices)" } ?? "--")
                            .font(Theme.Fonts.serif(30, weight: .bold))
                            .foregroundStyle(Theme.Colors.fg)
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Kicker(text: "Last Run")
                        Text(row.summary?.date ?? "No summary")
                            .font(Theme.Fonts.mono(12, weight: .semibold))
                            .foregroundStyle(row.summary == nil ? Theme.Colors.fgMuted : Theme.Colors.fg2)
                    }
                    Spacer()
                }

                Divider().background(Theme.Colors.hairline)

                if let summary = row.summary {
                    VStack(spacing: 7) {
                        metricRow("Compliance", value: summary.compliancePct)
                        metricRow("Patch", value: summary.patchPct)
                        metricRow("Stale", value: stalePercent(summary), inverse: true)
                    }
                } else {
                    Text("Run a schedule or generate a report to create the first summary.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
    }

    private func metricRow(_ label: String, value: Double?, inverse: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
                .frame(width: 72, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(inverse ? Theme.Colors.warn : Theme.Colors.teal)
                    .frame(width: max(0, min(CGFloat(value ?? 0), 100)) * 1.1)
            }
            .frame(width: 110, height: 6)
            Spacer()
            Mono(text: value.map { "\(String(format: "%.1f", $0))%" } ?? "--")
        }
    }

    private func stalePercent(_ summary: DailySummary) -> Double {
        guard summary.totalDevices > 0 else { return 0 }
        return (Double(summary.staleCount) / Double(summary.totalDevices)) * 100
    }
}

private extension View {
    func fleetDrillDownChrome() -> some View {
        self
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.goldBright)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }
}

private func stabilityLabel(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(String(format: "%.1f", value))%"
}

private func stabilityLabel(_ value: Double) -> String {
    "\(String(format: "%.1f", value))%"
}

private func stabilityTone(_ value: Double?) -> Pill.Tone {
    guard let value else { return .muted }
    if value >= 85 { return .teal }
    if value >= 70 { return .warn }
    return .danger
}

/// Returns true when the profile summary indicates an actionable issue:
/// - No summary yet (workspace needs a first run)
/// - Stability index below the warn threshold (< 70%)
/// - Any stale devices in the fleet
/// - FileVault below 90% (material encryption gap)
/// - Patch compliance below 80%
///
/// Stability already captures compliance + patch + stale in one composite score;
/// the individual thresholds catch cases where one metric is bad but others
/// keep stability above 70.
func fleetProfileHasIssue(_ summary: DailySummary?) -> Bool {
    guard let summary else { return true }
    if let stability = summary.stabilityIndex, stability < 70 { return true }
    if summary.staleCount > 0 { return true }
    if summary.fileVaultPct < 90 { return true }
    if summary.patchPct < 80 { return true }
    return false
}
