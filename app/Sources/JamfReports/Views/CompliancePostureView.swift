import SwiftUI
import Charts

/// Compliance posture screen. Buckets devices into the v3.5 STIG band shape
/// (Pass / Low / Med-Low / Medium / High / No Data) using control-gap counts
/// derived from `pro security report`. Designed to grow into the full mSCP
/// failure-count banding once an Extension Attribute is configured.
struct CompliancePostureView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot: CompliancePostureService.Snapshot = .empty
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    kicker: "Posture",
                    title: "Compliance Posture",
                    subtitle: subtitle,
                    lastModified: snapshot.snapshotDate
                )
                proxyNoteCard
                if snapshot.totalDevices == 0 {
                    emptyState
                } else {
                    bandsHeroCard
                    controlCoverageCard
                    perOSBreakdownCard
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
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    private var subtitle: String? {
        guard snapshot.totalDevices > 0 else { return nil }
        return "\(snapshot.totalDevices) device\(snapshot.totalDevices == 1 ? "" : "s") evaluated by control-gap proxy."
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fgMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Banded by control-gap count")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text("Each device is bucketed by how many of FileVault, SIP, Firewall, and Gatekeeper are failing. For full mSCP failure-count banding, configure a Compliance EA in your Jamf Pro tenant.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
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
            suggestedFilename: DashboardChartExport.filename(for: "compliance-bands")
        ) {
            CompliancePostureBandsDonutExport(bands: bands)
        }
        if case .failure(let error) = result {
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
    }

    private var bandsLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.bands) { band in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: band.colorHex))
                        .frame(width: 12, height: 12)
                    Text(band.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Text("(\(band.range))")
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                    Spacer()
                    Text("\(band.count)")
                        .font(Theme.Fonts.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg2)
                        .monospacedDigit()
                    Text(String(format: "%.1f%%", band.pct))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .frame(width: 56, alignment: .trailing)
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
                Text(gap.control)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Text("\(gap.failingDevices) failing")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
                Text(String(format: "%.1f%%", gap.pct))
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(barColor(for: gap.pct))
                    .frame(width: 56, alignment: .trailing)
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
        case ..<1:  return Color(hex: 0x30D158)  // ok
        case ..<5:  return Color(hex: 0xE8B614)  // gold
        case ..<15: return Color(hex: 0xFF9F0A)  // warn
        default:    return Color(hex: 0xFF453A)  // danger
        }
    }

    private var perOSBreakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Per-OS Breakdown")
                if snapshot.perOSMajor.isEmpty {
                    Text("Not enough OS version data in this snapshot.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.fgMuted)
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
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                        .frame(width: 150, alignment: .leading)
                    perOSStack(row.bands)
                        .frame(height: 14)
                    Text("\(row.bands.reduce(0) { $0 + $1.count })")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .frame(width: 50, alignment: .trailing)
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
