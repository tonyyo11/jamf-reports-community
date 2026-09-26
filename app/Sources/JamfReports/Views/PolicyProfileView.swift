import SwiftUI

/// Policy and Profile health dashboard. Surfaces Jamf Pro policy configuration
/// findings and profile assignment failures from `pro report policy-status` and
/// `pro report profile-status` snapshots. Lifts the policy health monitoring
/// from Excel reports into a live, on-screen dashboard.
struct PolicyProfileView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: PolicyHealthService.Snapshot = .empty
    @State private var hasLoaded = false
    @State private var selectedTab: Tab = .policies

    enum Tab: String, CaseIterable {
        case policies = "policies"
        case profiles = "profiles"

        var label: String {
            switch self {
            case .policies: "Policies"
            case .profiles: "Profiles"
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
                kicker: "Operations",
                title: "Policy & Profile Health",
                subtitle: subtitle,
                // The demo dataset is frozen on purpose; an age warning on it is noise.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )

            SegmentedControl(
                selection: $selectedTab,
                options: Tab.allCases.map { ($0, $0.label, $0.icon) }
            )

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
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    private var subtitle: String? {
        switch selectedTab {
        case .policies:
            guard let summary = snapshot.summary else { return nil }
            let totalFindings = snapshot.findings.count
            return "\(summary.totalPolicies) policies tracked, \(totalFindings) finding\(totalFindings == 1 ? "" : "s") identified."
        case .profiles:
            guard snapshot.hasProfileData else { return nil }
            let count = snapshot.profilesWithFailures
            let days = snapshot.profileLookbackDays.map { " in the last \($0) days" } ?? ""
            return "\(count) profile\(count == 1 ? "" : "s") with failures\(days)."
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
            ? DemoData.policyHealth
            : PolicyHealthService.load(profile: workspace.profile)
    }

    // MARK: - Policy Sections

    private var policyEmptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "list.bullet.indent",
                title: "No policy data yet",
                message: "Collect data for this screen — use the Collect now banner when shown, or run `jamf-cli pro report policy-status` — and it will populate."
            )
        }
    }

    private var policyKpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            if let summary = snapshot.summary {
                StatTile(
                    label: "Total Policies",
                    value: "\(summary.totalPolicies)",
                    sub: "Tracked in Jamf Pro"
                )
                StatTile(
                    label: "Enabled",
                    value: "\(summary.enabled)",
                    sub: "Active policies"
                )
                StatTile(
                    label: "Disabled",
                    value: "\(summary.disabled)",
                    sub: "Inactive policies"
                )
                StatTile(
                    label: "Config Findings",
                    value: "\(summary.configFindings)",
                    sub: "Requiring attention"
                )
                StatTile(
                    label: "Warnings",
                    value: "\(summary.warnings)",
                    sub: "Configuration warnings"
                )
                StatTile(
                    label: "Info",
                    value: "\(summary.info)",
                    sub: "Informational notices"
                )
            }
        }
    }

    private var findingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Configuration Findings", trailingTag: snapshot.findings.count <= 100 ? nil : "\(min(100, snapshot.findings.count)) of \(snapshot.findings.count)")
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
                .frame(minHeight: 200)
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
                title: "No profile data yet",
                message: "Collect data for this screen — use the Collect now banner when shown, or run `jamf-cli pro report profile-status` — and it will populate."
            )
        }
    }

    private var profileHealthyCard: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "checkmark.seal",
                title: "No profile failures",
                message: lookbackMessage
            )
        }
    }

    private var lookbackMessage: String {
        let days = snapshot.profileLookbackDays.map { "the last \($0) days" } ?? "the lookback window"
        return "No configuration profile reported installation errors in \(days)."
    }

    private var profileKpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Total Errors",
                value: "\(snapshot.profileTotalErrors)",
                sub: "Profile installation errors"
            )
            StatTile(
                label: "Profiles with Failures",
                value: "\(snapshot.profilesWithFailures)",
                sub: "Requiring attention"
            )
            StatTile(
                label: "Devices Affected",
                value: snapshot.profileDevicesAffected.map { "\($0)" } ?? "—",
                sub: "Unique devices with errors"
            )
            StatTile(
                label: "Lookback",
                value: snapshot.profileLookbackDays.map { "\($0)d" } ?? "—",
                sub: "Report window"
            )
        }
    }

    private var profileStatusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Profile Failures")
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
                            .accessibilityLabel("\(profile.errors) error\(profile.errors == 1 ? "" : "s")")
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
