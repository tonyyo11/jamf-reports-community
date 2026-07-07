import SwiftUI
import Charts

/// Compliance posture screen. Buckets devices into the v3.5 STIG band shape
/// (Pass / Low / Med-Low / Medium / High / No Data) using control-gap counts
/// derived from `pro security report`. Designed to grow into the full mSCP
/// failure-count banding once an Extension Attribute is configured.
struct CompliancePostureView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: CompliancePostureService.Snapshot = .empty
    @State private var mscpResults: [MSCPComplianceService.BaselineResult] = []
    @State private var hasLoaded = false

    /// Compliance-category templates from jamf-cli `pro sg` (PR #205, target release TBD).
    /// Loaded once per profile; empty when feature-detect fails.
    @State private var complianceTemplates: [SmartGroupTemplate] = []
    @State private var selectedTemplate: SmartGroupTemplate?
    @State private var bridge = CLIBridge()

    /// Order matches the on-screen controlCoverageCard column flow plus
    /// `non-compliant-baseline` at the bottom (most-actionable individual
    /// controls first, then the broader baseline rollup).
    private static let templateOrder: [String] = [
        "compliance/gatekeeper-disabled",
        "compliance/sip-disabled",
        "compliance/firewall-disabled",
        "compliance/non-compliant-baseline",
    ]

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Posture",
                title: "Compliance Posture",
                subtitle: subtitle,
                lastModified: snapshot.snapshotDate
            )

            // Shared StaleDataBanner surfaces snapshot freshness above the main content.
            // Suppressed in demo mode (the demo dataset is intentionally static and
            // not user-perceivably "stale"). Renders nothing when source is .fresh.
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
            }

            // Show proxy note only when using proxy compliance (no mSCP baselines)
            if mscpResults.isEmpty {
                proxyNoteCard
            }

            if let reason = snapshot.loadError {
                Card(padding: 24) {
                    ErrorStateView(
                        title: "Couldn't read compliance data",
                        message: reason,
                        commands: ["Re-run collection from Data Sources, then Refresh."],
                        retry: { reload() }
                    )
                }
            } else if snapshot.totalDevices == 0 && mscpResults.isEmpty {
                emptyState
            } else {
                // Show mSCP baseline donuts when available, otherwise proxy bands
                if !mscpResults.isEmpty {
                    mscpBaselineDonuts
                } else {
                    bandsHeroCard
                }
                controlCoverageCard
                if !complianceTemplates.isEmpty {
                    complianceSmartGroupBar
                }
                perOSBreakdownCard
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .task(id: workspace.profile) { await loadComplianceTemplates() }
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

    /// Sits between the control-coverage card and the per-OS breakdown so the
    /// operator can scan "which control is failing" → "create a smart group
    /// for that control" without leaving the page. Same menu-picker shape as
    /// SecurityPostureView for visual consistency across the posture dashboards.
    private var complianceSmartGroupBar: some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(Theme.Colors.gold)
                Text("Compliance remediation")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Menu("Create smart group") {
                    ForEach(complianceTemplates) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            Text(Self.menuLabel(for: template))
                        }
                    }
                }
                .help("Open a template-driven sheet to create a smart group for a compliance gap")
            }
        }
    }

    private static func menuLabel(for template: SmartGroupTemplate) -> String {
        switch template.slug {
        case "compliance/gatekeeper-disabled":     return "Gatekeeper disabled"
        case "compliance/sip-disabled":            return "SIP disabled"
        case "compliance/firewall-disabled":       return "Firewall disabled"
        case "compliance/non-compliant-baseline":  return "Not meeting baseline"
        default:                        return template.description.isEmpty ? template.slug : template.description
        }
    }

    private func loadComplianceTemplates() async {
        let service = SmartGroupTemplateService(executor: DefaultCLIExecutor(bridge: bridge))
        do {
            let all = try await service.listTemplates(profile: workspace.profile)
            let bySlug = Dictionary(uniqueKeysWithValues: all.map { ($0.slug, $0) })
            complianceTemplates = Self.templateOrder.compactMap { bySlug[$0] }
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            complianceTemplates = []
        } catch {
            AppLogger.cli.error(
                "CompliancePostureView smart-group templates load failed: \(String(describing: error), privacy: .private)"
            )
            complianceTemplates = []
        }
    }

    private var subtitle: String? {
        if !mscpResults.isEmpty {
            let devicesWithData = mscpResults.first?.devicesWithData ?? 0
            let baselinesText = mscpResults.count == 1 ? "baseline" : "baselines"
            if devicesWithData > 0 {
                return "\(devicesWithData) device\(devicesWithData == 1 ? "" : "s") evaluated across "
                    + "\(mscpResults.count) mSCP \(baselinesText)."
            } else {
                return "No device data matched the configured baseline EA column."
            }
        } else if snapshot.totalDevices > 0 {
            return "\(snapshot.totalDevices) device\(snapshot.totalDevices == 1 ? "" : "s") evaluated by control-gap proxy."
        } else {
            return nil
        }
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
            : CompliancePostureService.load(profile: workspace.profile)

        // Load real mSCP baseline results when not in demo mode
        if workspace.demoMode {
            mscpResults = Self.demoMSCPResults
        } else {
            // Load config to get resolved baselines
            if let config = readConfig(),
               let compliance = config.compliance,
               !compliance.resolvedBaselines.isEmpty {
                mscpResults = MSCPComplianceService.load(
                    profile: workspace.profile,
                    baselines: compliance.resolvedBaselines
                )
            } else {
                mscpResults = []
            }
        }
    }

    private func readConfig() -> ReportConfig? {
        guard let workspaceURL = ProfileService.workspaceURL(for: workspace.profile) else { return nil }
        let configURL = workspaceURL.appendingPathComponent("config.yaml")
        return try? ConfigLoader.load(from: configURL)
    }

    private static var demoMSCPResults: [MSCPComplianceService.BaselineResult] {
        // Demo baselines with different band distributions
        let stigBands = ComplianceBandingService.bands(failures:
            Array(repeating: 0, count: 380) +   // Pass
            Array(repeating: 5, count: 120) +   // Low
            Array(repeating: 15, count: 80) +   // Med-Low
            Array(repeating: 35, count: 40) +   // Medium
            Array(repeating: 60, count: 35)     // High
        )
        let nistBands = ComplianceBandingService.bands(failures:
            Array(repeating: 0, count: 400) +   // Pass
            Array(repeating: 3, count: 100) +   // Low
            Array(repeating: 20, count: 90) +   // Med-Low
            Array(repeating: 40, count: 50) +   // Medium
            Array(repeating: 55, count: 15)     // High
        )

        return [
            MSCPComplianceService.BaselineResult(
                name: "DISA STIG",
                failuresCountColumn: "STIG Failures Count",
                bands: stigBands,
                noDataCount: 0,
                totalDevices: 655,
                compliancePct: 58.0
            ),
            MSCPComplianceService.BaselineResult(
                name: "NIST 800-53r5",
                failuresCountColumn: "NIST Failures Count",
                bands: nistBands,
                noDataCount: 0,
                totalDevices: 655,
                compliancePct: 61.1
            )
        ]
    }

    private static var demoSnapshot: CompliancePostureService.Snapshot {
        let failures: [Int?] =
            Array(repeating: 0, count: 420) +
            Array(repeating: 1, count: 130) +
            Array(repeating: 2, count: 60) +
            Array(repeating: 3, count: 30) +
            Array(repeating: 4, count: 15)
        let bands = ComplianceBandingService.bands(failures: failures)
        let osPairs: [(osMajor: Int, failures: Int?)] = (0..<420).map { _ in (15, 0) }
            + (0..<130).map { _ in (15, 1) }
            + (0..<60).map { _ in (14, 2) }
            + (0..<45).map { _ in (13, 3) }
        let perOS = ComplianceBandingService.bandsByOSMajor(osPairs)
        let total = failures.count
        let controlGaps = [
            CompliancePostureService.Snapshot.ControlGap(control: "Gatekeeper", failingDevices: 90, totalDevices: total),
            CompliancePostureService.Snapshot.ControlGap(control: "Firewall", failingDevices: 80, totalDevices: total),
            CompliancePostureService.Snapshot.ControlGap(control: "FileVault", failingDevices: 25, totalDevices: total),
            CompliancePostureService.Snapshot.ControlGap(control: "SIP", failingDevices: 5, totalDevices: total)
        ]
        return CompliancePostureService.Snapshot(
            totalDevices: total,
            bands: bands,
            perOSMajor: perOS,
            controlGaps: controlGaps,
            sourceFile: nil,
            snapshotDate: Date()
        )
    }

    // MARK: - Sections

    private var proxyNoteCard: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fgMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Banded by control-gap count")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text("Each device is bucketed by how many of FileVault, SIP, Firewall, and Gatekeeper are failing. For full mSCP failure-count banding, configure a Compliance EA in your Jamf Pro tenant.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                title: "No compliance snapshot yet",
                message: "Run `jamf-cli pro report security` to populate this screen."
            )
        }
    }

    private var bandsHeroCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Compliance Bands", trailing: "Fleet-wide")
                    PNPButton(
                        title: "Export PNG",
                        icon: "square.and.arrow.down",
                        style: .neutral,
                        size: .sm,
                        action: exportBandsDonut
                    )
                    .accessibilityLabel("Export compliance bands donut as PNG")
                    .help("Save the fleet-wide compliance bands donut as a PNG image")
                }
                HStack(alignment: .top, spacing: 28) {
                    bandsDonut
                        .frame(width: 220, height: 220)
                    bandsLegend
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func exportBandsDonut() {
        let bands = snapshot.bands
        let total = snapshot.totalDevices
        let result = DashboardChartExport.run(
            title: "Compliance Bands",
            subtitle: "Compliance Posture",
            footnote: "Source: pro report security · \(total) devices banded by control-gap count",
            suggestedFilename: DashboardChartExport.filename(for: "compliance-bands", profile: workspace.profile)
        ) {
            CompliancePostureBandsDonutExport(bands: bands)
        }
        if case .failure(let error) = result {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    private var mscpBaselineDonuts: some View {
        ForEach(Array(mscpResults.enumerated()), id: \.offset) { index, result in
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionHeader(
                            title: "mSCP Compliance",
                            trailing: result.name
                        )
                        PNPButton(
                            title: "Export PNG",
                            icon: "square.and.arrow.down",
                            style: .neutral,
                            size: .sm,
                            action: { exportMSCPDonut(result: result) }
                        )
                        .accessibilityLabel("Export \(result.name) compliance donut as PNG")
                        .help("Save the \(result.name) compliance donut as a PNG image")
                    }
                    HStack(alignment: .top, spacing: 28) {
                        mscpDonutChart(for: result)
                            .frame(width: 220, height: 220)
                        mscpLegend(for: result)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Compliance percentage and rule count if available
                    HStack {
                        if let pct = result.compliancePct {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Compliance Rate")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                                Text(String(format: "%.1f%%", pct))
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.fg)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Devices Evaluated")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                            Text("\(result.devicesWithData)")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                        }
                    }
                    // Diagnostic: shown only when every device is No Data, which
                    // means the configured EA column name matched no rows — likely
                    // a config typo.
                    if result.devicesWithData == 0 && result.totalDevices > 0 {
                        noMatchDiagnostic(result: result)
                    }
                }
            }
        }
    }

    /// Caption displayed when matched device count is zero — signals a likely
    /// `failures_count_column` config typo without cluttering the normal view.
    @ViewBuilder
    private func noMatchDiagnostic(result: MSCPComplianceService.BaselineResult) -> some View {
        let msg = "0 of \(result.totalDevices) device\(result.totalDevices == 1 ? "" : "s") matched"
            + " EA column \"\(result.failuresCountColumn)\" — verify the column name"
            + " matches your Jamf EA."
        Text(msg)
            .font(.caption)
            .foregroundStyle(Theme.Colors.warn)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(msg)
    }

    @ViewBuilder
    private func mscpDonutChart(for result: MSCPComplianceService.BaselineResult) -> some View {
        let slices = MSCPChartDataBuilder.toDonutSlices(result: result)
        Chart(slices.filter { $0.count > 0 }) { slice in
            SectorMark(
                angle: .value("Count", slice.count),
                innerRadius: .ratio(0.62),
                angularInset: 1.6
            )
            .foregroundStyle(Color(cgColor: slice.color))
            .accessibilityLabel(slice.label)
            .accessibilityValue("\(slice.count) devices, \(Int(slice.pct.rounded()))%")
        }
        .chartLegend(.hidden)
        .accessibilityLabel("\(result.name) compliance bands")
        .accessibilityChartDescriptor(
            SectorChartDescriptor(
                title: "\(result.name) Compliance Bands",
                unit: " devices",
                slices: slices.filter { $0.count > 0 }.map { slice in
                    SectorChartDescriptor.Slice(
                        label: slice.label,
                        value: Double(slice.count)
                    )
                }
            )
        )
    }

    @ViewBuilder
    private func mscpLegend(for result: MSCPComplianceService.BaselineResult) -> some View {
        let slices = MSCPChartDataBuilder.toDonutSlices(result: result)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(slices, id: \.label) { slice in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(cgColor: slice.color))
                        .frame(width: 12, height: 12)
                    Text(slice.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    Text("\(slice.count)")
                        .font(Theme.Fonts.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg2)
                        .monospacedDigit()
                    Text(String(format: "%.1f%%", slice.pct))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(minWidth: 56, alignment: .trailing)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(slice.label), \(slice.count) devices, \(Int(slice.pct.rounded())) percent")
            }
        }
    }

    private func exportMSCPDonut(result: MSCPComplianceService.BaselineResult) {
        let slices = MSCPChartDataBuilder.toDonutSlices(result: result)
        let filename = DashboardChartExport.filename(for: "\(result.name.lowercased().replacingOccurrences(of: " ", with: "-"))-compliance-bands", profile: workspace.profile)
        let exportResult = DashboardChartExport.run(
            title: "\(result.name) Compliance Bands",
            subtitle: "Compliance Posture",
            footnote: "Source: mSCP Extension Attribute · \(result.devicesWithData) devices evaluated",
            suggestedFilename: filename
        ) {
            MSCPComplianceBandsDonutExport(
                result: result,
                slices: slices
            )
        }
        if case .failure(let error) = exportResult {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    private var bandsDonut: some View {
        Chart(snapshot.bands.filter { $0.count > 0 }) { band in
            SectorMark(
                angle: .value("Count", band.count),
                innerRadius: .ratio(0.62),
                angularInset: 1.6
            )
            .foregroundStyle(Color(hex: band.colorHex))
            .accessibilityLabel(band.label)
            .accessibilityValue("\(band.count) devices, \(Int(band.pct.rounded()))%")
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Fleet compliance bands")
        .accessibilityChartDescriptor(
            SectorChartDescriptor(
                title: "Fleet Compliance Bands",
                unit: " devices",
                slices: snapshot.bands.filter { $0.count > 0 }.map { band in
                    SectorChartDescriptor.Slice(
                        label: band.label,
                        value: Double(band.count)
                    )
                }
            )
        )
    }

    private var bandsLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.bands) { band in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: band.colorHex))
                        .frame(width: 12, height: 12)
                    Text(band.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Text("(\(band.range))")
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                    Spacer()
                    Text("\(band.count)")
                        .font(Theme.Fonts.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg2)
                        .monospacedDigit()
                    Text(String(format: "%.1f%%", band.pct))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(minWidth: 56, alignment: .trailing)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(band.label), \(band.count) devices, \(Int(band.pct.rounded())) percent")
            }
        }
    }

    private var controlCoverageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Control Coverage Gaps")
                ForEach(snapshot.controlGaps) { gap in
                    controlBar(for: gap)
                }
            }
        }
    }

    @ViewBuilder
    private func controlBar(for gap: CompliancePostureService.Snapshot.ControlGap) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    let icon = controlIcon(for: gap.pct)
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(barColor(for: gap.pct))
                    Text(gap.control)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                }
                Spacer()
                Text("\(gap.failingDevices) failing")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(String(format: "%.1f%%", gap.pct))
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(barColor(for: gap.pct))
                    .frame(minWidth: 56, alignment: .trailing)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(for: gap.pct))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * gap.pct / 100)))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gap.control) control coverage, \(String(format: "%.1f", gap.pct)) percent failing, \(gap.failingDevices) of \(gap.totalDevices) devices")
    }

    private func barColor(for pct: Double) -> Color {
        switch pct {
        case ..<1:  return Theme.Colors.ok
        case ..<5:  return Theme.Colors.goldBright
        case ..<15: return Theme.Colors.warn
        default:    return Theme.Colors.danger
        }
    }

    private func controlIcon(for pct: Double) -> String {
        switch pct {
        case ..<1:  return "checkmark.circle.fill"
        case ..<5:  return Theme.Severity.medium.systemImage
        case ..<15: return Theme.Severity.high.systemImage
        default:    return Theme.Severity.critical.systemImage
        }
    }

    private var perOSBreakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Per-OS Breakdown")
                if snapshot.perOSMajor.isEmpty {
                    Text("Not enough OS version data in this snapshot.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    perOSGrid
                }
            }
        }
    }

    private var perOSGrid: some View {
        VStack(spacing: 8) {
            ForEach(snapshot.perOSMajor, id: \.osMajor) { row in
                HStack(alignment: .center, spacing: 12) {
                    Text(osLabel(row.osMajor))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .frame(width: 150, alignment: .leading)
                    perOSStack(row.bands)
                        .frame(height: 14)
                    Text("\(row.bands.reduce(0) { $0 + $1.count })")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(minWidth: 50, alignment: .trailing)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(perOSAccessibilityLabel(for: row))
            }
        }
    }

    private func perOSStack(_ bands: [ComplianceBand]) -> some View {
        let total = max(bands.reduce(0) { $0 + $1.count }, 1)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(bands) { band in
                    Rectangle()
                        .fill(Color(hex: band.colorHex))
                        .frame(width: geo.size.width * Double(band.count) / Double(total))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    private func osLabel(_ major: Int) -> String {
        switch major {
        case 12: return "macOS Monterey 12"
        case 13: return "macOS Ventura 13"
        case 14: return "macOS Sonoma 14"
        case 15: return "macOS Sequoia 15"
        case 26: return "macOS Tahoe 26"
        default: return "macOS \(major)"
        }
    }

    private func perOSAccessibilityLabel(for row: (osMajor: Int, bands: [ComplianceBand])) -> String {
        let osName = osLabel(row.osMajor)
        let totalDevices = row.bands.reduce(0) { $0 + $1.count }
        let majorBand = row.bands.max(by: { $0.count < $1.count })?.label ?? "Unknown"
        return "\(osName), \(totalDevices) devices, majority in \(majorBand) band"
    }
}

// MARK: - Export-only chart

/// Light-mode export rendering of the compliance bands donut. Uses the
/// `band.colorHex` values directly — they're already chosen for category
/// distinguishability on light backgrounds.
private struct CompliancePostureBandsDonutExport: View {
    let bands: [ComplianceBand]

    private var visibleBands: [ComplianceBand] { bands.filter { $0.count > 0 } }
    private var total: Int { bands.reduce(0) { $0 + $1.count } }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Chart(visibleBands) { band in
                SectorMark(
                    angle: .value("Count", band.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.6
                )
                .foregroundStyle(Color(hex: band.colorHex))
            }
            .chartLegend(.hidden)
            .frame(width: 260, height: 260)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(bands) { band in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: band.colorHex))
                            .frame(width: 10, height: 10)
                        Text(band.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(hex: 0x111827))
                        Text("(\(band.range))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x64748B))
                        Spacer(minLength: 6)
                        Text("\(band.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", band.pct))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
                if total > 0 {
                    Text("Total: \(total) devices")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x475569))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - mSCP Export Chart

/// Light-mode export rendering of an mSCP compliance bands donut.
private struct MSCPComplianceBandsDonutExport: View {
    let result: MSCPComplianceService.BaselineResult
    let slices: [ChartRenderer.DonutSlice]

    private var visibleSlices: [ChartRenderer.DonutSlice] { slices.filter { $0.count > 0 } }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Chart(visibleSlices, id: \.label) { slice in
                SectorMark(
                    angle: .value("Count", slice.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.6
                )
                .foregroundStyle(Color(cgColor: slice.color))
            }
            .chartLegend(.hidden)
            .frame(width: 260, height: 260)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(slices, id: \.label) { slice in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(cgColor: slice.color))
                            .frame(width: 10, height: 10)
                        Text(slice.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(hex: 0x111827))
                        Spacer(minLength: 6)
                        Text("\(slice.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", slice.pct))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
                if result.totalDevices > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total: \(result.totalDevices) devices")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                        if let pct = result.compliancePct {
                            Text("Compliance: \(String(format: "%.1f%%", pct))")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x475569))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
