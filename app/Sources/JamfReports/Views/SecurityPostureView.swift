import SwiftUI
import Charts

/// Detailed security posture screen. Surfaces the v3.5 weighted Security Score
/// and per-control KPIs that previously only existed inside the Excel Fleet
/// Health Dashboard. Reads the latest `pro security report` snapshot via
/// `SecurityPostureService`.
struct SecurityPostureView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot: SecurityPostureService.Snapshot = .empty
    @State private var hasLoaded = false
    /// User-configurable weight overrides edited in ConfigView → Scoring tab.
    /// Empty string ⇒ the v3.5 defaults via `ScoringConfig.parse`.
    @AppStorage(ScoringConfig.storageKey) private var scoringRaw: String = ""

    /// Encryption-category templates from jamf-cli `pro sg` (PR #205, target release TBD).
    /// Loaded once per profile; empty when feature-detect fails (older jamf-cli).
    @State private var encryptionTemplates: [SmartGroupTemplate] = []
    @State private var selectedTemplate: SmartGroupTemplate?
    @State private var bridge = CLIBridge()

    /// Encryption templates in operational priority order — not-encrypted is
    /// the most actionable (devices with FV completely off), followed by IRK
    /// problems where the policy is partially applied but recovery is broken.
    private static let templateOrder: [String] = [
        "encryption/not-encrypted",
        "encryption/invalid-recovery-key",
        "encryption/escrow-missing",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    kicker: "Posture",
                    title: "Security Posture",
                    subtitle: subtitle,
                    lastModified: snapshot.snapshotDate
                )
                if snapshot.totalDevices == 0 {
                    emptyState
                } else {
                    heroScoreCard
                    kpiGrid
                    if !encryptionTemplates.isEmpty {
                        encryptionSmartGroupBar
                    }
                    actionItemsCard
                    osDistributionCard
                }
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .task(id: workspace.profile) { await loadEncryptionTemplates() }
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
        .sheet(item: $selectedTemplate) { template in
            SmartGroupApplySheet(
                viewModel: SmartGroupApplySheetViewModel(
                    template: template,
                    profile: workspace.profile,
                    templateService: SmartGroupTemplateService(
                        executor: DefaultCLIExecutor(bridge: bridge)
                    ),
                    applyService: SmartGroupApplyService(
                        executor: DefaultCLIExecutor(bridge: bridge)
                    )
                )
            )
            .environment(workspace)
        }
    }

    /// "Action row under the FV KPI" per the design plan. Sits between the
    /// KPI grid and the action-items card so the operator can go from
    /// "FV coverage is N%" → "Create smart group for the gap" → action items
    /// without scrolling.
    private var encryptionSmartGroupBar: some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Colors.gold)
                Text("Encryption remediation")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Menu("Create smart group") {
                    ForEach(encryptionTemplates) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            Text(Self.menuLabel(for: template))
                        }
                    }
                }
                .help("Open a template-driven sheet to create a smart group for an encryption gap")
            }
        }
    }

    private static func menuLabel(for template: SmartGroupTemplate) -> String {
        switch template.slug {
        case "encryption/not-encrypted":        return "Devices not encrypted"
        case "encryption/invalid-recovery-key": return "Invalid recovery key"
        case "encryption/escrow-missing":       return "Recovery key escrow missing"
        default:                     return template.description.isEmpty ? template.slug : template.description
        }
    }

    private func loadEncryptionTemplates() async {
        let service = SmartGroupTemplateService(executor: DefaultCLIExecutor(bridge: bridge))
        do {
            let all = try await service.listTemplates(profile: workspace.profile)
            let bySlug = Dictionary(uniqueKeysWithValues: all.map { ($0.slug, $0) })
            encryptionTemplates = Self.templateOrder.compactMap { bySlug[$0] }
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            encryptionTemplates = []
        } catch {
            AppLogger.cli.error(
                "SecurityPostureView smart-group templates load failed: \(String(describing: error), privacy: .private)"
            )
            encryptionTemplates = []
        }
    }

    private var subtitle: String? {
        if snapshot.totalDevices == 0 { return nil }
        return "Weighted across \(snapshot.totalDevices) device\(snapshot.totalDevices == 1 ? "" : "s")."
    }

    // MARK: - Data loading

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    private func reload() {
        snapshot = workspace.demoMode
            ? Self.demoSnapshot
            : SecurityPostureService.load(profile: workspace.profile)
    }

    private static let demoSnapshot = SecurityPostureService.Snapshot(
        totalDevices: 655,
        fileVaultEncrypted: 647,
        sipEnabled: 655,
        firewallEnabled: 655,
        gatekeeperEnabled: 640,
        osVersions: [
            .init(osVersion: "15.4.1", count: 380, pct: 58),
            .init(osVersion: "14.7.5", count: 180, pct: 27),
            .init(osVersion: "13.7.10", count: 70, pct: 11),
            .init(osVersion: "26.0.0", count: 25, pct: 4)
        ],
        sourceFile: nil,
        snapshotDate: Date()
    )

    // MARK: - Computed values

    private var score: SecurityScore {
        let weights = scoringRaw.isEmpty
            ? SecurityScoreWeights.defaultWeights
            : ScoringConfig.parse(scoringRaw).weights
        return SecurityScoreCalculator.score(
            input: SecurityScoreCalculator.input(from: snapshot),
            weights: weights
        )
    }

    private var actionItems: (p0: Int, p1: Int, p2: Int) {
        // P0 = devices missing FileVault, SIP, or Firewall. P1 = devices
        // missing Gatekeeper. P2 reserved. Matches v3.5 surface taxonomy.
        let total = snapshot.totalDevices
        let p0 = [
            snapshot.fileVaultEncrypted,
            snapshot.sipEnabled,
            snapshot.firewallEnabled
        ]
            .compactMap { $0 }
            .map { total - $0 }
            .reduce(0, +)
        let p1 = (snapshot.gatekeeperEnabled.map { total - $0 }) ?? 0
        return (p0, p1, 0)
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "lock.shield",
                title: "No security snapshot yet",
                message: "Run `jamf-cli pro report security` (Sources tab → Refresh) and this screen will populate."
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
                        Pill(text: score.grade.rawValue,
                             tone: pillTone(for: score.grade))
                    }
                    if !score.available.isEmpty {
                        Text(availabilityText)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    if !score.missing.isEmpty {
                        Text(missingText)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                Spacer()
            }
        }
    }

    private var availabilityText: String {
        let names = score.available.map(\.displayLabel).joined(separator: ", ")
        return "Weighted across: \(names)."
    }

    private var missingText: String {
        let names = score.missing.map(\.displayLabel).joined(separator: ", ")
        return "Not in this snapshot (run collect on EA results + device-compliance to include): \(names)."
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
            kpiTile(label: "FileVault", count: snapshot.fileVaultEncrypted)
            kpiTile(label: "SIP", count: snapshot.sipEnabled)
            kpiTile(label: "Firewall", count: snapshot.firewallEnabled)
            kpiTile(label: "Gatekeeper", count: snapshot.gatekeeperEnabled)
            StatTile(
                label: "Total Devices",
                value: "\(snapshot.totalDevices)",
                sub: "Across active and recently inactive"
            )
        }
    }

    @ViewBuilder
    private func kpiTile(label: String, count: Int?) -> some View {
        let total = snapshot.totalDevices
        if let count, total > 0 {
            let pct = (Double(count) / Double(total)) * 100
            StatTile(
                label: label,
                value: String(format: "%.1f%%", pct),
                sub: "\(count) of \(total)"
            )
        } else {
            StatTile(
                label: label,
                value: "—",
                sub: "Not in snapshot"
            )
        }
    }

    private var actionItemsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Action Items", trailing: "By priority")
                HStack(spacing: 12) {
                    actionTile(level: "P0", count: actionItems.p0,
                               caption: "FileVault / SIP / Firewall gaps",
                               tone: .danger)
                    actionTile(level: "P1", count: actionItems.p1,
                               caption: "Gatekeeper gaps",
                               tone: .warn)
                }
            }
        }
    }

    private func actionTile(level: String, count: Int, caption: String,
                            tone: Pill.Tone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Pill(text: level, tone: tone)
                Text("\(count)")
                    .font(Theme.Fonts.serif(22, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(Theme.Colors.fgMuted)
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
                        .foregroundStyle(Theme.Colors.fgMuted)
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
            suggestedFilename: DashboardChartExport.filename(for: "macos-version-distribution")
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
        .chartForegroundStyleScale(domain: orderedKeys, range: Theme.ChartPalette.osVersionInApp)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: score.value)
            VStack(spacing: 2) {
                Text(displayValue)
                    .font(Theme.Fonts.serif(32, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
                Text("of 100")
                    .font(Theme.Fonts.mono(9.5))
                    .tracking(1.0)
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Security score \(displayValue) of 100, grade \(score.grade.rawValue)")
    }

    private var clamped: Double {
        guard score.value.isFinite else { return 0 }
        return min(max(score.value / 100, 0), 1)
    }

    private var displayValue: String {
        guard score.value.isFinite else { return "—" }
        return String(format: "%.1f", score.value)
    }
}

// MARK: - Export-only chart

/// Light-mode export rendering of the macOS version distribution donut.
/// Stands alone so `ImageRenderer` can capture it without the dashboard's
/// dark `Theme` context bleeding through.
private struct SecurityPostureOSDonutExport: View {
    let rows: [SecurityPostureService.Snapshot.OSVersion]
    let totalDevices: Int

    /// Fixed palette chosen for legibility on the light export canvas. Mirrors
    /// the ChartExportView color discipline — saturated but not neon.
    private static let palette: [Color] = Theme.ChartPalette.osVersionExport

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Chart(Array(rows.enumerated()), id: \.offset) { offset, row in
                SectorMark(
                    angle: .value("Count", row.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .foregroundStyle(Self.palette[offset % Self.palette.count])
            }
            .chartLegend(.hidden)
            .frame(width: 260, height: 260)
            .accessibilityChartDescriptor(
                SectorChartDescriptor(
                    title: "macOS Version Distribution",
                    unit: " devices",
                    slices: rows.map { row in
                        SectorChartDescriptor.Slice(
                            label: row.osVersion,
                            value: Double(row.count)
                        )
                    }
                )
            )

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.palette[offset % Self.palette.count])
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
