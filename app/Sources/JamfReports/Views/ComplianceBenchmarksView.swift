import SwiftUI
import Charts

/// Browse view for Platform API compliance benchmark snapshots.
/// Renders a locked empty state until both the experimental Platform API
/// flag is on AND the configured jamf-cli profile reports
/// ``auth-method: platform``. When unlocked and data exists, surfaces a
/// rule pass/fail aggregate, a per-rule bar chart, and a device table.
struct ComplianceBenchmarksView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: ComplianceBenchmarksService.Snapshot = .empty
    @State private var experimentalFeatures = ExperimentalFeatureService()
    @State private var platformCapability: PlatformCapabilityService?
    @State private var platformAvailable = false
    @State private var bridge = CLIBridge()

    /// Tri-state lock decision the view's body switches on.
    enum LockState: Equatable {
        case locked
        case unlockedNoData
        case unlockedWithData
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ComplianceBenchmarksView.header()
                if !workspace.demoMode && lockState == .unlockedWithData {
                    StaleDataBanner(source: snapshot.cacheSource)
                }
                content
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
        }
        .tint(Theme.Colors.goldBright)
        .task(id: workspace.profile) {
            await probePlatformAvailability()
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    // MARK: - Lock decision

    /// View state machine. Exposed for unit tests so they can verify the
    /// gating logic without inspecting SwiftUI body output.
    var lockState: LockState {
        ComplianceBenchmarksView.decideLockState(
            isDemoMode: workspace.demoMode,
            experimentalOn: experimentalFeatures.isEnabled(.platformAPI),
            platformAvailable: platformAvailable,
            hasData: snapshot.totalRules > 0 || snapshot.totalDevices > 0
        )
    }

    /// Pure state-machine function. Inputs:
    /// - ``isDemoMode``: in demo mode the gate is bypassed entirely and
    ///   the demo dataset always renders.
    /// - ``experimentalOn``: ``ExperimentalFeatureService.platformAPI``
    ///   toggle from Settings.
    /// - ``platformAvailable``: result of ``PlatformCapabilityService``
    ///   probe for the active profile.
    /// - ``hasData``: any cached rule or device data on disk.
    static func decideLockState(
        isDemoMode: Bool,
        experimentalOn: Bool,
        platformAvailable: Bool,
        hasData: Bool
    ) -> LockState {
        if isDemoMode {
            return hasData ? .unlockedWithData : .unlockedNoData
        }
        guard experimentalOn else { return .locked }
        guard platformAvailable else { return .locked }
        return hasData ? .unlockedWithData : .unlockedNoData
    }

    // MARK: - Body fragments

    @ViewBuilder
    private var content: some View {
        switch lockState {
        case .locked:
            lockedCard
        case .unlockedNoData:
            unlockedEmptyCard
        case .unlockedWithData:
            ruleAggregateCard
            ruleDistributionCard
            deviceTableCard
        }
    }

    private static func header() -> some View {
        PageHeader(
            kicker: "Experimental — Platform API",
            title: "Compliance Benchmarks",
            subtitle: "Browse compliance benchmark results captured by jamf-cli's Platform API.",
            lastModified: nil
        )
    }

    private var lockedCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                ComplianceBenchmarksView.experimentalBadge()
                EmptyStateView(
                    systemImage: "lock.shield",
                    title: "Experimental — Platform API required",
                    message: ComplianceBenchmarksView.lockReason(
                        experimentalOn: experimentalFeatures.isEnabled(.platformAPI),
                        platformAvailable: platformAvailable
                    ),
                    commands: ComplianceBenchmarksView.setupCommands
                )
                if let url = ExperimentalFeatureService.Feature.platformAPI.discussionURL {
                    Link("Learn more on GitHub Discussions \u{2192}", destination: url)
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.gold)
                }
            }
        }
    }

    private var unlockedEmptyCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                ComplianceBenchmarksView.experimentalBadge()
                EmptyStateView(
                    systemImage: "checkmark.shield",
                    title: "No compliance snapshots yet",
                    message: "Run `jamf-cli pro report compliance-rules` and `compliance-devices` to populate this screen.",
                    commands: [
                        "jamf-cli pro report compliance-rules --output json",
                        "jamf-cli pro report compliance-devices --output json",
                    ]
                )
            }
        }
    }

    // MARK: - Unlocked sections

    private var ruleAggregateCard: some View {
        let agg = snapshot.ruleAggregate
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Rule Pass / Fail", trailing: "\(snapshot.totalRules) rules")
                    Spacer()
                    ComplianceBenchmarksView.experimentalBadge()
                }
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
                SectionHeader(title: "Per-Rule Distribution")
                ForEach(snapshot.rules.prefix(20)) { rule in
                    ComplianceBenchmarksView.ruleBar(rule, contrast: contrast)
                }
                if snapshot.rules.count > 20 {
                    Text("Showing the first 20 rules. Full data is in the Excel workbook (\"Compliance Rules\" sheet).")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var deviceTableCard: some View {
        let agg = snapshot.deviceAggregate
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Devices", trailing: "\(snapshot.totalDevices) devices")
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
                ForEach(snapshot.devices.prefix(30)) { device in
                    ComplianceBenchmarksView.deviceRow(device, contrast: contrast)
                }
                if snapshot.devices.count > 30 {
                    Text("Showing the first 30 devices. Full data is in the Excel workbook (\"Compliance Devices\" sheet).")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    // MARK: - Helpers

    private func reload() {
        snapshot = workspace.demoMode
            ? Self.demoSnapshot
            : ComplianceBenchmarksService.load(profile: workspace.profile)
    }

    private func probePlatformAvailability() async {
        guard !workspace.demoMode, !workspace.profile.isEmpty else {
            platformAvailable = false
            return
        }
        let service = platformCapability ?? PlatformCapabilityService(
            executor: DefaultCLIExecutor(bridge: bridge)
        )
        if platformCapability == nil { platformCapability = service }
        platformAvailable = await service.isAvailable(for: workspace.profile)
    }

    // MARK: - Static rendering helpers (kept static to keep view body type-check cheap)

    private static let setupCommands: [String] = [
        "jamf-cli config add-profile <name> --auth-method platform \\",
        "  --url <gateway-url> --tenant-id <id>",
        "Then enable both platform.enabled: true and experimental.platform_features_enabled: true",
    ]

    private static func lockReason(experimentalOn: Bool, platformAvailable: Bool) -> String {
        if !experimentalOn {
            return "Turn on Platform API in Settings → Experimental Features to enable this screen."
        }
        if !platformAvailable {
            return "Your active jamf-cli profile does not use auth-method: platform. Add a platform-auth profile and switch this workspace to it."
        }
        return "Platform API is enabled but no compliance data is available yet."
    }

    private static func experimentalBadge() -> some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.Colors.goldBright)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.Colors.goldBright.opacity(0.4), lineWidth: 1)
            )
            .accessibilityLabel("Experimental feature")
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

    // MARK: - Demo

    private static var demoSnapshot: ComplianceBenchmarksService.Snapshot {
        ComplianceBenchmarksService.Snapshot(
            rules: [
                .init(rule: "FileVault enabled", passed: 540, failed: 12,
                      unknown: 0, devices: 552, passRate: "98%"),
                .init(rule: "Gatekeeper enabled", passed: 540, failed: 12,
                      unknown: 0, devices: 552, passRate: "98%"),
                .init(rule: "Firewall enabled", passed: 510, failed: 42,
                      unknown: 0, devices: 552, passRate: "92%"),
                .init(rule: "SIP enabled", passed: 552, failed: 0,
                      unknown: 0, devices: 552, passRate: "100%"),
                .init(rule: "Secure boot strict", passed: 0, failed: nil,
                      unknown: 552, devices: 552, passRate: ""),
            ],
            devices: [
                .init(device: "demo-host-001", deviceId: "1",
                      rulesPassed: 5, rulesFailed: 0, compliance: "100%"),
                .init(device: "demo-host-002", deviceId: "2",
                      rulesPassed: 4, rulesFailed: 1, compliance: "80%"),
                .init(device: "demo-host-003", deviceId: "3",
                      rulesPassed: 3, rulesFailed: nil, compliance: ""),
            ],
            rulesSourceFile: nil,
            devicesSourceFile: nil,
            snapshotDate: Date()
        )
    }
}
