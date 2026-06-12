import SwiftUI
import AppKit

/// Patch management dashboard. Surfaces Jamf Pro patch-management status and
/// failure detail from `pro report patch-status` and `patch-status --scan-failures`
/// snapshots. Lifts the v3.5 "Patch Management Report" Excel sheet into a live,
/// on-screen dashboard.
struct PatchView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: PatchStatusService.Snapshot = .empty
    @State private var hasLoaded = false
    /// title_id → release_date from the patch-release-dates snapshot.
    /// Empty when the snapshot hasn't been collected yet — table column shows "—".
    @State private var releaseLookup: [String: String] = [:]

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Operations",
                title: "Patch Compliance",
                subtitle: subtitle,
                lastModified: snapshot.snapshotDate
            )
            // Shared StaleDataBanner surfaces snapshot freshness above the main content.
            // Suppressed in demo mode (the demo dataset is intentionally static and
            // not user-perceivably "stale"). Renders nothing when source is .fresh.
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource)
            }
            if snapshot.totalTitles == 0 {
                emptyState
            } else {
                kpiGrid
                patchTitlesCard
                if !snapshot.failures.isEmpty {
                    recentFailuresCard
                }
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
        guard snapshot.totalTitles > 0 else { return nil }
        return "\(snapshot.totalTitles) patch title\(snapshot.totalTitles == 1 ? "" : "s") tracked across the fleet."
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
            : PatchStatusService.load(profile: workspace.profile)
        if !workspace.demoMode {
            let rows = PatchReleaseDateService.load(profile: workspace.profile)
            releaseLookup = PatchReleaseDateService.releaseDateLookup(from: rows)
        }
    }

    private static let demoSnapshot = PatchStatusService.Snapshot(
        titles: [
            PatchStatusRow(title: "Firefox", id: "123", onLatest: 280, onOther: 45, total: 325, latest: "132.0.2", compliancePct: "86%"),
            PatchStatusRow(title: "Google Chrome", id: "124", onLatest: 420, onOther: 35, total: 455, latest: "131.0.6778.108", compliancePct: "92%"),
            PatchStatusRow(title: "Microsoft Office 365", id: "125", onLatest: 150, onOther: 200, total: 350, latest: "16.91", compliancePct: "43%"),
            PatchStatusRow(title: "Adobe Acrobat", id: "126", onLatest: 95, onOther: 5, total: 100, latest: "2024.004.20272", compliancePct: "95%")
        ],
        failures: [
            PatchFailureRow(policy: "Microsoft Office 365", policyId: "125", device: "MacBook-Pro-001", deviceId: "1001", statusDate: "2025-01-08", attempt: 3, lastAction: "Retrying", serial: "C02Z12345678", osVersion: "15.4.1", username: "jdoe"),
            PatchFailureRow(policy: "Firefox", policyId: "123", device: "iMac-Lab-042", deviceId: "1042", statusDate: "2025-01-07", attempt: 2, lastAction: "Failed", serial: "C02Y87654321", osVersion: "14.7.5", username: ""),
            PatchFailureRow(policy: "Microsoft Office 365", policyId: "125", device: "MacBook-Air-199", deviceId: "1199", statusDate: "2025-01-06", attempt: 1, lastAction: "Download Failed", serial: "C02X11223344", osVersion: "15.4.1", username: "asmith")
        ],
        sourceFile: nil,
        snapshotDate: Date()
    )

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "shippingbox",
                title: "No patch data yet",
                message: "Collect data for this screen — use the Collect now banner when shown, or run `jamf-cli pro report patch-status` — and it will populate."
            )
        }
    }

    private var kpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Total Titles",
                value: "\(snapshot.totalTitles)",
                sub: "Patch policies tracked"
            )
            StatTile(
                label: "Fleet Compliance",
                value: String(format: "%.1f%%", snapshot.fleetCompliancePct),
                sub: "Weighted across all devices"
            )
            StatTile(
                label: "Compliant Titles",
                value: "\(snapshot.compliantTitleCount)",
                sub: "≥90% compliance rate"
            )
            StatTile(
                label: "Failing Titles",
                value: "\(snapshot.failingTitleCount)",
                sub: "<50% compliance rate"
            )
            StatTile(
                label: "Devices With Failures",
                value: "\(snapshot.devicesWithFailures)",
                sub: "Requiring attention"
            )
        }
    }

    /// Cap shown rows so the table stays responsive in tenants with hundreds
    /// of patch titles. SwiftUI Tables are virtualized at the row-render
    /// level but data-source construction is eager, so this cap also bounds
    /// the SwiftUI diff cost on every state change.
    private static let titlesDisplayCap = 50

    private var patchTitlesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(
                        title: "Patch Titles",
                        trailing: sortedTitles.count > Self.titlesDisplayCap
                            ? "\(Self.titlesDisplayCap) of \(sortedTitles.count) shown"
                            : nil
                    )
                    PNPButton(
                        title: "Export CSV",
                        icon: "tablecells",
                        style: .neutral,
                        size: .sm,
                        action: exportPatchComplianceCSV
                    )
                    .accessibilityLabel("Export patch compliance report as CSV")
                    .help("Save the full patch compliance report as a CSV file")
                    PNPButton(
                        title: "Export PNG",
                        icon: "square.and.arrow.down",
                        style: .neutral,
                        size: .sm,
                        action: exportPatchTitlesTable
                    )
                    .accessibilityLabel("Export patch titles table as PNG")
                    .help("Save the patch titles table as a PNG image")
                }
                Table(Array(sortedTitles.prefix(Self.titlesDisplayCap))) {
                    TableColumn("Title") { title in
                        Text(title.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                            .accessibilityLabel("\(title.title), patch title")
                    }
                    .width(min: 180, ideal: 220)

                    TableColumn("Latest Version") { title in
                        Text(title.latest)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Released") { title in
                        let dateStr = releaseLookup[title.id] ?? ""
                        Text(dateStr.isEmpty ? "—" : String(dateStr.prefix(10)))
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .accessibilityLabel(dateStr.isEmpty ? "No release date" : "Released \(dateStr)")
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Compliance") { title in
                        let pct = PatchStatusService.parseCompliancePct(title.compliancePct)
                        HStack(spacing: 3) {
                            Image(systemName: complianceIcon(for: pct))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(complianceColor(for: pct))
                            Text(title.compliancePct)
                                .font(Theme.Fonts.mono(11, weight: .semibold))
                                .foregroundStyle(complianceColor(for: pct))
                                .monospacedDigit()
                        }
                        .accessibilityLabel("\(title.compliancePct) compliance rate")
                    }
                    .width(min: 80, ideal: 90)

                    TableColumn("On Latest / Total") { title in
                        Text("\(title.onLatest) / \(title.total)")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .monospacedDigit()
                            .accessibilityLabel("\(title.onLatest) devices on latest version, \(title.total) total devices")
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Failures") { title in
                        let failureCount = snapshot.failuresByTitle[title.title] ?? 0
                        Text("\(failureCount)")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(failureCount > 0 ? Theme.Colors.warn : Theme.Text.tertiary(contrast))
                            .monospacedDigit()
                            .accessibilityLabel("\(failureCount) device\(failureCount == 1 ? "" : "s") with patch failures")
                    }
                    .width(min: 80, ideal: 90)
                }
                .frame(minHeight: 200)
                if sortedTitles.count > Self.titlesDisplayCap {
                    Text("Generated reports include every patch title.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var sortedTitles: [PatchStatusRow] {
        snapshot.titles.sorted { lhs, rhs in
            let lhsPct = PatchStatusService.parseCompliancePct(lhs.compliancePct)
            let rhsPct = PatchStatusService.parseCompliancePct(rhs.compliancePct)
            return lhsPct < rhsPct
        }
    }

    private func complianceColor(for pct: Double) -> Color {
        switch pct {
        case ..<50:  return Theme.Colors.danger
        case ..<80:  return Theme.Colors.warn
        case 90...:  return Theme.Colors.ok
        default:     return Theme.Colors.fgMuted  // gray for 80-89
        }
    }

    private func complianceIcon(for pct: Double) -> String {
        switch pct {
        case ..<80:  return "exclamationmark.triangle"
        case ..<90:  return "exclamationmark.circle"
        default:     return "checkmark.circle"
        }
    }

    @ViewBuilder
    private var recentFailuresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recent Failures")
                if snapshot.failures.isEmpty {
                    Text("No recent patch failures recorded.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    Table(recentFailures) {
                        TableColumn("Device") { failure in
                            Text(failure.device)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.fg)
                                .accessibilityLabel("\(failure.device), device name")
                        }
                        .width(min: 150, ideal: 180)

                        TableColumn("Policy") { failure in
                            Text(failure.policy)
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.fg2)
                        }
                        .width(min: 120, ideal: 160)

                        TableColumn("Last Action") { failure in
                            Text(failure.lastAction)
                                .font(Theme.Fonts.mono(11))
                                .foregroundStyle(actionColor(for: failure.lastAction))
                                .accessibilityLabel("Last action \(failure.lastAction)")
                        }
                        .width(min: 100, ideal: 120)

                        TableColumn("Status Date") { failure in
                            Text(failure.statusDate)
                                .font(Theme.Fonts.mono(10.5))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        .width(min: 90, ideal: 110)
                    }
                    .frame(minHeight: 150)
                }
            }
        }
    }

    private var recentFailures: [PatchFailureRow] {
        // Show up to 20 most recent failures (newest status date first)
        snapshot.failures
            .sorted { $0.statusDate > $1.statusDate }
            .prefix(20)
            .map { $0 }
    }

    private func actionColor(for action: String) -> Color {
        let lowercased = action.lowercased()
        switch true {
        case lowercased.contains("fail"):
            return Theme.Colors.danger
        case lowercased.contains("retry"):
            return Theme.Colors.warn
        case lowercased.contains("success"):
            return Theme.Colors.ok
        default:
            return Theme.Colors.fgMuted
        }
    }

    private func exportPatchTitlesTable() {
        DashboardChartExport.run(
            title: "Patch Titles",
            subtitle: "Fleet patch compliance summary",
            suggestedFilename: DashboardChartExport.filename(for: "patch-titles-table", profile: workspace.profile)
        ) {
            PatchTitlesTableExport(titles: Array(sortedTitles.prefix(Self.titlesDisplayCap)))
        }
    }

    /// Export the full patch compliance report as a standalone CSV — the same
    /// column shape as the workbook's "Patch Compliance" sheet. Unlike the PNG
    /// export (capped and sorted for on-screen readability), this writes every
    /// tracked title in collected order.
    private func exportPatchComplianceCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = ExportNaming.filename(
            kind: "patch-compliance", profile: workspace.profile, ext: "csv"
        )
        panel.title = "Export Patch Compliance CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PatchStatusService.complianceCSV(snapshot.titles)
                .write(to: url, atomically: true, encoding: .utf8)
            workspace.toast = Toast(
                message: "Exported \(snapshot.totalTitles) patch titles to \(url.lastPathComponent)",
                style: .success
            )
        } catch {
            workspace.toast = Toast(
                message: "Could not export CSV: \(error.localizedDescription)",
                style: .danger
            )
        }
    }
}

// MARK: - Patch Titles Table Export View

struct PatchTitlesTableExport: View {
    let titles: [PatchStatusRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Patch Titles")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.black)

            VStack(alignment: .leading, spacing: 2) {
                // Header row
                HStack(spacing: 12) {
                    Text("Title")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 200, alignment: .leading)
                    Text("Latest Version")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 120, alignment: .leading)
                    Text("On Latest")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 80, alignment: .trailing)
                    Text("On Other")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 80, alignment: .trailing)
                    Text("Total")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 80, alignment: .trailing)
                    Text("Compliance %")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 100, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.gray.opacity(0.1))

                // Data rows
                ForEach(Array(titles.enumerated()), id: \.element.id) { index, title in
                    HStack(spacing: 12) {
                        Text(title.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.black)
                            .frame(width: 200, alignment: .leading)
                        Text(title.latest)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(width: 120, alignment: .leading)
                        Text("\(title.onLatest)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(width: 80, alignment: .trailing)
                        Text("\(title.onOther)")
                            .font(.system(size: 11))
                            .foregroundStyle(.black)
                            .frame(width: 80, alignment: .trailing)
                        Text("\(title.total)")
                            .font(.system(size: 11))
                            .foregroundStyle(.black)
                            .frame(width: 80, alignment: .trailing)
                        Text(title.compliancePct)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(width: 100, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    if index < titles.count - 1 {
                        Divider()
                            .background(.gray.opacity(0.3))
                    }
                }
            }
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(24)
        .frame(width: 848, height: 448)
        .background(.white)
        .colorScheme(.light)
    }
}