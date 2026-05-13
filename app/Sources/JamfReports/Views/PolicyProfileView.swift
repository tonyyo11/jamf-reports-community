import SwiftUI

/// Policy and Profile health dashboard. Surfaces Jamf Pro policy configuration
/// findings and profile deployment status from `pro report policy-status` and
/// `pro classic-macos-profiles list` snapshots. Lifts the policy health monitoring
/// from Excel reports into a live, on-screen dashboard.
struct PolicyProfileView: View {
    @Environment(WorkspaceStore.self) private var workspace
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    kicker: "Operations",
                    title: "Policy & Profile Health",
                    subtitle: subtitle,
                    lastModified: snapshot.snapshotDate
                )

                SegmentedControl(
                    selection: $selectedTab,
                    options: Tab.allCases.map { ($0, $0.label, $0.icon) }
                )

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
                    if snapshot.profiles.isEmpty {
                        profileEmptyState
                    } else {
                        profileKpiGrid
                        profileStatusCard
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
        switch selectedTab {
        case .policies:
            guard let summary = snapshot.summary else { return nil }
            let totalFindings = snapshot.findings.count
            return "\(summary.totalPolicies) policies tracked, \(totalFindings) finding\(totalFindings == 1 ? "" : "s") identified."
        case .profiles:
            let count = snapshot.totalProfiles
            guard count > 0 else { return nil }
            return "\(count) profile\(count == 1 ? "" : "s") tracked across the fleet."
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
            : PolicyHealthService.load(profile: workspace.profile)
    }

    private static let demoSnapshot = PolicyHealthService.Snapshot(
        summary: PolicyStatusSummary(
            totalPolicies: 47,
            enabled: 38,
            disabled: 9,
            configFindings: 12,
            warnings: 8,
            info: 4
        ),
        findings: [
            PolicyFinding(severity: "critical", policy: "Software Update Policy", policyId: "123", check: "Maintenance Window", detail: "No maintenance window configured for major updates"),
            PolicyFinding(severity: "warning", policy: "FileVault Enforcement", policyId: "124", check: "Scope Verification", detail: "Policy scope excludes mobile devices but includes server targets"),
            PolicyFinding(severity: "info", policy: "Chrome Configuration", policyId: "125", check: "Payload Optimization", detail: "Redundant payload keys detected in configuration profile"),
            PolicyFinding(severity: "warning", policy: "Antivirus Deployment", policyId: "126", check: "Trigger Frequency", detail: "Policy triggers on every checkin but should use custom events"),
            PolicyFinding(severity: "critical", policy: "macOS Installer Policy", policyId: "127", check: "Package Verification", detail: "Referenced installer package no longer exists in Jamf Pro"),
            PolicyFinding(severity: "warning", policy: "Dock Configuration", policyId: "128", check: "User Experience", detail: "Policy removes user customization without providing alternatives"),
            PolicyFinding(severity: "info", policy: "Login Window Settings", policyId: "129", check: "Accessibility", detail: "Login window message could be more user-friendly"),
            PolicyFinding(severity: "warning", policy: "Certificate Distribution", policyId: "130", check: "Expiry Monitoring", detail: "Certificate expires in 45 days with no renewal policy configured"),
            PolicyFinding(severity: "critical", policy: "Security Baseline", policyId: "131", check: "Compliance Drift", detail: "Policy conflicts with newly applied mSCP requirements"),
            PolicyFinding(severity: "info", policy: "Printer Setup Policy", policyId: "132", check: "Documentation", detail: "Policy description does not match actual configuration"),
            PolicyFinding(severity: "warning", policy: "VPN Configuration", policyId: "133", check: "Network Security", detail: "Legacy VPN protocol configured instead of IKEv2"),
            PolicyFinding(severity: "warning", policy: "Application Restriction", policyId: "134", check: "Business Impact", detail: "Policy blocks productivity apps during work hours")
        ],
        profiles: [
            ProfileStatusRow(id: AnyCodable(101), name: "Wi-Fi Corporate Network", category: "Network", site: "Default", managementStatus: "Installed", errorCount: AnyCodable(0)),
            ProfileStatusRow(id: AnyCodable(102), name: "Exchange Email Setup", category: "Email", site: "Default", managementStatus: "Pending", errorCount: AnyCodable(3)),
            ProfileStatusRow(id: AnyCodable(103), name: "VPN Configuration", category: "Network", site: "Remote Office", managementStatus: "Installed", errorCount: AnyCodable(0)),
            ProfileStatusRow(id: AnyCodable(104), name: "Certificate Authority", category: "Security", site: "Default", managementStatus: "Failed", errorCount: AnyCodable(15)),
            ProfileStatusRow(id: AnyCodable(105), name: "Software Update Settings", category: "System", site: "Default", managementStatus: "Installed", errorCount: AnyCodable(0)),
            ProfileStatusRow(id: AnyCodable(106), name: "Security Baseline", category: "Security", site: "Default", managementStatus: "Pending", errorCount: AnyCodable(2)),
            ProfileStatusRow(id: AnyCodable(107), name: "Dock Preferences", category: "Desktop", site: "Default", managementStatus: "Removed", errorCount: AnyCodable(8)),
            ProfileStatusRow(id: AnyCodable(108), name: "Printer Configuration", category: "Printing", site: "Branch Office", managementStatus: "Installed", errorCount: AnyCodable(1)),
            ProfileStatusRow(id: AnyCodable(109), name: "Chrome Enterprise", category: "Applications", site: "Default", managementStatus: "Failed", errorCount: AnyCodable(7)),
            ProfileStatusRow(id: AnyCodable(110), name: "Login Window", category: "System", site: "Default", managementStatus: "Installed", errorCount: AnyCodable(0)),
            ProfileStatusRow(id: AnyCodable(111), name: "Time Zone Settings", category: "System", site: "Remote Office", managementStatus: "Pending", errorCount: AnyCodable(1)),
            ProfileStatusRow(id: AnyCodable(112), name: "FileVault Encryption", category: "Security", site: "Default", managementStatus: "Installed", errorCount: AnyCodable(0))
        ],
        sourceFile: nil,
        snapshotDate: Date()
    )

    // MARK: - Policy Sections

    private var policyEmptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "list.bullet.indent",
                title: "No policy data yet",
                message: "Run `jamf-cli pro report policy-status` (Sources tab → Refresh) and this screen will populate."
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
                VStack(alignment: .leading, spacing: 0) {
                    DataTableHeader(columns: [
                        DataTableColumn(title: "Severity", width: 90, alignment: .leading),
                        DataTableColumn(title: "Policy", width: 220, alignment: .leading),
                        DataTableColumn(title: "Check", width: 150, alignment: .leading),
                        DataTableColumn(title: "Detail", width: nil, alignment: .leading)
                    ])

                    ForEach(Array(sortedFindings.enumerated()), id: \.offset) { _, finding in
                        DataTableRow {
                            Pill(
                                text: finding.severity,
                                tone: severityTone(for: finding.severity)
                            )
                            .frame(width: 90, alignment: .leading)

                            Spacer(minLength: 12)

                            Text(finding.policy)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.Colors.fg)
                                .frame(width: 220, alignment: .leading)

                            Spacer(minLength: 12)

                            Text(finding.check)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .frame(width: 150, alignment: .leading)

                            Spacer(minLength: 12)

                            Text(finding.detail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Policy finding, \(finding.severity) severity, \(finding.policy), \(finding.check), \(finding.detail)")
                    }
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
                message: "Run `jamf-cli pro classic-macos-profiles list` (Sources tab → Refresh) and this screen will populate."
            )
        }
    }

    private var profileKpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Total Profiles",
                value: "\(snapshot.totalProfiles)",
                sub: "Configuration profiles"
            )
            StatTile(
                label: "Pending",
                value: "\(snapshot.pendingProfiles)",
                sub: "Awaiting installation"
            )
            StatTile(
                label: "Installed",
                value: "\(snapshot.installedProfiles)",
                sub: "Successfully deployed"
            )
            StatTile(
                label: "Failed/Removed",
                value: "\(snapshot.failedProfiles)",
                sub: "Requiring attention"
            )
        }
    }

    private var profileStatusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Profile Status")
                VStack(alignment: .leading, spacing: 0) {
                    DataTableHeader(columns: [
                        DataTableColumn(title: "Name", width: 220, alignment: .leading),
                        DataTableColumn(title: "Category", width: 120, alignment: .leading),
                        DataTableColumn(title: "Site", width: 100, alignment: .leading),
                        DataTableColumn(title: "Status", width: 120, alignment: .leading),
                        DataTableColumn(title: "Errors", width: 80, alignment: .leading)
                    ])

                    ForEach(Array(snapshot.profiles.enumerated()), id: \.offset) { _, profile in
                        DataTableRow {
                            Text(profile.name ?? "Unknown Profile")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(profileNameColor(for: profile))
                                .frame(width: 220, alignment: .leading)

                            Spacer(minLength: 12)

                            Text(profile.category ?? "—")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .frame(width: 120, alignment: .leading)

                            Spacer(minLength: 12)

                            Text(profile.site ?? "—")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .frame(width: 100, alignment: .leading)

                            Spacer(minLength: 12)

                            if let status = profile.managementStatus {
                                Pill(
                                    text: status,
                                    tone: profileStatusTone(for: status)
                                )
                                .frame(width: 120, alignment: .leading)
                            } else {
                                Text("Unknown")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.Colors.fgMuted)
                                    .frame(width: 120, alignment: .leading)
                            }

                            Spacer(minLength: 12)

                            if let errorCount = profile.errorCount?.value as? Int {
                                Text("\(errorCount)")
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(errorCount > 0 ? Theme.Colors.danger : Theme.Colors.fgMuted)
                                    .monospacedDigit()
                                    .frame(width: 80, alignment: .leading)
                            } else {
                                Text("—")
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(Theme.Colors.fgMuted)
                                    .frame(width: 80, alignment: .leading)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Profile \(profile.name ?? "unknown"), status \(profile.managementStatus ?? "unknown"), \(profile.errorCount?.value as? Int ?? 0) errors")
                    }
                }
                .frame(minHeight: 200)
            }
        }
    }

    private func profileNameColor(for profile: ProfileStatusRow) -> Color {
        guard let status = profile.managementStatus?.lowercased() else {
            return Theme.Colors.fg
        }
        if status.contains("failed") || status.contains("removed") {
            return Theme.Colors.danger
        }
        return Theme.Colors.fg
    }

    private func profileStatusTone(for status: String) -> Pill.Tone {
        let lower = status.lowercased()
        if lower.contains("installed") || lower.contains("success") { return .teal }
        if lower.contains("pending") { return .warn }
        if lower.contains("failed") || lower.contains("removed") || lower.contains("error") { return .danger }
        return .muted
    }
}