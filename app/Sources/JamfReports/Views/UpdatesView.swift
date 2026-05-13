import SwiftUI
import Charts

/// macOS DDM update-plan dashboard. Surfaces DDM update status, plan states,
/// and failure details from `pro report update-status` snapshots via
/// `UpdateStatusService`.
struct UpdatesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot: UpdateStatusService.Snapshot = .empty
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    kicker: "Operations",
                    title: "OS Updates",
                    subtitle: subtitle,
                    lastModified: snapshot.snapshotDate
                )
                if snapshot.total == 0 {
                    emptyState
                } else {
                    kpiGrid
                    planStateCard
                    statusSummaryCard
                    if !snapshot.failedPlans.isEmpty {
                        failedPlansCard
                    }
                    if !snapshot.errorDevices.isEmpty {
                        errorDevicesCard
                    }
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
        snapshotDate: Date()
    )

    // MARK: - Computed values

    private var plansCompleted: Int {
        snapshot.planStateBreakdown.first { $0.label == "PlanCompleted" }?.count ?? 0
    }

    private var failingPlansCount: Int {
        snapshot.failedPlans.count
    }

    private var errorDevicesCount: Int {
        snapshot.errorDevices.count
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: "No update status data yet",
                message: "Run `jamf-cli pro report update-status` (Sources tab → Refresh) and this screen will populate."
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
                sub: "Requiring intervention"
            )
            StatTile(
                label: "Error Devices",
                value: "\(errorDevicesCount)",
                sub: "Device-level failures"
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
            suggestedFilename: DashboardChartExport.filename(for: "update-plan-states")
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
    }

    private var planStateLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.planStateBreakdown) { slice in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: slice.colorHex))
                        .frame(width: 12, height: 12)
                    Text(slice.label)
                        .font(.system(size: 12, weight: .medium))
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
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .frame(width: 56, alignment: .trailing)
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
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                }
                Spacer()
                Text("\(slice.count) devices")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
                Text(String(format: "%.1f%%", pct))
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(Color(hex: slice.colorHex))
                    .frame(width: 56, alignment: .trailing)
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

                VStack(spacing: 4) {
                    DataTableHeader(columns: [
                        DataTableColumn(title: "Device", width: 140, alignment: .leading),
                        DataTableColumn(title: "Serial", width: 100, alignment: .leading),
                        DataTableColumn(title: "OS Version", width: 100, alignment: .leading),
                        DataTableColumn(title: "State", width: 138, alignment: .leading),
                        DataTableColumn(title: "Action", width: 100, alignment: .leading),
                        DataTableColumn(title: "Error", width: nil, alignment: .leading)
                    ])

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(snapshot.failedPlans.prefix(50).enumerated()), id: \.offset) { _, plan in
                                DataTableRow {
                                    Text(plan.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.fg2)
                                        .frame(width: 140, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Mono(text: plan.serial, size: 11)
                                        .frame(width: 100, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Mono(text: plan.osVersion, size: 11)
                                        .frame(width: 100, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Pill(text: plan.state, tone: pillTone(for: plan.state))
                                        .frame(width: 138, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Text(plan.action)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.fg2)
                                        .frame(width: 100, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Text(truncatedError(plan.error))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.Colors.fgMuted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                }
                                .background(Color.white.opacity(0.03))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Failed plan for \(plan.name), state \(plan.state), error \(plan.error)")
                            }
                        }
                    }
                    .frame(height: min(300, CGFloat(snapshot.failedPlans.prefix(50).count) * 28))
                }

                if snapshot.failedPlans.count > 50 {
                    Text("+ \(snapshot.failedPlans.count - 50) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
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

                VStack(spacing: 4) {
                    DataTableHeader(columns: [
                        DataTableColumn(title: "Device", width: 140, alignment: .leading),
                        DataTableColumn(title: "Serial", width: 100, alignment: .leading),
                        DataTableColumn(title: "Status", width: 100, alignment: .leading),
                        DataTableColumn(title: "Product Key", width: 180, alignment: .leading),
                        DataTableColumn(title: "Updated", width: nil, alignment: .leading)
                    ])

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(snapshot.errorDevices.enumerated()), id: \.offset) { _, device in
                                DataTableRow {
                                    Text(device.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.fg2)
                                        .frame(width: 140, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Mono(text: device.serial, size: 11)
                                        .frame(width: 100, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Pill(text: device.status, tone: .danger)
                                        .frame(width: 100, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Mono(text: device.productKey, size: 10.5, color: Theme.Colors.fg2)
                                        .frame(width: 180, alignment: .leading)

                                    Spacer(minLength: 12)

                                    Text(formatDate(device.updated))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.Colors.fgMuted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .background(Color.white.opacity(0.03))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Error device \(device.name), status \(device.status), product \(device.productKey)")
                            }
                        }
                    }
                    .frame(height: min(200, CGFloat(snapshot.errorDevices.count) * 28))
                }
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