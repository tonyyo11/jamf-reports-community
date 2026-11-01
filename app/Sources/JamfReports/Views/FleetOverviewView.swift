import Charts
import SwiftUI

/// The active workspace's fleet: its latest summary, issues and stability trend. Another
/// workspace can be a different Jamf Pro server, so this screen never shows two; the sidebar
/// profile switcher changes what it shows.
struct FleetOverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var overview: FleetWorkspaceOverview?
    @State private var isLoading = false
    /// The `fleetOverviewLoadKey` `overview` was read for.
    @State private var loadedSource: String?
    @State private var reloads = 0

    /// The loaded overview, only while it was read for the current profile and demo mode.
    private var current: FleetWorkspaceOverview? {
        loadedSource == workspace.fleetOverviewLoadKey
            ? overview?.shown(for: workspace.profile) : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ProvenanceBadge(
                    asOf: current?.summary?.date,
                    sources: current?.summary?.collectionSources
                )
                if let overview = current {
                    workspaceDetail(overview)
                } else {
                    ProgressView()
                        .accessibilityLabel("Loading fleet overview")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .background(Theme.Colors.winBG)
        .task(id: "\(workspace.fleetOverviewLoadKey)|\(reloads)") {
            await load()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: workspace.profile,
            breadcrumbs: [Breadcrumb(label: L("Overview"), action: { navigate(to: .overview) })],
            title: L("Fleet Overview"),
            subtitle: current?.summary.map { L("Latest summary \($0.date)") }
                ?? L("No successful summary found for this workspace")
        ) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing fleet overview")
                }
                PNPButton(title: L("Refresh"), icon: "arrow.clockwise") {
                    reloads += 1
                }
                .help("Re-read this workspace's latest summary snapshot.")
            }
        }
    }

    @ViewBuilder
    private func workspaceDetail(_ row: FleetWorkspaceOverview) -> some View {
        // #184: each flagged condition gets its explanation and a route to the
        // screen where the operator can act on it.
        if row.hasIssue {
            profileIssuesCard(for: row)
        }

        HStack(spacing: 12) {
            StatTile(
                label: L("Macs"),
                value: row.summary.map { "\($0.totalDevices)" } ?? "--",
                sub: L("Latest successful summary")
            )
            StatTile(
                label: L("Stability"),
                value: stabilityLabel(row.summary?.stabilityIndex),
                sub: L("Composite index")
            )
            StatTile(
                label: L("Stale"),
                value: row.summary?.staleCount.map { "\($0)" } ?? "--",
                sub: L(">30d since contact")
            )
            StatTile(
                label: L("Patch"),
                value: row.summary?.patchPct.map { "\(String(format: "%.1f", $0))%" } ?? "--",
                sub: L("Devices on latest")
            )
        }

        stabilityTrendCard(for: row)
        summaryDetailsCard(for: row)
    }

    private func summaryDetailsCard(for row: FleetWorkspaceOverview) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: L("Summary Details"))
                    Spacer()
                    let index = row.summary?.stabilityIndex
                    Pill(
                        text: row.summary == nil ? L("No Data") : stabilityPillText(index),
                        tone: stabilityTone(index)
                    )
                    .accessibilityLabel(
                        stabilityAccessibilityLabel(index, hasSummary: row.summary != nil))
                }

                if let summary = row.summary {
                    VStack(spacing: 10) {
                        profileMetricRow(L("Compliance"), value: summary.compliancePct)
                        profileMetricRow(L("FileVault"), value: summary.fileVaultPct)
                        profileMetricRow(L("Current macOS"), value: summary.osCurrentPct)
                        profileMetricRow(L("EDR Agent"), value: summary.crowdstrikePct)
                        profileMetricRow(L("Patch"), value: summary.patchPct)
                        profileMetricRow(L("Stale"), value: stalePercent(summary), inverse: true)
                    }
                } else {
                    Text("Run a schedule or generate a report for this workspace to create its first summary.")
                        .font(.callout)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Theme.Colors.hairline)

                HStack {
                    Text("Open the relevant surface.")
                        .font(.callout)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                    Spacer()
                    PNPButton(title: L("Overview"), icon: Tab.overview.sfSymbol, size: .sm) {
                        navigate(to: .overview)
                    }
                    .help("Open the Overview tab.")
                    PNPButton(title: L("Computers"), icon: Tab.devices.sfSymbol, size: .sm) {
                        navigate(to: .devices)
                    }
                    .help("Open the Computers tab.")
                    PNPButton(title: L("Runs"), icon: Tab.runs.sfSymbol, size: .sm) {
                        navigate(to: .runs)
                    }
                    .help("Open the Runs tab.")
                    PNPButton(title: L("Schedules"), icon: Tab.schedules.sfSymbol, size: .sm) {
                        navigate(to: .schedules)
                    }
                    .help("Open the Schedules tab.")
                }
            }
        }
    }

    private func stabilityTrendPoints(_ summaries: [DailySummary]) -> [StabilityTrendPoint] {
        summaries.compactMap { summary in
            guard let value = summary.stabilityIndex else { return nil }
            let date = summary.parsedDate
            guard date != .distantPast else { return nil }
            return StabilityTrendPoint(date: date, value: value)
        }
    }

    private func stabilityTrendCard(for row: FleetWorkspaceOverview) -> some View {
        let points = stabilityTrendPoints(row.summaries)
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: L("Stability Trend"))
                    Spacer()
                    if !points.isEmpty {
                        Pill(text: (points.count == 1 ? L("\(points.count) snapshot") : L("\(points.count) snapshots")),
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
        EmptyStateView(
            systemImage: "chart.line.uptrend.xyaxis",
            title: L("No trend summaries yet"),
            message: L("Stability history is built from daily summary snapshots written by each collect run.")
        )
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .padding(.horizontal, 4)
    }

    private func stabilityChart(points: [StabilityTrendPoint]) -> some View {
        let stability = Theme.ChartColors.color(forMetric: .stability)
        return Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Stability", point.value)
                )
                .foregroundStyle(LinearGradient(
                    colors: [stability.opacity(0.35),
                             stability.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Stability", point.value)
                )
                .foregroundStyle(stability)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                // WCAG 1.4.4: .caption.monospaced() scales with Accessibility text size.
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                               centered: false)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                AxisValueLabel(horizontalSpacing: 6) {
                    if let pct = value.as(Double.self) {
                        Text("\(Int(pct))%")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .frame(height: 200)
        .accessibilityLabel(Self.stabilityChartLabel)
        .accessibilityChartDescriptor(TrendLineChartDescriptor(
            title: L("Stability Trend"),
            seriesName: L("Stability Index"),
            dates: points.map(\.date),
            values: points.map(\.value),
            unit: "%"
        ))
    }

    /// VoiceOver container label for the fleet stability trend chart.
    /// `nonisolated` so unit tests can assert it without View `@MainActor` isolation.
    nonisolated static let stabilityChartLabel = L("Fleet stability trend over time")

    private func profileMetricRow(_ label: String, value: Double?, inverse: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(minWidth: 112, alignment: .leading)
            GeometryReader { geo in
                let normalized = max(0, min(value ?? 0, 100)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(inverse ? Theme.Colors.warn : Theme.Colors.tealBright)
                        .frame(width: geo.size.width * normalized)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Mono(text: value.map { "\(String(format: "%.1f", $0))%" } ?? "--",
                 color: Theme.Colors.fg)
                .frame(width: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value.map { "\(String(format: "%.1f", $0))%" } ?? L("no data"))")
    }

    private func stalePercent(_ summary: DailySummary) -> Double? {
        guard let staleCount = summary.staleCount, summary.totalDevices > 0 else { return nil }
        return (Double(staleCount) / Double(summary.totalDevices)) * 100
    }

    private func profileIssuesCard(for row: FleetWorkspaceOverview) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warn)
                        .accessibilityHidden(true)
                    SectionHeader(title: L("Issues on This Workspace"))
                }
                ForEach(row.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.reason)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.Colors.warn)
                        Text(issue.explanation)
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .fixedSize(horizontal: false, vertical: true)
                        PNPButton(title: issue.actionLabel, icon: "arrow.right", size: .sm) {
                            navigate(to: issue.tab)
                        }
                        .help("Opens \(issue.tab.label).")
                    }
                }
            }
        }
    }

    private func navigate(to tab: Tab) {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
    }

    /// The task is cancelled when the profile, demo mode or `reloads` changes, so a result
    /// that arrives after is dropped, and the spinner is left to the load that replaced it.
    private func load() async {
        // A reload from disk: nothing is collected, so it neither writes the shared status
        // line (a running collect owns it) nor claims the data was refreshed.
        let source = workspace.fleetOverviewLoadKey
        if loadedSource != source { loadedSource = nil; overview = nil }
        isLoading = true
        let loaded = await workspace.loadFleetOverview()
        guard !Task.isCancelled, source == workspace.fleetOverviewLoadKey,
              let loaded = loaded.shown(for: workspace.profile) else { return }
        overview = loaded
        loadedSource = source
        isLoading = false
    }
}

private struct StabilityTrendPoint: Identifiable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// The word the tone encodes, on the tone's own thresholds.
func stabilityWord(_ value: Double?) -> String? {
    guard let value else { return nil }
    if value >= 85 { return L("Healthy") }
    if value >= 70 { return L("Watch") }
    return L("Low")
}

func stabilityPillText(_ value: Double?) -> String {
    guard let word = stabilityWord(value) else { return stabilityLabel(value) }
    return "\(word) · \(stabilityLabel(value))"
}

func stabilityAccessibilityLabel(_ value: Double?, hasSummary: Bool) -> String {
    guard hasSummary, let value, let word = stabilityWord(value) else {
        return hasSummary ? L("Stability unknown") : L("Stability: no data")
    }
    return L("Stability \(word), \(String(format: "%.1f", value)) percent")
}

private func stabilityLabel(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(String(format: "%.1f", value))%"
}

private func stabilityTone(_ value: Double?) -> Pill.Tone {
    guard let value else { return .muted }
    if value >= 85 { return .teal }
    if value >= 70 { return .warn }
    return .danger
}

/// One flagged condition: what tripped, why it matters, and the screen where the operator can act.
struct FleetProfileIssue: Identifiable {
    var id: String { reason }
    let reason: String
    let explanation: String
    let actionLabel: String
    let tab: Tab
}

/// Why a workspace is flagged (#184), for Fleet Overview's issues card.
func fleetProfileIssues(_ summary: DailySummary?) -> [FleetProfileIssue] {
    guard let summary else {
        return [FleetProfileIssue(
            reason: L("No summary collected yet"),
            explanation: L("No successful collect has produced a daily summary for this profile, so its fleet metrics are unknown."),
            actionLabel: L("Open Overview"),
            tab: .overview
        )]
    }
    var issues: [FleetProfileIssue] = []
    if let stability = summary.stabilityIndex, stability < 70 {
        issues.append(FleetProfileIssue(
            reason: L("Stability \(String(format: "%.0f", stability)) (below 70)"),
            explanation: L("Composite of the summary's compliance, patch posture, and stale-device metrics. Components the last collect could not measure are dropped and the rest reweighted, so the score reflects measured data only."),
            actionLabel: L("Open Trends"),
            tab: .trends
        ))
    }
    if let staleCount = summary.staleCount, staleCount > 0 {
        issues.append(FleetProfileIssue(
            reason: (staleCount == 1 ? L("\(staleCount) stale computer") : L("\(staleCount) stale computers")),
            explanation: L("Computers that have not checked in for more than 30 days. Offline Outreach buckets them by how long they have been quiet."),
            actionLabel: L("Open Offline Outreach"),
            tab: .outreach
        ))
    }
    // Absent metric data isn't grounds for flagging the profile — under-flag rather
    // than over-flag. A nil here means the snapshot didn't carry the field at all.
    if let fileVaultPct = summary.fileVaultPct, fileVaultPct < 90 {
        issues.append(FleetProfileIssue(
            reason: L("FileVault \(String(format: "%.1f", fileVaultPct))% (below 90%)"),
            explanation: L("Share of computers reporting FileVault encryption enabled in the latest security snapshot."),
            actionLabel: L("Open Security Posture"),
            tab: .securityPosture
        ))
    }
    if let patchPct = summary.patchPct, patchPct < 80 {
        issues.append(FleetProfileIssue(
            reason: L("Patch \(String(format: "%.1f", patchPct))% (below 80%)"),
            explanation: L("Share of computers on the latest version of their patch titles, in the latest patch snapshot."),
            actionLabel: L("Open Patch Compliance"),
            tab: .patch
        ))
    }
    return issues
}
