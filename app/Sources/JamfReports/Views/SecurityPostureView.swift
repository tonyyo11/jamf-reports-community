import SwiftUI
import Charts

/// Detailed security posture screen. Surfaces the v3.5 weighted Security Score
/// and per-control KPIs that previously only existed inside the Excel Fleet
/// Health Dashboard. Reads the latest `pro security report` snapshot via
/// `SecurityPostureService`.
struct SecurityPostureView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    // WCAG 1.4.4: Dynamic Type scaling for KPI numerals
    @ScaledMetric(relativeTo: .title) private var actionTileSize: CGFloat = 22
    @State private var snapshot: SecurityPostureService.Snapshot = .empty
    /// The `dataSource` `snapshot` was read for; the content waits for it to match, so the
    /// screen never says there is no data, or shows another profile's, while one loads.
    @State private var loadedSource: String?
    @State private var reloads = 0

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Posture",
                title: "Security Posture",
                subtitle: subtitle,
                // The demo dataset is fixed; an age measured from today would grow
                // for as long as the demo stays open.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )

            if loadedSource != dataSource {
                ScreenLoadingCard(what: "security posture")
            } else {
                content
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    @ViewBuilder
    private var content: some View {
        // Shared StaleDataBanner surfaces snapshot freshness above the main content.
        // Suppressed in demo mode (the demo dataset is intentionally static and
        // not user-perceivably "stale"). Renders nothing when source is .fresh.
        if !workspace.demoMode {
            CollectNowBanner(source: snapshot.cacheSource, tiers: [.refresh])
            // Per-kind file dates are the honest per-screen signal here;
            // digest-level collectionSources belongs on summary screens only.
            FreshnessChipRow(
                sourceDates: snapshot.sourceDates,
                expectedKinds: ["security"]
            )
        }

        if let reason = snapshot.loadError {
            Card(padding: 24) {
                ErrorStateView(
                    title: "Couldn't read security data",
                    message: reason,
                    commands: ["Re-run collection from Data Sources, then Refresh."],
                    retry: { reloads += 1 }
                )
            }
        } else if snapshot.totalDevices == 0 {
            emptyState
        } else {
            heroScoreCard
            kpiGrid
            aiInsightCard
            actionItemsCard
            osDistributionCard
        }
    }

    private var subtitle: String? {
        if snapshot.totalDevices == 0 { return nil }
        let count = snapshot.totalDevices
        return "Weighted across \(count) computer\(count == 1 ? "" : "s")."
    }

    // MARK: - Data loading

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { loadedSource = nil; snapshot = .empty }
        guard !workspace.demoMode else {
            snapshot = DemoData.securityPostureSnapshot
            loadedSource = source
            return
        }
        let profile = workspace.profile
        guard let loaded = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: { SecurityPostureService.load(profile: profile) }
        ) else { return }
        snapshot = loaded
        loadedSource = source
    }

    // MARK: - Computed values

    private var score: SecurityScore { Self.score(snapshot) }

    /// The ring's score, over the workspace's factors, from the same inputs as summary.json's
    /// `securityScore` and the workbook's Executive Summary.
    static func score(_ snapshot: SecurityPostureService.Snapshot) -> SecurityScore {
        SecurityScoreCalculator.score(
            factors: snapshot.scoreFactors, measures: snapshot.scoreMeasures)
    }

    private var actionItems: (p0: Int, p1: Int, p2: Int) {
        // P0 = FileVault, SIP or Firewall failures under the workspace's policy. P1 =
        // Gatekeeper failures. P2 reserved. Matches v3.5 surface taxonomy.
        (Self.p0TileCount(snapshot.fleetCounts), snapshot.fleetCounts.p1 ?? 0, 0)
    }

    /// An Action Items caption with the values the tile leaves out because Jamf did not
    /// report them.
    static func actionCaption(_ base: String, notReported: Int) -> String {
        notReported > 0 ? base + " · not reported: \(notReported)" : base
    }

    /// summary.json writes no P0 without a FileVault count; the tile still sums the
    /// controls the report does carry, as it always has.
    static func p0TileCount(_ fleet: SecurityFleetCounts) -> Int {
        fleet.p0 ?? [SecurityControl.sip, .firewall].compactMap { fleet.controls[$0]?.fail }
            .reduce(0, +)
    }

    /// A KPI tile's sub-line. The tile's value stays the fact; this says how the
    /// workspace's policy counts the Macs where the control is off.
    static func kpiTileSub(
        _ control: SecurityControl, on: Int, total: Int, fleet: SecurityFleetCounts
    ) -> String {
        let counts = fleet.controls[control]
        if counts?.level == .ignore { return "Not counted by this workspace's policy" }
        var base = "\(on) of \(total)"
        if let missing = counts?.notReported, missing > 0 { base += " · not reported: \(missing)" }
        let lowered = fleet.fileVaultOffHardwareEncrypted
        if control == .fileVault, lowered > 0 {
            return base + " · \(lowered) more hardware-encrypted, FileVault off"
        }
        if let warnings = counts?.warning, warnings > 0 {
            return base + " · \(warnings) warning\(warnings == 1 ? "" : "s")"
        }
        return base
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "lock.shield",
                title: "No security snapshot yet",
                message: "Collect data for this screen with the Collect now banner when it shows, "
                    + "or run this command.",
                commands: [EmptyStateView.collectCommand(
                    profile: workspace.profile, kinds: ["security"])]
            )
        }
    }

    @ViewBuilder
    private var heroScoreCard: some View {
        Card {
            HStack(alignment: .center, spacing: 28) {
                ScoreRing(score: score)
                    .frame(width: 168, height: 168)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Security Score")
                            .font(.headline)
                            .foregroundStyle(Theme.Colors.fg)
                        if !score.parts.isEmpty {
                            Pill(text: score.grade.rawValue,
                                 tone: pillTone(for: score.grade))
                        }
                    }
                    if score.parts.isEmpty {
                        Text(Self.noScoreCaption)
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        ScoreBreakdownList(
                            score: score, staleDays: snapshot.staleDays,
                            staleBasis: snapshot.staleBasis)
                    }
                    // The demo cannot collect, so it never tells its viewer to.
                    if !score.missing.isEmpty && !workspace.demoMode {
                        Text(Self.missingText(
                            score, fleet: snapshot.fleetCounts, staleDays: snapshot.staleDays,
                            staleBasis: snapshot.staleBasis))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
                Spacer()
            }
        }
    }

    static let noScoreCaption = "No factor had data"

    /// The ring's number: a dash when nothing was scored, never a 0.0 that reads as grade F.
    static func scoreText(_ score: SecurityScore) -> String {
        guard !score.parts.isEmpty, score.value.isFinite else { return "—" }
        return String(format: "%.1f", score.value)
    }

    /// The hero card's line for metrics the ring does not score. FileVault, when the report
    /// carries it but the hardware rule left no Mac to score it over, gets its own reason.
    static func missingText(
        _ score: SecurityScore, fleet: SecurityFleetCounts, staleDays: Int? = nil,
        staleBasis: [StaleBasis] = StaleBasis.default
    ) -> String {
        let fileVaultNotCounted = score.missing.contains { $0.kind == .fileVault }
            && fleet.controls[.fileVault] != nil
        let names = score.missing
            .filter { !(fileVaultNotCounted && $0.kind == .fileVault) }
            .map { $0.label(staleDays: staleDays, staleBasis: staleBasis) }
            .joined(separator: ", ")
        var sentences: [String] = []
        // A factor has no data when its snapshot was not collected, or when it judged no Mac
        // (an agent no Mac reports, a SOFA feed not yet cached). The line says what has no
        // data and asks for no collect.
        if !names.isEmpty {
            sentences.append("No data for \(names), so not scored.")
        }
        if fileVaultNotCounted {
            sentences.append("FileVault is not scored: every Mac with it off is "
                + "hardware-encrypted and not counted by this workspace's policy.")
        }
        return sentences.joined(separator: " ")
    }

    private func pillTone(for grade: SecurityScore.Grade) -> Pill.Tone {
        switch grade {
        case .aPlus, .a, .b: return .teal
        case .c:             return .gold
        case .d:             return .warn
        case .f:             return .danger
        }
    }

    private var kpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            kpiTile(label: "FileVault", control: .fileVault, count: snapshot.fileVaultEncrypted)
            kpiTile(label: "SIP", control: .sip, count: snapshot.sipEnabled)
            kpiTile(label: "Firewall", control: .firewall, count: snapshot.firewallEnabled)
            kpiTile(label: "Gatekeeper", control: .gatekeeper, count: snapshot.gatekeeperEnabled)
            StatTile(
                label: "Total Computers",
                value: "\(snapshot.totalDevices)",
                sub: "Across active and recently inactive"
            )
        }
    }

    @ViewBuilder
    private func kpiTile(label: String, control: SecurityControl, count: Int?) -> some View {
        let total = snapshot.totalDevices
        if let count, total > 0 {
            let pct = (Double(count) / Double(total)) * 100
            // Rounded as the AI card rounds it, so an exact x.x5 reads the same in both.
            StatTile(
                label: label,
                value: FleetInsightInput.Value.percent(pct).text,
                sub: Self.kpiTileSub(
                    control, on: count, total: total, fleet: snapshot.fleetCounts)
            )
        } else {
            StatTile(
                label: label,
                value: "—",
                sub: "Not in snapshot"
            )
        }
    }

    /// macOS 27, opt-in: which control to work first. The card hides itself while
    /// `ai.enabled` is off; the input is built only where it can show.
    @ViewBuilder
    private var aiInsightCard: some View {
        if AIInsightCard.isOffered(demoMode: workspace.demoMode),
           let input = FleetInsightInput.posture(.security(snapshot)) {
            AIInsightCard(
                title: "AI Posture Insight",
                idleText: "Suggest which security control to work first using on-device "
                    + "intelligence.",
                provenanceText: "AI-generated from the counts on this screen — verify against "
                    + "the tiles above.",
                input: input
            )
        }
    }

    private var actionItemsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Action Items", trailing: "By priority")
                HStack(spacing: 12) {
                    actionTile(level: "P0", count: actionItems.p0,
                               caption: Self.actionCaption(
                                   "FileVault / SIP / Firewall gaps",
                                   notReported: snapshot.fleetCounts.p0NotReported),
                               tone: .danger)
                    actionTile(level: "P1", count: actionItems.p1,
                               caption: Self.actionCaption(
                                   "Gatekeeper gaps",
                                   notReported: snapshot.fleetCounts.p1NotReported),
                               tone: .warn)
                }
                openDevicesRow
            }
        }
    }

    /// Takes the reader from the P0 and P1 counts to the Macs with a security gap.
    private var openDevicesRow: some View {
        HStack {
            Text("Open Computers to see which Macs have a security gap.")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Spacer()
            PNPButton(title: "Open Computers", icon: Tab.devices.sfSymbol, size: .sm) {
                NotificationCenter.default.post(
                    name: .navigateToTab, object: nil,
                    userInfo: DevicesView.DeviceFilter.security.navigationUserInfo())
            }
        }
    }

    private func actionTile(level: String, count: Int, caption: String,
                            tone: Pill.Tone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Pill(text: level, tone: tone)
                Text("\(count)")
                    .font(Theme.Fonts.serif(actionTileSize, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(level) priority, \(count) devices, \(caption)")
    }

    private var osDistributionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "macOS Version Distribution")
                    if !snapshot.osVersions.isEmpty {
                        PNPButton(
                            title: "Export PNG",
                            icon: "square.and.arrow.down",
                            style: .neutral,
                            size: .sm,
                            action: exportOSChart
                        )
                        .accessibilityLabel("Export macOS version distribution chart as PNG")
                        .help("Save the macOS version distribution donut as a PNG image")
                    }
                }
                if snapshot.osVersions.isEmpty {
                    Text("No OS version data in this snapshot.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    osChart
                }
            }
        }
    }

    private func exportOSChart() {
        let rows = osChartRows
        let total = snapshot.totalDevices
        let result = DashboardChartExport.run(
            title: "macOS Version Distribution",
            subtitle: "Security Posture",
            footnote: "Source: pro report security · \(total) devices",
            suggestedFilename: DashboardChartExport.filename(for: "macos-version-distribution", profile: workspace.profile)
        ) {
            SecurityPostureOSDonutExport(rows: rows, totalDevices: total)
        }
        if case .failure(let error) = result {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    /// Cap legend entries so the trailing legend stays within the card. The
    /// tail of small OS versions rolls into a single "Other" slice; without
    /// this, tenants with 15+ point releases get a legend taller than the
    /// donut and unreadable slivers in the pie.
    private static let osChartTopCount = 10

    private var osChartRows: [SecurityPostureService.Snapshot.OSVersion] {
        let sorted = snapshot.osVersions.sorted { $0.count > $1.count }
        guard sorted.count > Self.osChartTopCount else { return sorted }
        let top = Array(sorted.prefix(Self.osChartTopCount))
        let tail = sorted.dropFirst(Self.osChartTopCount)
        let tailCount = tail.reduce(0) { $0 + $1.count }
        let tailPct = tail.reduce(0.0) { $0 + $1.pct }
        return top + [.init(osVersion: "Other (\(tail.count))", count: tailCount, pct: tailPct)]
    }

    private var osChart: some View {
        let orderedKeys = osChartRows.sorted { $0.count > $1.count }.map(\.osVersion)
        return Chart(osChartRows, id: \.osVersion) { row in
            SectorMark(
                angle: .value("Count", row.count),
                innerRadius: .ratio(0.62),
                angularInset: 1.2
            )
            .foregroundStyle(by: .value("Version", row.osVersion))
            .accessibilityLabel(row.osVersion)
            .accessibilityValue("\(row.count) devices, \(Int(row.pct.rounded()))%")
        }
        .chartForegroundStyleScale(
            domain: orderedKeys, range: Theme.ChartColors.colors(forVersions: orderedKeys))
        // ViewThatFits picks the trailing legend when there's room, otherwise
        // falls back to a bottom legend so narrow cards don't truncate.
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .frame(minHeight: 220, idealHeight: 260)
        .accessibilityLabel("macOS version distribution across the fleet")
        .accessibilityChartDescriptor(
            SectorChartDescriptor(
                title: "macOS Version Distribution",
                unit: " devices",
                slices: osChartRows.map { row in
                    SectorChartDescriptor.Slice(
                        label: row.osVersion,
                        value: Double(row.count)
                    )
                }
            )
        )
    }
}

// MARK: - Score ring

/// Lightweight circular gauge for the hero Security Score. Two stroked
/// `Circle` shapes: track + filled arc. The center renders the score and
/// letter grade in the same `Theme.Fonts.serif` used by `StatTile`.
private struct ScoreRing: View {
    let score: SecurityScore
    @Environment(\.colorSchemeContrast) private var contrast

    // WCAG 1.4.4: Dynamic Type scaling for KPI numerals
    @ScaledMetric(relativeTo: .largeTitle) private var scoreDisplaySize: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.hairlineStrong, lineWidth: 14)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    Color(hex: score.grade.colorHex),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .motionSafeAnimation(.easeOut(duration: 0.5), value: score.value)
            VStack(spacing: 2) {
                Text(displayValue)
                    .font(Theme.Fonts.serif(scoreDisplaySize, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
                Text("of 100")
                    .font(Theme.Fonts.mono(9.5))
                    .tracking(1.0)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.parts.isEmpty
            ? "Security score: \(SecurityPostureView.noScoreCaption)"
            : "Security score \(displayValue) of 100, grade \(score.grade.rawValue)")
    }

    private var clamped: Double {
        guard !score.parts.isEmpty, score.value.isFinite else { return 0 }
        return min(max(score.value / 100, 0), 1)
    }

    private var displayValue: String { SecurityPostureView.scoreText(score) }
}

// MARK: - Export-only chart

/// Light-mode export rendering of the macOS version distribution donut.
/// Stands alone so `ImageRenderer` can capture it without the dashboard's
/// dark `Theme` context bleeding through.
private struct SecurityPostureOSDonutExport: View {
    let rows: [SecurityPostureService.Snapshot.OSVersion]
    let totalDevices: Int

    var body: some View {
        let colors = Theme.ChartColors.colors(forVersions: rows.map(\.osVersion), scheme: .light)
        HStack(alignment: .center, spacing: 24) {
            Chart(Array(rows.enumerated()), id: \.offset) { offset, row in
                SectorMark(
                    angle: .value("Count", row.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .foregroundStyle(colors[offset])
            }
            .chartLegend(.hidden)
            .frame(width: 260, height: 260)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colors[offset])
                            .frame(width: 10, height: 10)
                        Text(row.osVersion)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(hex: 0x111827))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(row.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .monospacedDigit()
                        Text(String(format: "%.0f%%", row.pct))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                            .frame(width: 40, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Under the score ring: each scored factor, its share of Macs and the points it adds.
struct ScoreBreakdownList: View {
    let score: SecurityScore
    let staleDays: Int?
    var staleBasis: [StaleBasis] = StaleBasis.default

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(score.parts, id: \.factor.key) { part in
                GridRow {
                    Text(part.factor.label(staleDays: staleDays, staleBasis: staleBasis))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.percent(part.share))
                        .gridColumnAlignment(.trailing)
                    Text(Self.points(score.points(of: part)))
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(Theme.Text.tertiary(contrast))
        .accessibilityElement(children: .combine)
    }

    static func percent(_ share: Double) -> String { String(format: "%.1f%%", share) }

    static func points(_ value: Double) -> String { String(format: "%.1f pts", value) }
}
