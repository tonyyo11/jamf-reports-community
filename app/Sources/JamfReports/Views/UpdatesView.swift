import SwiftUI
import Charts

/// macOS DDM update-plan dashboard. Surfaces DDM update status, plan states,
/// and failure details from `pro report update-status` snapshots via
/// `UpdateStatusService`.
struct UpdatesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: UpdateStatusService.Snapshot = .empty
    @State private var hasLoaded = false
    /// Latest OS versions from cached SOFA feeds. Empty until the first collect that
    /// fetches SOFA — view renders nothing new when empty.
    @State private var sofaRows: [SOFAFeedService.OSFamilyRow] = []

    /// `pro sg` templates the Updates dashboard offers as actionable
    /// remediations. Loaded once per profile. `nil` until the feature-detect
    /// completes; if jamf-cli doesn't include PR #205 yet or `pro sg` errors out the
    /// menu stays hidden so older installs see no regression.
    @State private var updateTemplates: [SmartGroupTemplate] = []
    @State private var selectedTemplate: SmartGroupTemplate?
    @State private var bridge = CLIBridge()

    /// Stable order of templates in the menu — matches the operational priority
    /// from the design plan, not alphabetical.
    private static let templateOrder: [String] = [
        "updates/os-version-below",
        "updates/major-version-behind",
        "updates/rsr-not-applied",
        "updates/beta-os",
    ]

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Operations",
                title: "OS Updates",
                subtitle: subtitle,
                lastModified: snapshot.snapshotDate
            )
            // Shared StaleDataBanner surfaces snapshot freshness above the main content.
            // Suppressed in demo mode (the demo dataset is intentionally static and
            // not user-perceivably "stale"). Renders nothing when source is .fresh.
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory, .scan])
                // Per-kind file dates are the honest per-screen signal here;
                // digest-level collectionSources belongs on summary screens only.
                FreshnessChipRow(sourceDates: snapshot.sourceDates)
            }
            if snapshot.total == 0 {
                emptyState
            } else {
                kpiGrid
                if !updateTemplates.isEmpty {
                    smartGroupActionBar
                }
                planStateCard
                statusSummaryCard
                if !snapshot.failedPlans.isEmpty {
                    failedPlansCard
                }
                if !snapshot.errorDevices.isEmpty {
                    errorDevicesCard
                }
                if !sofaRows.isEmpty {
                    sofaLatestCard
                }
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .task(id: workspace.profile) { await loadSmartGroupTemplates() }
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

    /// Single-button menu surface: avoids cluttering the cards row with four
    /// loose buttons, keeps discovery in one place, and aligns with the read
    /// flow (operator sees a problem in a card, then chooses which template
    /// fits from a focused list).
    private var smartGroupActionBar: some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .foregroundStyle(Theme.Colors.gold)
                Text("Create smart group")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Menu("Select template") {
                    ForEach(updateTemplates) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            Text(Self.menuLabel(for: template))
                        }
                    }
                }
                .controlSize(.regular)
                .help("Open a template-driven sheet to create a smart group for this update gap")
            }
        }
    }

    /// Short, scannable label for the menu — falls back to the slug when the
    /// template description is empty.
    private static func menuLabel(for template: SmartGroupTemplate) -> String {
        switch template.slug {
        case "updates/os-version-below":    return "Devices below an OS version…"
        case "updates/major-version-behind": return "A major OS version behind"
        case "updates/rsr-not-applied":     return "Rapid Security Response not applied"
        case "updates/beta-os":             return "Running a beta OS"
        default:                    return template.description.isEmpty ? template.slug : template.description
        }
    }

    /// Loads the 4 update-category templates once per profile. Errors leave the
    /// list empty, which hides the action bar — older jamf-cli installs see no
    /// regression.
    private func loadSmartGroupTemplates() async {
        let service = SmartGroupTemplateService(executor: DefaultCLIExecutor(bridge: bridge))
        do {
            let all = try await service.listTemplates(profile: workspace.profile)
            let bySlug = Dictionary(uniqueKeysWithValues: all.map { ($0.slug, $0) })
            updateTemplates = Self.templateOrder.compactMap { bySlug[$0] }
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            updateTemplates = []
        } catch {
            AppLogger.cli.error(
                "UpdatesView smart-group templates load failed: \(String(describing: error), privacy: .private)"
            )
            updateTemplates = []
        }
    }

    private var subtitle: String? {
        guard snapshot.total > 0 else { return nil }
        return "\(snapshot.total) device\(snapshot.total == 1 ? "" : "s") tracked for update management."
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
            : UpdateStatusService.load(profile: workspace.profile)
        if !workspace.demoMode,
           let dir = try? WorkspacePaths.dataDir(for: workspace.profile) {
            let sofaSnap = SOFAFeedService.load(dataDir: dir)
            sofaRows = sofaSnap.rows
        }
    }

    private static let demoSnapshot = UpdateStatusService.Snapshot(
        total: 485,
        planTotal: 18,
        statusBreakdown: [
            .init(label: "COMPLETED", count: 320, colorHex: 0x30D158),
            .init(label: "PENDING", count: 95, colorHex: 0x007AFF),
            .init(label: "INSTALLING", count: 42, colorHex: 0x007AFF),
            .init(label: "ERROR", count: 28, colorHex: 0xFF453A)
        ],
        planStateBreakdown: [
            .init(label: "PlanCompleted", count: 12, colorHex: 0x30D158),
            .init(label: "PlanActive", count: 3, colorHex: 0x007AFF),
            .init(label: "PlanPending", count: 2, colorHex: 0x007AFF),
            .init(label: "PlanFailed", count: 1, colorHex: 0xFF453A)
        ],
        errorDevices: [
            UpdateErrorDevice(name: "MacBook-001", serial: "ABC123", deviceType: "Computer",
                             osVersion: "15.2.1", username: "jdoe", status: "ERROR",
                             productKey: "macOS Sequoia 15.3", updated: "2026-05-10T10:30:00Z"),
            UpdateErrorDevice(name: "MacBook-047", serial: "DEF456", deviceType: "Computer",
                             osVersion: "14.7.5", username: "asmith", status: "TIMEOUT",
                             productKey: "macOS Sonoma 14.8", updated: "2026-05-09T15:45:00Z"),
            UpdateErrorDevice(name: "iMac-Pro-12", serial: "GHI789", deviceType: "Computer",
                             osVersion: "15.2.1", username: "bwilson", status: "FAILED",
                             productKey: "macOS Sequoia 15.3", updated: "2026-05-08T09:15:00Z")
        ],
        failedPlans: [
            UpdateFailedPlan(name: "MacBook-035", serial: "JKL012", deviceType: "Computer",
                            osVersion: "14.7.5", username: "cjohnson", state: "PlanFailed",
                            action: "Install", version: "15.3", error: "Insufficient disk space",
                            lastEvent: "2026-05-11T14:20:00Z"),
            UpdateFailedPlan(name: "MacBook-078", serial: "MNO345", deviceType: "Computer",
                            osVersion: "15.2.1", username: "dlee", state: "PlanException",
                            action: "Download", version: "15.3", error: "Network timeout after 3 retries",
                            lastEvent: "2026-05-11T11:45:00Z"),
            UpdateFailedPlan(name: "iMac-024", serial: "PQR678", deviceType: "Computer",
                            osVersion: "14.7.5", username: "egarcia", state: "PlanCanceled",
                            action: "Install", version: "15.3", error: "User canceled installation",
                            lastEvent: "2026-05-10T16:30:00Z"),
            UpdateFailedPlan(name: "MacBook-Air-67", serial: "STU901", deviceType: "Computer",
                            osVersion: "15.1.2", username: "fmartinez", state: "PlanFailed",
                            action: "Validate", version: "15.3", error: "Signature verification failed",
                            lastEvent: "2026-05-10T13:10:00Z"),
            UpdateFailedPlan(name: "Mac-Pro-03", serial: "VWX234", deviceType: "Computer",
                            osVersion: "14.7.5", username: "gbrown", state: "PlanException",
                            action: "Install", version: "15.3", error: "Power management conflict",
                            lastEvent: "2026-05-09T20:25:00Z"),
            UpdateFailedPlan(name: "MacBook-Pro-89", serial: "YZA567", deviceType: "Computer",
                            osVersion: "15.2.1", username: "hdavis", state: "PlanFailed",
                            action: "Restart", version: "15.3", error: "Failed to apply updates on restart",
                            lastEvent: "2026-05-09T18:00:00Z"),
            UpdateFailedPlan(name: "iMac-Pro-45", serial: "BCD890", deviceType: "Computer",
                            osVersion: "14.7.5", username: "ithompson", state: "PlanException",
                            action: "Download", version: "15.3", error: "Storage full during download",
                            lastEvent: "2026-05-08T22:40:00Z")
        ],
        sourceFile: nil,
        snapshotDate: Date(),
        scanFailuresAvailable: true
    )

    // MARK: - Computed values

    private var plansCompleted: Int {
        snapshot.planStateBreakdown.first { $0.label == "PlanCompleted" }?.count ?? 0
    }

    /// From plan_state_summary — always present, and always the same number
    /// the plan-state donut shows. (The failedPlans array only exists after a
    /// --scan-failures run; counting it rendered "0 failing plans" next to a
    /// donut showing thousands of PlanFailed states.)
    private var failingPlansCount: Int {
        snapshot.plansFailedFromStates
    }

    private var errorDevicesValue: String {
        snapshot.scanFailuresAvailable ? "\(snapshot.errorDevices.count)" : "—"
    }

    private var errorDevicesSubtitle: String {
        snapshot.scanFailuresAvailable
            ? "Device-level failures"
            : "Failure scan not run"
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: "No update status data yet",
                message: "Collect data for this screen — use the Collect now banner when shown, or run `jamf-cli pro report update-status` — and it will populate."
            )
        }
    }

    private var kpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Total Devices",
                value: "\(snapshot.total)",
                sub: "Tracked for updates"
            )
            StatTile(
                label: "Plans Active",
                value: "\(snapshot.planTotal)",
                sub: "Update plans in flight"
            )
            StatTile(
                label: "Failing Plans",
                value: "\(failingPlansCount)",
                sub: "Failed or exception state"
            )
            StatTile(
                label: "Error Devices",
                value: errorDevicesValue,
                sub: errorDevicesSubtitle
            )
            StatTile(
                label: "Plans Completed",
                value: "\(plansCompleted)",
                sub: "Successfully finished"
            )
        }
    }

    @ViewBuilder
    private var planStateCard: some View {
        if !snapshot.planStateBreakdown.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionHeader(title: "Plan State Distribution")
                        PNPButton(
                            title: "Export PNG",
                            icon: "square.and.arrow.down",
                            style: .neutral,
                            size: .sm,
                            action: exportPlanStateDonut
                        )
                        .accessibilityLabel("Export plan state distribution chart as PNG")
                        .help("Save the update plan state distribution donut as a PNG image")
                    }
                    HStack(alignment: .top, spacing: 28) {
                        planStateDonut
                            .frame(width: 220, height: 220)
                        planStateLegend
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func exportPlanStateDonut() {
        let slices = snapshot.planStateBreakdown
        let planTotal = snapshot.planTotal
        let result = DashboardChartExport.run(
            title: "Plan State Distribution",
            subtitle: "OS Updates",
            footnote: "Source: pro report update-status · \(planTotal) plans tracked",
            suggestedFilename: DashboardChartExport.filename(for: "update-plan-states", profile: workspace.profile)
        ) {
            UpdatesPlanStateDonutExport(slices: slices, planTotal: planTotal)
        }
        if case .failure(let error) = result {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    private var planStateDonut: some View {
        Chart(snapshot.planStateBreakdown.filter { $0.count > 0 }) { slice in
            SectorMark(
                angle: .value("Count", slice.count),
                innerRadius: .ratio(0.62),
                angularInset: 1.6
            )
            .foregroundStyle(Color(hex: slice.colorHex))
            .accessibilityLabel(slice.label)
            .accessibilityValue("\(slice.count) plans")
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Update plan state distribution")
        .accessibilityChartDescriptor(
            SectorChartDescriptor(
                title: "Update Plan State Distribution",
                unit: " plans",
                slices: snapshot.planStateBreakdown.filter { $0.count > 0 }.map { slice in
                    SectorChartDescriptor.Slice(
                        label: slice.label,
                        value: Double(slice.count)
                    )
                }
            )
        )
    }

    private var planStateLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.planStateBreakdown) { slice in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: slice.colorHex))
                        .frame(width: 12, height: 12)
                    Text(slice.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    Text("\(slice.count)")
                        .font(Theme.Fonts.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg2)
                        .monospacedDigit()
                    let pct = snapshot.planTotal > 0
                        ? (Double(slice.count) / Double(snapshot.planTotal)) * 100
                        : 0
                    Text(String(format: "%.1f%%", pct))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(minWidth: 56, alignment: .trailing)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(slice.label), \(slice.count) plans, \(Int((snapshot.planTotal > 0 ? (Double(slice.count) / Double(snapshot.planTotal)) * 100 : 0).rounded())) percent")
            }
        }
    }

    @ViewBuilder
    private var statusSummaryCard: some View {
        if !snapshot.statusBreakdown.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Device Status Summary")
                    ForEach(snapshot.statusBreakdown) { slice in
                        statusBar(for: slice)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBar(for slice: UpdateStatusService.Snapshot.Slice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let pct = snapshot.total > 0
                ? (Double(slice.count) / Double(snapshot.total)) * 100
                : 0
            HStack {
                HStack(spacing: 4) {
                    let icon = statusIcon(for: slice.label)
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: slice.colorHex))
                    Text(slice.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                }
                Spacer()
                Text("\(slice.count) devices")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(String(format: "%.1f%%", pct))
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(Color(hex: slice.colorHex))
                    .frame(minWidth: 56, alignment: .trailing)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: slice.colorHex))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * pct / 100)))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(slice.label) device status, \(String(format: "%.1f", snapshot.total > 0 ? (Double(slice.count) / Double(snapshot.total)) * 100 : 0)) percent, \(slice.count) devices")
    }

    private func statusIcon(for status: String) -> String {
        let lower = status.lowercased()
        if lower.contains("completed") { return "checkmark.circle" }
        if lower.contains("pending") || lower.contains("installing") { return "arrow.triangle.2.circlepath" }
        if lower.contains("error") { return "exclamationmark.triangle" }
        return "circle.fill"
    }

    @ViewBuilder
    private var failedPlansCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Failed Plans", trailing: "\(snapshot.failedPlans.count) total")
                Table(Array(snapshot.failedPlans.prefix(50))) {
                    TableColumn("Device") { plan in
                        Text(plan.name)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .accessibilityLabel("\(plan.name), device name")
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Serial") { plan in
                        Mono(text: plan.serial, size: 11)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("OS Version") { plan in
                        Mono(text: plan.osVersion, size: 11)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("State") { plan in
                        Pill(text: plan.state, tone: pillTone(for: plan.state))
                            .accessibilityLabel("State \(plan.state)")
                    }
                    .width(min: 118, ideal: 138)

                    TableColumn("Action") { plan in
                        Text(plan.action)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Error") { plan in
                        Text(truncatedError(plan.error))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .lineLimit(1)
                    }
                    .width(min: 150, ideal: 200)
                }
                .frame(minHeight: 200)

                if snapshot.failedPlans.count > 50 {
                    Text("+ \(snapshot.failedPlans.count - 50) more")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var errorDevicesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Error Devices", trailing: "\(snapshot.errorDevices.count) total")
                Table(snapshot.errorDevices) {
                    TableColumn("Device") { device in
                        Text(device.name)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .accessibilityLabel("\(device.name), device name")
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Serial") { device in
                        Mono(text: device.serial, size: 11)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Status") { device in
                        Pill(text: device.status, tone: .danger)
                            .accessibilityLabel("Status \(device.status)")
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Product Key") { device in
                        Mono(text: device.productKey, size: 10.5, color: Theme.Colors.fg2)
                    }
                    .width(min: 150, ideal: 180)

                    TableColumn("Updated") { device in
                        Text(formatDate(device.updated))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 100, ideal: 120)
                }
                .frame(minHeight: 150)
            }
        }
    }

    // MARK: - Helpers

    private func pillTone(for state: String) -> Pill.Tone {
        let upper = state.uppercased()
        switch upper {
        case "PLANCOMPLETED":
            return .teal
        case let s where s.contains("PLANFAILED") || s.contains("PLANEXCEPTION") || s.contains("PLANCANCELED"):
            return .danger
        default:
            return .muted
        }
    }

    private func truncatedError(_ error: String) -> String {
        error.count > 80 ? String(error.prefix(77)) + "..." : error
    }

    private func formatDate(_ dateString: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        guard let date = isoFormatter.date(from: dateString) else {
            return dateString
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - SOFA OS Latest Versions

    /// Shows the latest OS version per platform from the cached SOFA feed.
    /// Renders only when SOFA data has been collected — no error state when absent.
    @ViewBuilder
    private var sofaLatestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "OS Latest Versions")
                ForEach(sofaRows, id: \.osFamily) { row in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.osFamily)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.fg)
                            Text(row.platform)
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.productVersion)
                                .font(Theme.Fonts.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            if let days = row.daysSinceRelease {
                                Text("\(days)d ago")
                                    .font(Theme.Fonts.mono(10.5))
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            } else if !row.releaseDate.isEmpty {
                                Text(String(row.releaseDate.prefix(10)))
                                    .font(Theme.Fonts.mono(10.5))
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(row.osFamily): \(row.productVersion)" +
                        (row.daysSinceRelease.map { ", released \($0) days ago" } ?? "")
                    )
                    if row.osFamily != sofaRows.last?.osFamily {
                        Divider()
                    }
                }
                Text("Source: SOFA (sofa.macadmins.io)")
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }
}

// MARK: - Export-only chart

/// Light-mode export rendering of the update plan state donut. Uses the
/// slice color hex values directly — they're already chosen for state
/// semantics (green completed / blue active / red failed).
private struct UpdatesPlanStateDonutExport: View {
    let slices: [UpdateStatusService.Snapshot.Slice]
    let planTotal: Int

    private var visibleSlices: [UpdateStatusService.Snapshot.Slice] {
        slices.filter { $0.count > 0 }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Chart(visibleSlices) { slice in
                SectorMark(
                    angle: .value("Count", slice.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.6
                )
                .foregroundStyle(Color(hex: slice.colorHex))
            }
            .chartLegend(.hidden)
            .frame(width: 260, height: 260)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(slices) { slice in
                    let pct = planTotal > 0 ? (Double(slice.count) / Double(planTotal)) * 100 : 0
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: slice.colorHex))
                            .frame(width: 10, height: 10)
                        Text(slice.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(hex: 0x111827))
                        Spacer(minLength: 6)
                        Text("\(slice.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", pct))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
                if planTotal > 0 {
                    Text("Total: \(planTotal) plans")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x475569))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}