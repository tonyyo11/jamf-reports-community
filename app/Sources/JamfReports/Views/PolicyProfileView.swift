import SwiftUI

/// Policy and Profile health dashboard. Surfaces Jamf Pro policy configuration
/// findings and profile assignment failures from `pro report policy-status` and
/// `pro report profile-status` snapshots. Lifts the policy health monitoring
/// from Excel reports into a live, on-screen dashboard.
struct PolicyProfileView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: PolicyHealthService.Snapshot = .empty
    /// The `dataSource` `snapshot` was read for; the content waits for it to match.
    @State private var loadedSource: String?
    @State private var reloads = 0
    @State private var selectedTab: Tab = .policies

    enum Tab: String, CaseIterable {
        case policies = "policies"
        case profiles = "profiles"

        var label: String {
            switch self {
            case .policies: L("Policies")
            case .profiles: L("Profiles")
            }
        }

        var icon: String? {
            switch self {
            case .policies: "doc.text"
            case .profiles: "gear"
            }
        }
    }

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: L("Operations"),
                title: L("Policy & Profile Health"),
                subtitle: subtitle,
                // The demo dataset is frozen on purpose; an age warning on it is noise.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )

            SegmentedControl(
                selection: $selectedTab,
                options: Tab.allCases.map { ($0, $0.label, $0.icon) }
            )

            if loadedSource != dataSource {
                ScreenLoadingCard(what: L("policies and profiles"))
            } else {
                // Shared StaleDataBanner surfaces snapshot freshness above the main content.
                // Suppressed in demo mode (the demo dataset is intentionally static and
                // not user-perceivably "stale"). Renders nothing when source is .fresh.
                if !workspace.demoMode {
                    CollectNowBanner(source: snapshot.cacheSource, tiers: [.refresh, .inventory])
                    // Per-kind file dates are the honest per-screen signal here;
                    // digest-level collectionSources belongs on summary screens only.
                    FreshnessChipRow(
                        sourceDates: snapshot.sourceDates,
                        expectedKinds: ["policy-status", "profile-status"]
                    )
                }

                switch selectedTab {
                case .policies:
                    if snapshot.summary == nil && snapshot.findings.isEmpty {
                        policyEmptyState
                    } else {
                        policyKpiGrid
                        if !snapshot.findings.isEmpty {
                            findingsCard
                        }
                    }
                case .profiles:
                    if !snapshot.hasProfileData {
                        profileEmptyState
                    } else {
                        profileKpiGrid
                        if snapshot.profiles.isEmpty {
                            profileHealthyCard
                        } else {
                            profileStatusCard
                        }
                    }
                }
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    private var subtitle: String? {
        switch selectedTab {
        case .policies:
            guard let summary = snapshot.summary else { return nil }
            let totalFindings = snapshot.findings.count
            return (totalFindings == 1 ? L("\(summary.totalPolicies) policies tracked, \(totalFindings) finding identified.") : L("\(summary.totalPolicies) policies tracked, \(totalFindings) findings identified."))
        case .profiles:
            guard snapshot.hasProfileData else { return nil }
            let count = snapshot.profilesWithFailures
            let days = snapshot.profileLookbackDays.map { L(" in the last \($0) days") } ?? ""
            return (count == 1 ? L("\(count) profile with failures\(days).") : L("\(count) profiles with failures\(days)."))
        }
    }

    // MARK: - Data loading

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { loadedSource = nil; snapshot = .empty }
        guard !workspace.demoMode else {
            snapshot = DemoData.policyHealth
            loadedSource = source
            return
        }
        let profile = workspace.profile
        guard let loaded = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: { PolicyHealthService.load(profile: profile) }
        ) else { return }
        snapshot = loaded
        loadedSource = source
    }

    // MARK: - Policy Sections

    private var policyEmptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "list.bullet.indent",
                title: L("No policy data yet"),
                message: L("Collect data for this screen with the Collect now banner when it shows, or run this command."),
                commands: [EmptyStateView.collectCommand(
                    profile: workspace.profile, kinds: ["policy-status"])]
            )
        }
    }

    private var policyKpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            if let summary = snapshot.summary {
                StatTile(
                    label: L("Total Policies"),
                    value: "\(summary.totalPolicies)",
                    sub: L("Tracked in Jamf Pro")
                )
                StatTile(
                    label: L("Enabled"),
                    value: "\(summary.enabled)",
                    sub: L("Active policies")
                )
                StatTile(
                    label: L("Disabled"),
                    value: "\(summary.disabled)",
                    sub: L("Inactive policies")
                )
                StatTile(
                    label: L("Config Findings"),
                    value: "\(summary.configFindings)",
                    sub: L("Requiring attention")
                )
                StatTile(
                    label: L("Warnings"),
                    value: "\(summary.warnings)",
                    sub: L("Configuration warnings")
                )
                StatTile(
                    label: L("Info"),
                    value: "\(summary.info)",
                    sub: L("Informational notices")
                )
            }
        }
    }

    private var findingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Configuration Findings"), trailingTag: snapshot.findings.count <= 100 ? nil : L("\(min(100, snapshot.findings.count)) of \(snapshot.findings.count)"))
                Table(sortedFindings) {
                    TableColumn("Severity") { finding in
                        Pill(
                            text: finding.severity,
                            tone: severityTone(for: finding.severity),
                            icon: severityIcon(for: finding.severity)
                        )
                        .accessibilityLabel("\(finding.severity) severity")
                    }
                    .width(min: 90, ideal: 90)

                    TableColumn("Policy") { finding in
                        Text(finding.policy)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                            .accessibilityLabel("\(finding.policy), policy name")
                    }
                    .width(min: 180, ideal: 220)

                    TableColumn("Check") { finding in
                        Text(finding.check)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Detail") { finding in
                        Text(finding.detail)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 150, ideal: 200)
                }
                .pageTableHeight(rows: sortedFindings.count)
            }
        }
    }

    private var sortedFindings: [PolicyFinding] {
        snapshot.findings
            .prefix(100) // Limit to 100 rows
            .sorted { lhs, rhs in
                let lhsPriority = severityPriority(lhs.severity)
                let rhsPriority = severityPriority(rhs.severity)
                return lhsPriority < rhsPriority
            }
            .map { $0 }
    }

    private func severityTone(for severity: String) -> Pill.Tone {
        let lower = severity.lowercased()
        if lower.contains("critical") { return .danger }
        if lower.contains("warning") { return .warn }
        return .muted
    }

    private func severityIcon(for severity: String) -> String {
        let lower = severity.lowercased()
        if lower.contains("critical") { return Theme.Severity.critical.systemImage }
        if lower.contains("warning") { return Theme.Severity.high.systemImage }
        return Theme.Severity.low.systemImage
    }

    private func severityPriority(_ severity: String) -> Int {
        let lower = severity.lowercased()
        if lower.contains("critical") { return 0 }
        if lower.contains("warning") { return 1 }
        return 2
    }

    // MARK: - Profile Sections

    private var profileEmptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "doc.badge.gearshape",
                title: L("No profile data yet"),
                message: L("Collect data for this screen with the Collect now banner when it shows, or run this command."),
                commands: [EmptyStateView.collectCommand(
                    profile: workspace.profile, kinds: ["profile-status"])]
            )
        }
    }

    private var profileHealthyCard: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "checkmark.seal",
                title: L("No profile failures"),
                message: lookbackMessage
            )
        }
    }

    private var lookbackMessage: String {
        let days = snapshot.profileLookbackDays.map { L("the last \($0) days") } ?? L("the lookback window")
        return L("No configuration profile reported installation errors in \(days).")
    }

    private var profileKpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: L("Total Errors"),
                value: "\(snapshot.profileTotalErrors)",
                sub: L("Profile installation errors")
            )
            StatTile(
                label: L("Profiles with Failures"),
                value: "\(snapshot.profilesWithFailures)",
                sub: L("Requiring attention")
            )
            StatTile(
                label: L("Devices Affected"),
                value: snapshot.profileDevicesAffected.map { "\($0)" } ?? "—",
                sub: L("Unique devices with errors")
            )
            StatTile(
                label: L("Lookback"),
                value: snapshot.profileLookbackDays.map { "\($0)d" } ?? "—",
                sub: L("Report window")
            )
        }
    }

    private var profileStatusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Profile Failures"))
                Table(snapshot.profiles) {
                    TableColumn("Profile") { profile in
                        Text(profile.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(profile.errors > 0 ? Theme.Colors.danger : Theme.Colors.fg)
                            .accessibilityLabel("\(profile.name), profile name")
                    }
                    .width(min: 180, ideal: 220)

                    TableColumn("Device Type") { profile in
                        Text(profile.deviceType)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Errors") { profile in
                        Text("\(profile.errors)")
                            .font(.caption.monospaced())
                            .foregroundStyle(profile.errors > 0 ? Theme.Colors.danger : Theme.Text.tertiary(contrast))
                            .monospacedDigit()
                            .accessibilityLabel(profile.errors == 1 ? "\(profile.errors) error" : "\(profile.errors) errors")
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Devices") { profile in
                        Text("\(profile.devices)")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .monospacedDigit()
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Last Error") { profile in
                        Text(profile.lastError.isEmpty ? "—" : profile.lastError)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Top Error") { profile in
                        Text(profile.topError.isEmpty ? "—" : profile.topError)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .help(profile.topError)
                    }
                    .width(min: 180, ideal: 260)
                }
                .frame(minHeight: 200)
            }
        }
    }

}
