import SwiftUI
import Charts

/// Browse view for Platform API DDM blueprint and declaration snapshots.
/// Renders a locked empty state until both the experimental Platform API
/// flag is on AND the configured jamf-cli profile reports
/// ``auth-method: platform``. When unlocked and data exists, surfaces
/// blueprint adoption rate, deployment status breakdown, and a
/// per-source declaration table.
struct DDMBlueprintView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: DDMBlueprintService.Snapshot = .empty
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
                DDMBlueprintView.header()
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
        DDMBlueprintView.decideLockState(
            isDemoMode: workspace.demoMode,
            experimentalOn: experimentalFeatures.isEnabled(.platformAPI),
            platformAvailable: platformAvailable,
            hasData: snapshot.totalBlueprints > 0 || snapshot.totalDeclarationSources > 0
        )
    }

    /// Pure state-machine function. Inputs:
    /// - ``isDemoMode``: in demo mode the gate is bypassed entirely and
    ///   the demo dataset always renders.
    /// - ``experimentalOn``: ``ExperimentalFeatureService.platformAPI``
    ///   toggle from Settings.
    /// - ``platformAvailable``: result of ``PlatformCapabilityService``
    ///   probe for the active profile.
    /// - ``hasData``: any cached blueprint or DDM data on disk.
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
            adoptionCard
            blueprintTableCard
            declarationTableCard
        }
    }

    private static func header() -> some View {
        PageHeader(
            kicker: "Experimental — Platform API",
            title: "DDM Blueprints",
            subtitle: "Browse DDM blueprint deployment and per-source declaration status captured by jamf-cli's Platform API.",
            lastModified: nil
        )
    }

    private var lockedCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                DDMBlueprintView.experimentalBadge()
                EmptyStateView(
                    systemImage: "lock.shield",
                    title: "Experimental — Platform API required",
                    message: DDMBlueprintView.lockReason(
                        experimentalOn: experimentalFeatures.isEnabled(.platformAPI),
                        platformAvailable: platformAvailable
                    ),
                    commands: DDMBlueprintView.setupCommands
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
                DDMBlueprintView.experimentalBadge()
                EmptyStateView(
                    systemImage: "doc.badge.gearshape",
                    title: "No DDM snapshots yet",
                    message: "Run `jamf-cli pro report blueprint-status` and `ddm-status` to populate this screen.",
                    commands: [
                        "jamf-cli pro report blueprint-status --output json",
                        "jamf-cli pro report ddm-status --output json",
                    ]
                )
            }
        }
    }

    // MARK: - Unlocked sections

    private var adoptionCard: some View {
        let agg = snapshot.blueprintAggregate
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Blueprint Adoption",
                                  trailing: "\(snapshot.totalBlueprints) blueprints")
                    Spacer()
                    DDMBlueprintView.experimentalBadge()
                }
                HStack(alignment: .top, spacing: 28) {
                    DDMBlueprintView.adoptionDonut(deployed: agg.deployed,
                                                   notDeployed: agg.notDeployed)
                        .frame(width: 200, height: 200)
                    DDMBlueprintView.adoptionLegend(deployed: agg.deployed,
                                                    notDeployed: agg.notDeployed,
                                                    failing: agg.failing,
                                                    pending: agg.pending,
                                                    rate: snapshot.adoptionRate,
                                                    contrast: contrast)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var blueprintTableCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Blueprints", trailing: "Top 20 by failures, pending, name")
                ForEach(DDMBlueprintView.sortedBlueprints(snapshot.blueprints).prefix(20)) { blueprint in
                    DDMBlueprintView.blueprintRow(blueprint, contrast: contrast)
                }
                if snapshot.blueprints.count > 20 {
                    Text("Showing the first 20 blueprints. Full data is in the Excel workbook (\"Platform Blueprints\" sheet).")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var declarationTableCard: some View {
        let agg = snapshot.declarationAggregate
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Declaration Sources",
                              trailing: "\(snapshot.totalDeclarationSources) sources")
                HStack(spacing: 10) {
                    DDMBlueprintView.declarationCounter(label: "Sources w/ Issues",
                                                        value: agg.sourcesWithIssues,
                                                        color: Theme.Colors.danger)
                    DDMBlueprintView.declarationCounter(label: "Unsuccessful",
                                                        value: agg.unsuccessfulTotal,
                                                        color: Theme.Colors.warn)
                    DDMBlueprintView.declarationCounter(label: "Sources",
                                                        value: snapshot.totalDeclarationSources,
                                                        color: Theme.Colors.ok)
                }
                ForEach(DDMBlueprintView.sortedDeclarations(snapshot.declarations).prefix(30)) { entry in
                    DDMBlueprintView.declarationRow(entry, contrast: contrast)
                }
                if snapshot.declarations.count > 30 {
                    Text("Showing the first 30 sources. Full data is in the Excel workbook (\"Platform DDM Status\" sheet).")
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
            : DDMBlueprintService.load(profile: workspace.profile)
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
        return "Platform API is enabled but no DDM data is available yet."
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

    private static func adoptionDonut(deployed: Int, notDeployed: Int) -> some View {
        let slices: [(label: String, value: Int, color: Color)] = [
            ("Deployed", deployed, Theme.Colors.ok),
            ("Not deployed", notDeployed, Theme.Colors.warn),
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
        .accessibilityLabel("Blueprint deployment donut")
    }

    private static func adoptionLegend(deployed: Int,
                                       notDeployed: Int,
                                       failing: Int,
                                       pending: Int,
                                       rate: Double,
                                       contrast: ColorSchemeContrast) -> some View {
        let rows: [(label: String, value: Int, color: Color)] = [
            ("Deployed", deployed, Theme.Colors.ok),
            ("Not deployed", notDeployed, Theme.Colors.warn),
            ("With failures", failing, Theme.Colors.danger),
            ("With pending", pending, Theme.Colors.gold),
        ]
        let percent = Int((rate * 100).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(percent)%")
                    .font(Theme.Fonts.mono(28, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
                Text("adopted")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
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

    static func sortedBlueprints(
        _ blueprints: [DDMBlueprintService.Snapshot.Blueprint]
    ) -> [DDMBlueprintService.Snapshot.Blueprint] {
        blueprints.sorted { lhs, rhs in
            let lf = lhs.failed ?? 0
            let rf = rhs.failed ?? 0
            if lf != rf { return lf > rf }
            let lp = lhs.pending ?? 0
            let rp = rhs.pending ?? 0
            if lp != rp { return lp > rp }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    static func sortedDeclarations(
        _ declarations: [DDMBlueprintService.Snapshot.Declaration]
    ) -> [DDMBlueprintService.Snapshot.Declaration] {
        declarations.sorted { lhs, rhs in
            if lhs.unsuccessful != rhs.unsuccessful {
                return lhs.unsuccessful > rhs.unsuccessful
            }
            return lhs.source.lowercased() < rhs.source.lowercased()
        }
    }

    private static func blueprintRow(_ blueprint: DDMBlueprintService.Snapshot.Blueprint,
                                     contrast: ColorSchemeContrast) -> some View {
        let failed = blueprint.failed ?? 0
        let pending = blueprint.pending ?? 0
        let stateColor: Color = blueprint.state.uppercased() == "DEPLOYED"
            ? Theme.Colors.ok : Theme.Colors.warn
        let failColor: Color = failed > 0 ? Theme.Colors.danger : Theme.Colors.fg2
        let pendingColor: Color = pending > 0 ? Theme.Colors.gold : Theme.Colors.fg2
        return HStack(spacing: 12) {
            Text(blueprint.name.isEmpty ? "(unnamed)" : blueprint.name)
                .font(.callout)
                .foregroundStyle(Theme.Colors.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(blueprint.state.isEmpty ? "—" : blueprint.state)
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 120, alignment: .trailing)
            Text("\(blueprint.succeeded) ok")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.ok)
                .frame(width: 70, alignment: .trailing)
                .monospacedDigit()
            Text("\(failed) failed")
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(failColor)
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()
            Text("\(pending) pending")
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(pendingColor)
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blueprintA11y(blueprint))
    }

    private static func blueprintA11y(_ blueprint: DDMBlueprintService.Snapshot.Blueprint) -> String {
        let name = blueprint.name.isEmpty ? "Unnamed blueprint" : blueprint.name
        let state = blueprint.state.isEmpty ? "no state" : blueprint.state
        let failed = blueprint.failed.map { "\($0) failed" } ?? "no failures reported"
        let pending = blueprint.pending.map { "\($0) pending" } ?? "no pending"
        return "\(name), \(state), \(blueprint.succeeded) succeeded, \(failed), \(pending)"
    }

    private static func declarationCounter(label: String, value: Int, color: Color) -> some View {
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

    private static func declarationRow(_ entry: DDMBlueprintService.Snapshot.Declaration,
                                       contrast: ColorSchemeContrast) -> some View {
        let unsuccessfulColor: Color = entry.unsuccessful > 0
            ? Theme.Colors.danger : Theme.Colors.fg2
        return HStack(spacing: 12) {
            Text(entry.source.isEmpty ? "(no source)" : entry.source)
                .font(.callout)
                .foregroundStyle(Theme.Colors.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(entry.type.isEmpty ? "—" : entry.type)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(width: 100, alignment: .trailing)
            Text("\(entry.devices) devices")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
            Text("\(entry.declarations) decls")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()
            Text("\(entry.successful) ok")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.ok)
                .frame(width: 70, alignment: .trailing)
                .monospacedDigit()
            Text("\(entry.unsuccessful) bad")
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(unsuccessfulColor)
                .frame(width: 70, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(declarationA11y(entry))
    }

    private static func declarationA11y(_ entry: DDMBlueprintService.Snapshot.Declaration) -> String {
        let source = entry.source.isEmpty ? "Unnamed source" : entry.source
        let type = entry.type.isEmpty ? "unknown type" : entry.type
        return "\(source), \(type), \(entry.devices) devices, "
            + "\(entry.successful) successful, \(entry.unsuccessful) unsuccessful"
    }

    // MARK: - Demo

    private static var demoSnapshot: DDMBlueprintService.Snapshot {
        DDMBlueprintService.Snapshot(
            blueprints: [
                .init(name: "Baseline Security", state: "DEPLOYED", scope: 552,
                      steps: 4, succeeded: 540, failed: 12, pending: 0),
                .init(name: "Software Update Eligibility", state: "DEPLOYED", scope: 552,
                      steps: 2, succeeded: 510, failed: 42, pending: 0),
                .init(name: "Beta Test Group", state: "DEPLOYED", scope: 24,
                      steps: 1, succeeded: 22, failed: 0, pending: 2),
                .init(name: "Legacy Profile Removal", state: "NOT_DEPLOYED", scope: 100,
                      steps: 1, succeeded: 0, failed: nil, pending: nil),
                .init(name: "OOO Macs Lockdown", state: "OUT_OF_DATE", scope: 12,
                      steps: 3, succeeded: 0, failed: nil, pending: nil),
            ],
            declarations: [
                .init(source: "Baseline Security", type: "blueprint",
                      declarations: 4, devices: 540, successful: 528, unsuccessful: 12),
                .init(source: "Software Update Eligibility", type: "blueprint",
                      declarations: 2, devices: 510, successful: 468, unsuccessful: 42),
                .init(source: "Device Group Membership", type: "system",
                      declarations: 1, devices: 552, successful: 552, unsuccessful: 0),
            ],
            blueprintsSourceFile: nil,
            declarationsSourceFile: nil,
            snapshotDate: Date()
        )
    }
}
