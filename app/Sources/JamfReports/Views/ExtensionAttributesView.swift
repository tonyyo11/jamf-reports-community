import SwiftUI
import Charts

/// Extension Attributes dashboard. Surfaces EA coverage and value distributions
/// from `pro report ea-results --all` and `computer-extension-attributes list`
/// snapshots. Shows which EAs are actually populating data across the fleet
/// and what values are appearing.
struct ExtensionAttributesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: ExtensionAttributeService.Snapshot = .empty
    @State private var hasLoaded = false
    @State private var selectedEA: String?
    @State private var sortOrder: SortOrder = .devices
    @State private var coverageDrift: [EAParseHealthService.CoverageDrift] = []

    /// Only EAs whose fleet coverage dropped sharply since the previous collect.
    private static let driftAlertThresholdPP: Double = -15

    /// Cap the drift callout's row list; the rest collapse into "+N more".
    private static let driftDisplayCap = 5

    private enum SortOrder: String, CaseIterable {
        case devices = "Devices"
        case name = "Name"
    }

    /// Cap the rendered count so tenants with hundreds of EAs don't slow the
    /// view diff. Full list is always available in the generated Excel report.
    private static let definitionsDisplayCap = 100

    /// Threshold above which the view surfaces a "Top values shown per EA;
    /// generated reports include all values." footnote. ~25k rows is the
    /// point at which the topValueLimit cap starts hiding meaningful tails.
    private static let largeFleetRowThreshold = 25_000

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Inventory",
                title: "Extension Attributes",
                subtitle: subtitle,
                lastModified: snapshot.snapshotDate
            )
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
            }
            if snapshot.totalEAs == 0 {
                emptyState
            } else {
                kpiGrid
                driftCard
                coverageCard
                if let selectedEA, !selectedEA.isEmpty {
                    valueDistributionCard(for: selectedEA)
                }
                definitionsCard
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    private var subtitle: String? {
        guard snapshot.totalEAs > 0 else { return nil }
        return "\(snapshot.totalEAs) Extension Attribute\(snapshot.totalEAs == 1 ? "" : "s") across \(snapshot.totalDevices) device\(snapshot.totalDevices == 1 ? "" : "s")."
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
            : ExtensionAttributeService.load(profile: workspace.profile)

        // Set default selection to the most-covered EA
        if selectedEA == nil {
            selectedEA = snapshot.coverage.max(by: { $0.populatedDevices < $1.populatedDevices })?.eaName
        }

        loadCoverageDrift()
    }

    /// Coverage drift needs a directory scan across dated `ea-results` snapshots —
    /// runs off-main so a large fleet's history never blocks the UI.
    private func loadCoverageDrift() {
        guard !workspace.demoMode else {
            coverageDrift = []
            return
        }
        let profile = workspace.profile
        coverageDrift = []
        Task {
            typealias Drift = [EAParseHealthService.CoverageDrift]
            let drift = await Task.detached(priority: .utility) { () -> Drift in
                guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return [] }
                return EAParseHealthService.coverageDrift(dataDir: dir)
            }.value
            guard workspace.profile == profile else { return }
            coverageDrift = drift
        }
    }

    private static let demoSnapshot = ExtensionAttributeService.Snapshot(
        definitions: [
            ExtensionAttribute(
                id: "1", name: "FileVault Status", dataType: "STRING",
                description: "Reports FileVault encryption status",
                inputType: "SCRIPT", enabled: true
            ),
            ExtensionAttribute(
                id: "2", name: "mSCP Version", dataType: "STRING",
                description: "Installed mSCP compliance baseline version",
                inputType: "SCRIPT", enabled: true
            ),
            ExtensionAttribute(
                id: "3", name: "Last Patched", dataType: "DATE",
                description: "Date of last software update",
                inputType: "SCRIPT", enabled: true
            ),
            ExtensionAttribute(
                id: "4", name: "Disk Usage", dataType: "INTEGER",
                description: "Disk usage percentage",
                inputType: "SCRIPT", enabled: true
            ),
            ExtensionAttribute(
                id: "5", name: "CrowdStrike Status", dataType: "STRING",
                description: "CrowdStrike agent status",
                inputType: "SCRIPT", enabled: false
            ),
            ExtensionAttribute(
                id: "6", name: "Legacy Test EA", dataType: "BOOLEAN",
                description: "Deprecated test attribute",
                inputType: "TEXT", enabled: false
            ),
            ExtensionAttribute(
                id: "7", name: "Office Version", dataType: "STRING",
                description: "Microsoft Office version",
                inputType: "SCRIPT", enabled: true
            ),
            ExtensionAttribute(
                id: "8", name: "VPN Connection", dataType: "BOOLEAN",
                description: "VPN connectivity status",
                inputType: "SCRIPT", enabled: true
            )
        ],
        coverage: [
            .init(eaName: "Legacy Test EA", definitionId: "6", populatedDevices: 0, totalDevices: 655),
            .init(eaName: "CrowdStrike Status", definitionId: "5", populatedDevices: 320, totalDevices: 655),
            .init(eaName: "VPN Connection", definitionId: "8", populatedDevices: 459, totalDevices: 655),
            .init(eaName: "Last Patched", definitionId: "3", populatedDevices: 459, totalDevices: 655),
            .init(eaName: "Office Version", definitionId: "7", populatedDevices: 590, totalDevices: 655),
            .init(eaName: "Disk Usage", definitionId: "4", populatedDevices: 622, totalDevices: 655),
            .init(eaName: "mSCP Version", definitionId: "2", populatedDevices: 622, totalDevices: 655),
            .init(eaName: "FileVault Status", definitionId: "1", populatedDevices: 655, totalDevices: 655)
        ],
        totalDevices: 655,
        totalEAs: 8,
        totalRowCount: 5_240,
        valueDistributions: [
            .init(
                eaName: "FileVault Status",
                top: [
                    .init(value: "encrypted", count: 647),
                    .init(value: "not encrypted", count: 8)
                ],
                otherCount: 0,
                distinctValueCount: 2
            ),
            .init(
                eaName: "mSCP Version",
                top: [
                    .init(value: "v1.0.3", count: 380),
                    .init(value: "v1.0.2", count: 180),
                    .init(value: "v1.0.1", count: 62)
                ],
                otherCount: 0,
                distinctValueCount: 3
            )
        ],
        sourceFile: nil,
        snapshotDate: Date()
    )

    // MARK: - Computed values

    private var sortedCoverage: [ExtensionAttributeService.Snapshot.Coverage] {
        switch sortOrder {
        case .devices:
            return snapshot.coverage.sorted { $0.populatedDevices > $1.populatedDevices }
        case .name:
            return snapshot.coverage.sorted { $0.eaName < $1.eaName }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "slider.horizontal.below.rectangle",
                title: "No Extension Attribute data yet",
                message: "Collect data for this screen — use the Collect now banner when shown, or run `jamf-cli pro report ea-results --all` — and it will populate."
            )
        }
    }

    private var kpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Total EAs",
                value: "\(snapshot.totalEAs)",
                sub: "Across definitions and results"
            )
            StatTile(
                label: "Total Devices",
                value: "\(snapshot.totalDevices)",
                sub: "With EA result data"
            )
        }
    }

    private var significantDrops: [EAParseHealthService.CoverageDrift] {
        coverageDrift.filter { $0.deltaPP <= Self.driftAlertThresholdPP }
    }

    /// Sharp coverage drops since the previous collect — renders nothing when
    /// there's nothing worth flagging (no empty-state card).
    @ViewBuilder
    private var driftCard: some View {
        let drops = significantDrops
        if !drops.isEmpty {
            let shown = Array(drops.prefix(Self.driftDisplayCap))
            let remaining = drops.count - shown.count

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.right.circle.fill")
                            .foregroundStyle(Theme.Colors.warn)
                            .accessibilityHidden(true)
                        SectionHeader(title: "Coverage Drift")
                        Spacer()
                    }
                    Text("Fleet coverage dropped sharply for these Extension Attributes since "
                        + "the previous collect. Check the source (script, EA config, or agent "
                        + "rollout) if this is unexpected.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown, id: \.eaName) { drift in
                            driftRow(drift)
                        }
                        if remaining > 0 {
                            Text("+\(remaining) more")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.Colors.warn.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.Colors.warn.opacity(0.35), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private func driftRow(_ drift: EAParseHealthService.CoverageDrift) -> some View {
        HStack(spacing: 6) {
            Text(drift.eaName)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.fg)
            Text("—")
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Text("\(Int(drift.previousPct.rounded()))% → \(Int(drift.currentPct.rounded()))%")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Text("(\(Int(drift.deltaPP.rounded()))pp)")
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(Theme.Colors.warn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(drift.eaName) coverage dropped from \(Int(drift.previousPct.rounded())) "
            + "percent to \(Int(drift.currentPct.rounded())) percent"
        )
    }

    // EAs carry custom, often legitimately sparse data — a serial-number EA
    // populating 11 devices means 11 Macs run that app, not a broken EA. So
    // this list shows neutral devices-reporting counts, never a coverage %.
    private var coverageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Extension Attributes")
                    Spacer()
                    SegmentedControl(
                        selection: $sortOrder,
                        options: SortOrder.allCases.map { ($0, $0.rawValue, nil) }
                    )
                }

                VStack(spacing: 8) {
                    ForEach(Array(sortedCoverage.prefix(30)), id: \.id) { coverage in
                        coverageRow(for: coverage)
                            .onTapGesture {
                                selectedEA = coverage.eaName
                            }
                    }

                    if snapshot.coverage.count > 30 {
                        Text("+\(snapshot.coverage.count - 30) more")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func coverageRow(for coverage: ExtensionAttributeService.Snapshot.Coverage) -> some View {
        let isSelected = selectedEA == coverage.eaName
        HStack {
            Text(coverage.eaName)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.Colors.fg : Theme.Colors.fg2)
            Spacer()
            Text("\(coverage.populatedDevices) device\(coverage.populatedDevices == 1 ? "" : "s")")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            isSelected ? Theme.Colors.hairline : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(coverage.eaName) extension attribute, \(coverage.populatedDevices) devices reporting a value")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "View distribution") {
            selectedEA = coverage.eaName
        }
        .focusable()
    }

    @ViewBuilder
    private func valueDistributionCard(for eaName: String) -> some View {
        if let distribution = snapshot.valueDistributions.first(where: { $0.eaName == eaName }) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionHeader(title: "Value Distribution", trailingValue: eaName)
                        PNPButton(
                            title: "Export PNG",
                            icon: "square.and.arrow.down",
                            style: .neutral,
                            size: .sm
                        ) {
                            exportDistributionPNG(distribution)
                        }
                        .accessibilityLabel("Export \(eaName) value distribution chart as PNG")
                        .help("Save the \(eaName) value distribution as a PNG image")
                    }

                    Chart(distribution.top.indices, id: \.self) { index in
                        let item = distribution.top[index]
                        BarMark(
                            x: .value("Count", item.count),
                            y: .value("Value", item.value)
                        )
                        .foregroundStyle(Theme.Colors.gold)
                        .cornerRadius(3)
                        .accessibilityLabel(item.value)
                        .accessibilityValue("\(item.count) devices")
                    }
                    .frame(height: min(220, max(120, CGFloat(distribution.top.count * 24))))
                    .accessibilityLabel("Value distribution for \(eaName) extension attribute")
                    .accessibilityChartDescriptor(
                        BarDistributionChartDescriptor(
                            title: "Value distribution for \(eaName) extension attribute",
                            unit: " devices",
                            bars: distribution.top.map { item in
                                BarDistributionChartDescriptor.Bar(
                                    label: item.value,
                                    value: Double(item.count)
                                )
                            }
                        )
                    )
                    .chartXAxis {
                        AxisMarks(position: .bottom) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                        }
                    }

                    distributionFootnote(for: distribution)
                }
            }
        }
    }

    @ViewBuilder
    private func distributionFootnote(
        for distribution: ExtensionAttributeService.Snapshot.ValueDistribution
    ) -> some View {
        if distribution.otherCount > 0 || snapshot.totalRowCount > Self.largeFleetRowThreshold {
            VStack(alignment: .leading, spacing: 2) {
                if distribution.otherCount > 0 {
                    Text("+\(distribution.otherCount) value\(distribution.otherCount == 1 ? "" : "s") in \(distribution.distinctValueCount - distribution.top.count) other bucket\(distribution.distinctValueCount - distribution.top.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                if snapshot.totalRowCount > Self.largeFleetRowThreshold {
                    Text("Top values shown per EA; generated reports include all values.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var definitionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "EA Definitions",
                    trailing: snapshot.definitions.count > Self.definitionsDisplayCap
                        ? "\(Self.definitionsDisplayCap) of \(snapshot.definitions.count) shown"
                        : nil
                )

                if snapshot.definitions.isEmpty {
                    Text("No EA definitions loaded.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    Table(Array(snapshot.definitions.prefix(Self.definitionsDisplayCap))) {
                        TableColumn("Name") { definition in
                            Text(definition.name ?? "Unknown")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.fg)
                                .accessibilityLabel("\(definition.name ?? "Unknown"), extension attribute name")
                        }
                        .width(min: 150, ideal: 200)

                        TableColumn("Type") { definition in
                            Pill(
                                text: definition.inferredEAType,
                                tone: pillTone(for: definition.inferredEAType)
                            )
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("Input") { definition in
                            Text(definition.inputType ?? "Unknown")
                                .font(.footnote)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("Enabled") { definition in
                            Text(definition.enabled == true ? "✓" : "✗")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(definition.enabled == true ? Theme.Colors.ok : Theme.Colors.fgMuted)
                                .accessibilityLabel(definition.enabled == true ? "Enabled" : "Disabled")
                        }
                        .width(min: 60, ideal: 80)
                    }
                    .frame(minHeight: 200)
                    if snapshot.definitions.count > Self.definitionsDisplayCap {
                        Text("Generated reports include every definition.")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
            }
        }
    }

    private func pillTone(for eaType: String) -> Pill.Tone {
        switch eaType {
        case "boolean":    return .teal
        case "date":       return .gold
        case "percentage": return .warn
        case "text":       return .muted
        default:           return .muted
        }
    }

    // MARK: - PNG export

    /// Routes the value-distribution chart through `DashboardChartExport.render`,
    /// which handles save panel, off-screen rendering, write, and error
    /// surfacing. `BarChartExportView` already supplies its own title/date
    /// frame, so we use `render(...)` (raw canvas) rather than `run(...)`
    /// (which adds a second title/footer layer).
    private func exportDistributionPNG(
        _ distribution: ExtensionAttributeService.Snapshot.ValueDistribution
    ) {
        let totalDevices = snapshot.totalDevices
        let totalRowCount = snapshot.totalRowCount
        let snapshotDate = snapshot.snapshotDate
        let result = DashboardChartExport.render(
            suggestedFilename: DashboardChartExport.filename(for: "ea-values-\(distribution.eaName)", profile: workspace.profile)
        ) {
            BarChartExportView(
                distribution: distribution,
                totalDevices: totalDevices,
                totalRowCount: totalRowCount,
                snapshotDate: snapshotDate
            )
        }
        if case .failure(let error) = result {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }
}

// MARK: - Chart export snapshot view

/// Fixed-size view rendered to PNG by `ImageRenderer`. Stands alone — no
/// environment dependencies — so it renders correctly off-screen. Visual
/// contract matches `TrendsView`'s ChartExportView: 848×448, light slate
/// background, serif title, monospaced stats footer.
private struct BarChartExportView: View {
    let distribution: ExtensionAttributeService.Snapshot.ValueDistribution
    let totalDevices: Int
    let totalRowCount: Int
    let snapshotDate: Date?

    private struct ExportBar: Identifiable {
        let index: Int
        let value: String
        let count: Int
        var id: Int { index }
    }

    private var bars: [ExportBar] {
        distribution.top.enumerated().map { idx, item in
            ExportBar(index: idx, value: item.value, count: item.count)
        }
    }

    private var maxCount: Int { distribution.top.map(\.count).max() ?? 0 }
    private var totalPopulated: Int { distribution.top.reduce(0) { $0 + $1.count } + distribution.otherCount }

    private var dateText: String {
        guard let snapshotDate else { return "No snapshot date" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Snapshot \(f.string(from: snapshotDate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardExportHeader(
                title: distribution.eaName,
                subtitle: dateText
            ) {
                AnyView(
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(distribution.top.count)")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.Colors.gold)
                        Text("distinct values shown")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Chart.textTertiary)
                    }
                )
            }

            Chart(bars) { bar in
                BarMark(
                    x: .value("Count", bar.count),
                    y: .value("Value", bar.value)
                )
                .foregroundStyle(Theme.Colors.gold)
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                    Text("\(bar.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Chart.textPrimary)
                }
            }
            .chartXScale(domain: 0...(Double(maxCount) * 1.18))
            .chartXAxis {
                AxisMarks(position: .bottom) { value in
                    AxisGridLine().foregroundStyle(Theme.Chart.borders)
                    AxisTick().foregroundStyle(Theme.Chart.gridLines)
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.Chart.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Chart.textPrimary)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.Chart.borders, lineWidth: 1)
                    )
            }
            .frame(height: 278)
            .accessibilityHidden(true)

            HStack(spacing: 14) {
                exportStat("Distinct values", "\(distribution.distinctValueCount)")
                exportStat("Top shown", "\(distribution.top.count)")
                exportStat("Other bucket", "\(distribution.otherCount)")
                exportStat("Populated", "\(totalPopulated)")
                exportStat("Devices", "\(totalDevices)")
                Spacer()
                Text("Source: ea-results · Rows: \(totalRowCount)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Chart.textTertiary)
            }
        }
        .padding(24)
        .frame(width: 848, height: 448)
        .background(Theme.Chart.backgroundLight)
    }

    private func exportStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Chart.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Chart.textPrimary)
        }
    }
}
