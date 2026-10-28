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

    /// The loaded overview, only while it is the sidebar profile's.
    private var current: FleetWorkspaceOverview? { overview?.shown(for: workspace.profile) }

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
        .task(id: workspace.fleetOverviewLoadKey) {
            await load()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: workspace.profile,
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigate(to: .overview) })],
            title: "Fleet Overview",
            subtitle: current?.summary.map { "Latest summary \($0.date)" }
                ?? "No successful summary found for this workspace"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Refreshing fleet overview")
                    }
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .help("Re-read this workspace's latest summary snapshot.")
                }
            )
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
                label: "Macs",
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
                value: row.summary?.staleCount.map { "\($0)" } ?? "--",
                sub: ">30d since contact"
            )
            StatTile(
                label: "Patch",
                value: row.summary?.patchPct.map { "\(String(format: "%.1f", $0))%" } ?? "--",
                sub: "Devices on latest"
            )
        }

        stabilityTrendCard(for: row)
        summaryDetailsCard(for: row)
    }

    private func summaryDetailsCard(for row: FleetWorkspaceOverview) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Summary Details")
                    Spacer()
                    let index = row.summary?.stabilityIndex
                    Pill(
                        text: row.summary == nil ? "No Data" : stabilityPillText(index),
                        tone: stabilityTone(index)
                    )
                    .accessibilityLabel(
                        stabilityAccessibilityLabel(index, hasSummary: row.summary != nil))
                }

                if let summary = row.summary {
                    VStack(spacing: 10) {
                        profileMetricRow("Compliance", value: summary.compliancePct)
                        profileMetricRow("FileVault", value: summary.fileVaultPct)
                        profileMetricRow("Current macOS", value: summary.osCurrentPct)
                        profileMetricRow("EDR Agent", value: summary.crowdstrikePct)
                        profileMetricRow("Patch", value: summary.patchPct)
                        profileMetricRow("Stale", value: stalePercent(summary), inverse: true)
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
                    PNPButton(title: "Overview", icon: Tab.overview.sfSymbol, size: .sm) {
                        navigate(to: .overview)
                    }
                    .help("Open the Overview tab.")
                    PNPButton(title: "Computers", icon: Tab.devices.sfSymbol, size: .sm) {
                        navigate(to: .devices)
                    }
                    .help("Open the Computers tab.")
                    PNPButton(title: "Runs", icon: Tab.runs.sfSymbol, size: .sm) {
                        navigate(to: .runs)
                    }
                    .help("Open the Runs tab.")
                    PNPButton(title: "Schedules", icon: Tab.schedules.sfSymbol, size: .sm) {
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
        EmptyStateView(
            systemImage: "chart.line.uptrend.xyaxis",
            title: "No trend summaries yet",
            message: "Stability history is built from daily summary snapshots written by each collect run."
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
            title: "Stability Trend",
            seriesName: "Stability Index",
            dates: points.map(\.date),
            values: points.map(\.value),
            unit: "%"
        ))
    }

    /// VoiceOver container label for the fleet stability trend chart.
    /// `nonisolated` so unit tests can assert it without View `@MainActor` isolation.
    nonisolated static let stabilityChartLabel = "Fleet stability trend over time"

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
        .accessibilityLabel("\(label): \(value.map { "\(String(format: "%.1f", $0))%" } ?? "no data")")
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
                    SectionHeader(title: "Issues on This Workspace")
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

    private func load() async {
        // A reload from disk: nothing is collected, so it neither writes the shared status
        // line (a running collect owns it) nor claims the data was refreshed.
        isLoading = true
        defer { isLoading = false }
        let loaded = await workspace.loadFleetOverview()
        guard !Task.isCancelled, let loaded = loaded.shown(for: workspace.profile) else { return }
        overview = loaded
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
    if value >= 85 { return "Healthy" }
    if value >= 70 { return "Watch" }
    return "Low"
}

func stabilityPillText(_ value: Double?) -> String {
    guard let word = stabilityWord(value) else { return stabilityLabel(value) }
    return "\(word) · \(stabilityLabel(value))"
}

func stabilityAccessibilityLabel(_ value: Double?, hasSummary: Bool) -> String {
    guard hasSummary, let value, let word = stabilityWord(value) else {
        return hasSummary ? "Stability unknown" : "Stability: no data"
    }
    return "Stability \(word), \(String(format: "%.1f", value)) percent"
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
            reason: "No summary collected yet",
            explanation: "No successful collect has produced a daily summary for this "
                + "profile, so its fleet metrics are unknown.",
            actionLabel: "Open Overview",
            tab: .overview
        )]
    }
    var issues: [FleetProfileIssue] = []
    if let stability = summary.stabilityIndex, stability < 70 {
        issues.append(FleetProfileIssue(
            reason: "Stability \(String(format: "%.0f", stability)) (below 70)",
            explanation: "Composite of the summary's compliance, patch posture, and "
                + "stale-device metrics. Components the last collect could not "
                + "measure are dropped and the rest reweighted, so the score "
                + "reflects measured data only.",
            actionLabel: "Open Trends",
            tab: .trends
        ))
    }
    if let staleCount = summary.staleCount, staleCount > 0 {
        issues.append(FleetProfileIssue(
            reason: "\(staleCount) stale computer\(staleCount == 1 ? "" : "s")",
            explanation: "Computers that have not checked in for more than 30 days. Offline "
                + "Outreach buckets them by how long they have been quiet.",
            actionLabel: "Open Offline Outreach",
            tab: .outreach
        ))
    }
    // Absent metric data isn't grounds for flagging the profile — under-flag rather
    // than over-flag. A nil here means the snapshot didn't carry the field at all.
    if let fileVaultPct = summary.fileVaultPct, fileVaultPct < 90 {
        issues.append(FleetProfileIssue(
            reason: "FileVault \(String(format: "%.1f", fileVaultPct))% (below 90%)",
            explanation: "Share of computers reporting FileVault encryption enabled "
                + "in the latest security snapshot.",
            actionLabel: "Open Security Posture",
            tab: .securityPosture
        ))
    }
    if let patchPct = summary.patchPct, patchPct < 80 {
        issues.append(FleetProfileIssue(
            reason: "Patch \(String(format: "%.1f", patchPct))% (below 80%)",
            explanation: "Share of computers on the latest version of their patch titles, "
                + "in the latest patch snapshot.",
            actionLabel: "Open Patch Compliance",
            tab: .patch
        ))
    }
    return issues
}
