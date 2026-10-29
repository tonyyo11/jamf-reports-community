import SwiftUI
import Charts

/// Browse view for Platform API compliance benchmark snapshots.
/// Renders a locked empty state until the configured jamf-cli profile
/// reports ``auth-method: platform``. When unlocked and data exists, surfaces a
/// rule pass/fail aggregate, a per-rule bar chart, and a device table.
struct ComplianceBenchmarksView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: ComplianceBenchmarksService.Snapshot = .empty
    /// The `dataSource` `snapshot` was read for; the content waits for it to match.
    @State private var loadedSource: String?
    @State private var reloads = 0
    /// A Platform API profile, as profile discovery read it from jamf-cli.
    private var platformAvailable: Bool {
        !workspace.demoMode && workspace.activeCLIProfile?.auth?.isPlatform == true
    }

    /// A tenant-level integration, which collect skips benchmarks for.
    private var platformTenantLevel: Bool {
        !workspace.demoMode && workspace.activeCLIProfile?.platformLevel == .tenant
    }
    @State private var selectedBenchmark = ""

    /// Tri-state lock decision the view's body switches on.
    enum LockState: Equatable {
        case locked
        case unlockedNoData
        case unlockedWithData
        /// A tenant-level integration, which Jamf Account cannot grant Compliance Benchmarks.
        case needsEnvironmentLevel
    }

    var body: some View {
        PageScaffold {
            ComplianceBenchmarksView.header()
            if loadedSource != dataSource {
                ScreenLoadingCard(what: "compliance benchmarks")
            } else {
                if !workspace.demoMode && lockState == .unlockedWithData {
                    CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
                }
                content
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    // MARK: - Lock decision

    /// View state machine. Exposed for unit tests so they can verify the
    /// gating logic without inspecting SwiftUI body output.
    var lockState: LockState {
        ComplianceBenchmarksView.decideLockState(
            isDemoMode: workspace.demoMode,
            platformAvailable: platformAvailable,
            hasData: snapshot.totalRules > 0 || snapshot.totalDevices > 0,
            tenantLevel: platformTenantLevel
        )
    }

    /// Pure state-machine function. Inputs:
    /// - ``isDemoMode``: in demo mode the gate is bypassed entirely and
    ///   the demo dataset always renders.
    /// - ``platformAvailable``: the active profile's auth method is `platform`
    ///   probe for the active profile.
    /// - ``hasData``: any cached rule or device data on disk.
    /// - ``tenantLevel``: the profile's integration is tenant level, so collect skips benchmarks.
    static func decideLockState(
        isDemoMode: Bool,
        platformAvailable: Bool,
        hasData: Bool,
        tenantLevel: Bool = false
    ) -> LockState {
        if isDemoMode {
            return hasData ? .unlockedWithData : .unlockedNoData
        }
        guard platformAvailable else { return .locked }
        if hasData { return .unlockedWithData }
        return tenantLevel ? .needsEnvironmentLevel : .unlockedNoData
    }

    // MARK: - Body fragments

    @ViewBuilder
    private var content: some View {
        switch lockState {
        case .locked:
            lockedCard
        case .unlockedNoData:
            unlockedEmptyCard
        case .needsEnvironmentLevel:
            environmentLevelCard
        case .unlockedWithData:
            if snapshot.benchmarks.count > 1 { benchmarkPicker }
            ruleAggregateCard
            ruleDistributionCard
            deviceTableCard
        }
    }

    private static func header() -> some View {
        PageHeader(
            kicker: "Platform API",
            title: "Compliance Benchmarks",
            subtitle: "Browse compliance benchmark results captured by jamf-cli's Platform API.",
            lastModified: nil
        )
    }

    private var lockedCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                EmptyStateView(
                    systemImage: "lock.shield",
                    title: "Platform API profile required",
                    message: ComplianceBenchmarksView.lockReason(),
                    commands: ComplianceBenchmarksView.setupCommands
                )
            }
        }
    }

    private var unlockedEmptyCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                EmptyStateView(
                    systemImage: "checkmark.shield",
                    title: "No compliance snapshots yet",
                    message: "Collect this workspace to list its compliance benchmarks and "
                        + "fetch each one's rule and device results.",
                    commands: [
                        "jamf-cli pro compliance-benchmarks list --output json",
                        "jamf-cli pro report compliance-rules \"<title>\" --output json",
                        "jamf-cli pro report compliance-devices \"<title>\" --output json",
                    ]
                )
            }
        }
    }

    private var environmentLevelCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                EmptyStateView(
                    systemImage: "lock.shield",
                    title: "Needs a platform environment integration",
                    message: "This profile's Jamf Account integration is tenant level, and "
                        + "Jamf Account does not offer the Compliance Benchmarks permission at "
                        + "that level, so collect skips benchmarks. Create an integration at "
                        + "platform environment level, then switch this profile to it with "
                        + "Update credentials in Data Sources.",
                    commands: []
                )
            }
        }
    }

    // MARK: - Unlocked sections

    /// What the unlocked cards draw; see `displayed`.
    private var shown: ComplianceBenchmarksService.Snapshot {
        Self.displayed(snapshot, selected: selectedBenchmark)
    }

    /// The benchmark on screen when the snapshot holds several, else nil.
    nonisolated static func activeBenchmark(
        in snapshot: ComplianceBenchmarksService.Snapshot, selected: String
    ) -> String? {
        let benchmarks = snapshot.benchmarks
        guard benchmarks.count > 1 else { return nil }
        return benchmarks.contains(selected) ? selected : benchmarks[0]
    }

    /// One benchmark's rows when there are several (aggregates across benchmarks would
    /// double-count devices), all rows when there is one or none.
    nonisolated static func displayed(
        _ snapshot: ComplianceBenchmarksService.Snapshot, selected: String
    ) -> ComplianceBenchmarksService.Snapshot {
        activeBenchmark(in: snapshot, selected: selected).map(snapshot.filtered(to:)) ?? snapshot
    }

    private var benchmarkPicker: some View {
        let active = Self.activeBenchmark(in: snapshot, selected: selectedBenchmark) ?? ""
        return Menu {
            ForEach(snapshot.benchmarks, id: \.self) { name in
                Button {
                    selectedBenchmark = name
                } label: {
                    if name == active {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 10, weight: .semibold))
                Text(active).font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .foregroundStyle(Theme.Colors.fg2)
            .background(Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Compliance benchmark")
        .accessibilityValue(active)
        .help("Switch which compliance benchmark this screen shows")
    }

    private var ruleAggregateCard: some View {
        let agg = shown.ruleAggregate
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Rule Pass / Fail", trailing: "\(shown.totalRules) rules")
                HStack(alignment: .top, spacing: 28) {
                    ComplianceBenchmarksView.aggregateDonut(passed: agg.passed,
                                                            failed: agg.failed,
                                                            unknown: agg.unknown)
                        .frame(width: 200, height: 200)
                    ComplianceBenchmarksView.aggregateLegend(passed: agg.passed,
                                                             failed: agg.failed,
                                                             unknown: agg.unknown,
                                                             contrast: contrast)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var ruleDistributionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Per-Rule Distribution",
                              trailing: "Top 20 by failures, name")
                ForEach(
                    ComplianceBenchmarksService.rankedRules(shown.rules).prefix(20)
                ) { rule in
                    ComplianceBenchmarksView.ruleBar(rule, contrast: contrast)
                }
                if shown.rules.count > 20 {
                    Text("Showing the 20 rules with the most failures. Full data is in the Excel workbook (\"Compliance Rules\" sheet).")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var deviceTableCard: some View {
        let agg = shown.deviceAggregate
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Devices",
                              trailing: "\(shown.totalDevices) devices, top 30 by failed rules")
                HStack(spacing: 10) {
                    ComplianceBenchmarksView.deviceCounter(label: "Failing",
                                                           value: agg.failing,
                                                           color: Theme.Colors.danger)
                    ComplianceBenchmarksView.deviceCounter(label: "Passing",
                                                           value: agg.passing,
                                                           color: Theme.Colors.ok)
                    ComplianceBenchmarksView.deviceCounter(label: "Unknown",
                                                           value: agg.unknown,
                                                           color: Theme.Colors.warn)
                }
                ForEach(
                    ComplianceBenchmarksService.rankedDevices(shown.devices).prefix(30)
                ) { device in
                    ComplianceBenchmarksView.deviceRow(device, contrast: contrast)
                }
                if shown.devices.count > 30 {
                    Text("Showing the 30 devices with the most failed rules. Full data is in the Excel workbook (\"Compliance Devices\" sheet).")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { loadedSource = nil; snapshot = .empty }
        guard !workspace.demoMode else {
            snapshot = DemoData.complianceBenchmarksSnapshot
            loadedSource = source
            return
        }
        let profile = workspace.profile
        guard let loaded = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: { ComplianceBenchmarksService.load(profile: profile) }
        ) else { return }
        snapshot = loaded
        loadedSource = source
    }

    // MARK: - Static rendering helpers (kept static to keep view body type-check cheap)

    private static let setupCommands: [String] = [
        "jamf-cli config add-profile <name> --auth-method platform \\",
        "  --url https://<us|eu|apac>.api.jamfcloud.com --environment-id <id>",
    ]

    private static func lockReason() -> String {
        "Your active jamf-cli profile does not use auth-method: platform. Connect with a Jamf "
            + "Account integration (Settings › Add connection, then Platform API) or switch this "
            + "workspace to a Platform profile."
    }

    private static func aggregateDonut(passed: Int, failed: Int, unknown: Int) -> some View {
        let slices: [(label: String, value: Int, color: Color)] = [
            ("Passed", passed, Theme.Colors.ok),
            ("Failed", failed, Theme.Colors.danger),
            ("Unknown", unknown, Theme.Colors.warn),
        ].filter { $0.value > 0 }
        return Chart(slices, id: \.label) { slice in
            SectorMark(
                angle: .value("Count", slice.value),
                innerRadius: .ratio(0.62),
                angularInset: 1.6
            )
            .foregroundStyle(slice.color)
            .accessibilityLabel(slice.label)
            .accessibilityValue("\(slice.value)")
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Rule pass-fail-unknown donut")
    }

    private static func aggregateLegend(passed: Int,
                                        failed: Int,
                                        unknown: Int,
                                        contrast: ColorSchemeContrast) -> some View {
        let rows: [(label: String, value: Int, color: Color)] = [
            ("Passed", passed, Theme.Colors.ok),
            ("Failed", failed, Theme.Colors.danger),
            ("Unknown (no result)", unknown, Theme.Colors.warn),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.label) { row in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.color)
                        .frame(width: 12, height: 12)
                    Text(row.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    Text("\(row.value)")
                        .font(Theme.Fonts.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg2)
                        .monospacedDigit()
                }
            }
        }
    }

    private static func ruleBar(_ rule: ComplianceBenchmarksService.Snapshot.Rule,
                                contrast: ColorSchemeContrast) -> some View {
        let failed = rule.failed ?? 0
        let total = max(rule.passed + failed + rule.unknown, 1)
        let failRatio = Double(failed) / Double(total)
        let color: Color = failed > 0 ? Theme.Colors.danger
            : (rule.failed == nil ? Theme.Colors.warn : Theme.Colors.ok)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.rule)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(rule.passRate.isEmpty ? "—" : rule.passRate)
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * failRatio)))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rule.rule), \(failed) failing of \(total)")
    }

    private static func deviceCounter(label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(color)
            Text("\(value)")
                .font(Theme.Fonts.mono(20, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    private static func deviceRow(_ device: ComplianceBenchmarksService.Snapshot.Device,
                                  contrast: ColorSchemeContrast) -> some View {
        let failed = device.rulesFailed
        let failColor: Color = (failed ?? 0) > 0 ? Theme.Colors.danger
            : (failed == nil ? Theme.Colors.warn : Theme.Colors.ok)
        return HStack(spacing: 12) {
            Text(device.device.isEmpty ? "(unnamed)" : device.device)
                .font(.callout)
                .foregroundStyle(Theme.Colors.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("ID \(device.deviceId.isEmpty ? "—" : device.deviceId)")
                .font(Theme.Fonts.mono(10.5))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(width: 100, alignment: .trailing)
            Text("\(device.rulesPassed) passed")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
            Text(failed.map { "\($0) failed" } ?? "unknown")
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(failColor)
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
            Text(device.compliance.isEmpty ? "—" : device.compliance)
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(failColor)
                .frame(width: 64, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deviceA11y(device: device))
    }

    private static func deviceA11y(device: ComplianceBenchmarksService.Snapshot.Device) -> String {
        let name = device.device.isEmpty ? "Unnamed device" : device.device
        let failed = device.rulesFailed.map { "\($0) failed" } ?? "unknown failures"
        return "\(name), \(device.rulesPassed) passed, \(failed)"
    }
}
