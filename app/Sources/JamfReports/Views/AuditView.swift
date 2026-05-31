import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AuditFinding: Identifiable, Codable {
    let id = UUID()
    let name: String
    let affected: Int
    let category: String
    let recommendation: String
    let severity: String

    var driftKey: String {
        [
            category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case name, affected, category, recommendation, severity
    }
}

struct UnusedGroup: Identifiable, Codable {
    let id: String
    let name: String
    let memberCount: Int
    let type: String
    let reason: String?

    var reasonLabel: String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Not referenced by any policy or profile." : trimmed
    }

    /// jamf-cli's `pro group-tools analyze --unused` always returns
    /// `memberCount: 0` regardless of the group's actual size (upstream
    /// limitation). The platform-API `groups` snapshot has the correct value
    /// in `membershipCount`, keyed by `groupJamfProId`. This helper builds the
    /// id → count map from the supplied groups-list JSON and rewrites each
    /// `UnusedGroup`'s `memberCount` to match. Falls back to the analyzer's
    /// value (typically 0) when no platform record exists for that id.
    static func merging(_ unused: [UnusedGroup], withGroupCounts groupsJSON: Data?) -> [UnusedGroup] {
        guard let data = groupsJSON,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return unused
        }
        var counts: [String: Int] = [:]
        for entry in array {
            guard let id = entry["groupJamfProId"] as? String else { continue }
            if let n = entry["membershipCount"] as? Int {
                counts[id] = n
            } else if let n = entry["membershipCount"] as? NSNumber {
                counts[id] = n.intValue
            }
        }
        return unused.map { g in
            guard let real = counts[g.id], real != g.memberCount else { return g }
            return UnusedGroup(id: g.id, name: g.name, memberCount: real,
                               type: g.type, reason: g.reason)
        }
    }
}

struct AuditView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var bridge = CLIBridge()

    @State private var findings: [AuditFinding] = []
    @State private var unusedGroups: [UnusedGroup] = []

    @State private var isRunningAudit = false
    @State private var isRunningHygiene = false
    @State private var lastAuditDate: Date?
    @State private var lastHygieneDate: Date?
    @State private var selectedFinding: AuditFinding?
    @State private var newFindingKeys: Set<String> = []
    @State private var resolvedFindings: [AuditFinding] = []

    @State private var selectedTab = 0
    @State private var query = ""
    @State private var sortOrderAudit = [KeyPathComparator(\AuditFinding.name)]
    @State private var sortOrderHygiene = [KeyPathComparator(\UnusedGroup.name)]
    @State private var showExportError = false
    @State private var exportError: String? = nil
    @FocusState private var isSearchFocused: Bool

    // PR-10 / threat-model T-11: surface unverified-snapshot state.
    @State private var integritySummary: SnapshotManifest.WorkspaceVerificationSummary?

    private var filteredFindings: [AuditFinding] {
        findings.filter { finding in
            query.isEmpty || finding.name.lowercased().contains(query.lowercased()) || finding.category.lowercased().contains(query.lowercased())
        }.sorted(using: sortOrderAudit)
    }

    private var sortedHygiene: [UnusedGroup] {
        unusedGroups.sorted(using: sortOrderHygiene)
    }

    private var maxAffected: Int {
        max(findings.map(\.affected).max() ?? 0, 1)
    }

    private var criticalCount: Int {
        findings.filter { $0.severity.uppercased() == "CRITICAL" }.count
    }

    private var warningCount: Int {
        findings.filter { $0.severity.uppercased() == "WARNING" }.count
    }

    private var affectedTotal: Int {
        findings.reduce(0) { $0 + $1.affected }
    }

    private var categoryCount: Int {
        Set(findings.map { $0.category.lowercased() }).count
    }

    var body: some View {
        PageScaffold {
            header

            HStack(spacing: 16) {
                SegmentedControl(
                    selection: Binding(
                        get: { selectedTab == 0 ? "Audit" : "Hygiene" },
                        set: { selectedTab = ($0 == "Audit" ? 0 : 1) }
                    ),
                    options: [
                        ("Audit", "Health Audit", "shield.checkered"),
                        ("Hygiene", "Group Hygiene", "wand.and.stars")
                    ]
                )

                if selectedTab == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.fgMuted)
                        TextField("Search findings", text: $query)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(Theme.Colors.fg)
                            .focused($isSearchFocused)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 240, height: 28)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                    )
                }

                Spacer()
            }

            if selectedTab == 0 {
                auditSection
            } else {
                hygieneSection
            }
        }
        .task(id: workspace.profile) {
            await loadCached()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            if selectedTab == 0 { runAudit() } else { runHygiene() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            if selectedTab == 0 { isSearchFocused = true }
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Health & Hygiene",
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
            title: selectedTab == 0 ? "Instance Health Audit" : "Computer Group Hygiene",
            subtitle: selectedTab == 0
                ? "Automated checks for security, compliance, and hygiene"
                : "Identifying unused or redundant configuration objects",
            lastModified: selectedTab == 0 ? lastAuditDate : lastHygieneDate
        ) {
            AnyView(
                VStack(alignment: .trailing, spacing: 6) {
                    Mono(
                        text: selectedTab == 0
                            ? lastRunLabel(lastAuditDate, empty: "Last audit: Never")
                            : lastRunLabel(lastHygieneDate, empty: "Last analysis: Never"),
                        size: 10.5
                    )
                    HStack(spacing: 8) {
                        if selectedTab == 0 {
                            PNPButton(
                                title: isRunningAudit ? "Audit running…" : "Run Audit",
                                icon: isRunningAudit ? "hourglass" : "play.fill",
                                style: .gold
                            ) {
                                runAudit()
                            }
                            .disabled(isRunningAudit || workspace.demoMode)
                            .help("Run a fresh audit against this workspace.")
                            PNPButton(title: "Export Findings", icon: "square.and.arrow.up", style: .neutral) {
                                Task { await exportFindings() }
                            }
                            .disabled(findings.isEmpty || workspace.demoMode)
                            .help("Export all audit findings to a CSV file")
                        } else {
                            PNPButton(title: "Copy IDs", icon: "doc.on.doc", style: .neutral) {
                                copyGroupIDs()
                            }
                            .disabled(unusedGroups.isEmpty)
                            .help("Copy the comma-separated list of unused group IDs to the clipboard.")
                            PNPButton(title: "Copy All", icon: "doc.on.clipboard", style: .neutral) {
                                copyAllGroups()
                            }
                            .disabled(sortedHygiene.isEmpty || workspace.demoMode)
                            .help("Copy all unused group IDs and names as tab-separated values")
                            PNPButton(
                                title: isRunningHygiene ? "Analyzing…" : "Analyze Groups",
                                icon: isRunningHygiene ? "hourglass" : "magnifyingglass",
                                style: .gold
                            ) {
                                runHygiene()
                            }
                            .disabled(isRunningHygiene || workspace.demoMode)
                            .help("Find computer groups not referenced by any policy or profile.")
                        }
                    }
                }
            )
        }
    }

    private func navigateToOverview() {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": Tab.overview.rawValue]
        )
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            integrityCard
            if findings.isEmpty {
                emptyState(
                    icon: "shield.checkered",
                    text: "No audit findings yet. Run an audit to scan your instance."
                )
            } else {
                auditSummaryStrip
                Card(padding: 0) {
                    Table(filteredFindings, sortOrder: $sortOrderAudit) {
                        TableColumn("Finding", value: \.name) { f in
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(f.severity.uppercased() == "CRITICAL"
                                          ? Theme.Colors.danger
                                          : Color.clear)
                                    .frame(width: 3)
                                    .frame(maxHeight: .infinity)
                                severityIcon(f.severity)
                                Text(f.name).font(.callout.weight(.semibold))
                                if newFindingKeys.contains(f.driftKey) {
                                    Pill(text: "New", tone: .gold, icon: "sparkle")
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .animation(.spring(response: 0.35, dampingFraction: 0.7),
                                       value: newFindingKeys.contains(f.driftKey))
                        }
                        TableColumn("Severity", value: \.severity) { f in
                            Pill(text: f.severity, tone: pillTone(f.severity))
                        }
                        TableColumn("Category", value: \.category) { f in
                            Text(f.category.capitalized).font(.footnote)
                        }
                        TableColumn("Affected", value: \.affected) { f in
                            AffectedBar(value: f.affected, maxValue: maxAffected, tone: pillTone(f.severity))
                        }
                        TableColumn("Recommendation") { f in
                            HStack(spacing: 8) {
                                Text(f.recommendation)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                PNPButton(title: "Details", icon: "info.circle", size: .sm) {
                                    selectedFinding = f
                                }
                            }
                        }
                    }
                    .frame(height: tableHeight(rowCount: filteredFindings.count))
                    .popover(item: $selectedFinding) { finding in
                        FindingDetailPopover(finding: finding, tone: pillTone(finding.severity))
                    }
                }
                resolvedSection
            }
        }
    }

    @ViewBuilder
    private var resolvedSection: some View {
        if !resolvedFindings.isEmpty {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Kicker(text: "Resolved · \(resolvedFindings.count)", tone: .teal)
                        Spacer()
                    }
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    Divider().background(Theme.Colors.hairline)

                    VStack(spacing: 0) {
                        ForEach(Array(resolvedFindings.enumerated()), id: \.element.id) { idx, finding in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.ok)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.name)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.Colors.fg)
                                        .strikethrough(true, color: Theme.Colors.fgMuted)
                                    Text(finding.recommendation)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.tertiary(contrast))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Pill(text: finding.category, tone: .muted)
                                Mono(text: "\(finding.affected) affected")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .opacity(0.5)
                            if idx < resolvedFindings.count - 1 {
                                Divider().background(Theme.Colors.hairline)
                            }
                        }
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: resolvedFindings.count)
        }
    }

    private var auditSummaryStrip: some View {
        HStack(spacing: 10) {
            CompactMetricTile(label: "Critical", value: "\(criticalCount)", tone: .danger)
            CompactMetricTile(label: "Warnings", value: "\(warningCount)", tone: .warn)
            CompactMetricTile(label: "Affected", value: "\(affectedTotal)", tone: .gold)
            CompactMetricTile(label: "Categories", value: "\(categoryCount)", tone: .teal)
        }
    }

    /// PR-10 / threat-model T-11: surface snapshot directories whose newest
    /// JSON could not be verified against its sibling `manifest.json`. Renders
    /// nothing when the workspace is clean — additive, no layout cost.
    ///
    /// Card copy distinguishes legacy snapshots (`.absent` / `.omitted` —
    /// expected for snapshots collected before PR-7 introduced manifests;
    /// fix is "re-run Collect") from security-sensitive failures
    /// (`.mismatch` / `.corrupt` — possible tampering or bit-rot; fix
    /// requires investigation). Prevents first-launch support questions
    /// from users seeing "Unverified" on legitimately-old workspaces.
    @ViewBuilder
    private var integrityCard: some View {
        if let summary = integritySummary, summary.unverified > 0 {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: integrityIcon(summary))
                        .font(.title3)
                        .foregroundStyle(integrityTint(summary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(integrityTitle(summary))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                        Text(integrityDetail(summary))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    Pill(text: "\(summary.unverified)", tone: integrityTone(summary),
                         icon: "shield.lefthalf.filled")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(integrityTitle(summary)): \(summary.unverified) snapshot directories")
            .accessibilityHint(integrityHint(summary))
        }
    }

    /// True when at least one snapshot failed in a way that suggests
    /// tampering rather than pre-PR-7 legacy state.
    private func hasSecuritySensitiveFailure(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> Bool {
        summary.mismatch > 0 || summary.corrupt > 0
    }

    private func integrityIcon(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> String {
        hasSecuritySensitiveFailure(summary)
            ? "exclamationmark.shield.fill"
            : "clock.arrow.circlepath"
    }

    private func integrityTint(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> Color {
        hasSecuritySensitiveFailure(summary) ? Theme.Colors.danger : Theme.Colors.warn
    }

    private func integrityTone(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> Pill.Tone {
        hasSecuritySensitiveFailure(summary) ? .danger : .warn
    }

    private func integrityTitle(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> String {
        hasSecuritySensitiveFailure(summary)
            ? "Snapshot integrity violation"
            : "Snapshots from before SHA-256 manifests"
    }

    private func integrityDetail(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> String {
        var parts: [String] = []
        if summary.absent > 0 { parts.append("\(summary.absent) missing manifest") }
        if summary.corrupt > 0 { parts.append("\(summary.corrupt) corrupt manifest") }
        if summary.omitted > 0 { parts.append("\(summary.omitted) partial collect") }
        if summary.mismatch > 0 { parts.append("\(summary.mismatch) hash mismatch") }
        let breakdown = parts.joined(separator: " · ")
        if hasSecuritySensitiveFailure(summary) {
            return "\(breakdown). Possible tampering or bit-rot — investigate before " +
                "trusting this data. Enable jamf_cli.require_manifest " +
                "(Configuration → jamf-cli Cache → \"Require snapshot manifest\") " +
                "to abort future generate runs when this occurs."
        }
        // Only-`.absent`/`.omitted` case. When strict mode is OFF this is
        // almost always pre-PR-7 legacy snapshots (re-run Collect fixes it).
        // When strict mode is ON, `.absent` is also the documented T-11
        // attack signal (attacker deleted manifest.json after tampering) so
        // we can't claim it's "not a security concern." (security-reviewer S-01)
        if workspace.configState.jamfCLIRequireManifest {
            return "\(breakdown). May indicate pre-PR-7 snapshots or " +
                "manifest deletion — re-run Collect to confirm. If the " +
                "warning persists after a fresh Collect, investigate as " +
                "possible tampering."
        }
        return "\(breakdown). Pre-PR-7 snapshots without manifests. Re-run " +
            "Collect to attach SHA-256 manifests; not a security concern " +
            "while jamf_cli.require_manifest is disabled."
    }

    private func integrityHint(
        _ summary: SnapshotManifest.WorkspaceVerificationSummary
    ) -> String {
        hasSecuritySensitiveFailure(summary)
            ? "Investigate before trusting this data."
            : "Re-run Collect to attach manifests."
    }

    private var hygieneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if unusedGroups.isEmpty {
                emptyState(
                    icon: "wand.and.stars",
                    text: "No unused groups identified. Run analysis to check for redundant groups."
                )
            } else {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            SectionHeader(title: "Unused Computer Groups")
                            Spacer()
                            Pill(text: "\(unusedGroups.count) groups", tone: .warn)
                        }
                        .padding(16)

                        Divider().background(Theme.Colors.hairline)

                        Table(sortedHygiene, sortOrder: $sortOrderHygiene) {
                            TableColumn("Group Name", value: \.name) { g in
                                Text(g.name).font(.footnote.weight(.semibold))
                            }
                            TableColumn("Type", value: \.type) { g in
                                groupTypePill(g.type)
                            }
                            TableColumn("ID", value: \.id) { g in
                                Mono(text: g.id)
                            }
                            TableColumn("Members", value: \.memberCount) { g in
                                groupMemberPill(g.memberCount)
                            }
                            TableColumn("Why Flagged") { g in
                                Text(g.reasonLabel)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                                    .lineLimit(2)
                            }
                            TableColumn("Actions") { g in
                                PNPButton(title: "View", size: .sm) {
                                    openInJamfPro(g)
                                }
                            }
                        }
                        .frame(height: tableHeight(rowCount: sortedHygiene.count, maxHeight: 430))
                    }
                }
            }
        }
    }

    private func openInJamfPro(_ group: UnusedGroup) {
        guard let groupID = Int(group.id) else {
            workspace.toast = Toast(
                message: "Group `\(group.name)` has a non-numeric id (\(group.id)) — cannot build console URL.",
                style: .danger
            )
            return
        }
        let isStatic = group.type.lowercased() == "static"
        guard let url = workspace.consoleURL(forComputerGroupID: groupID, isStatic: isStatic) else {
            workspace.toast = Toast(
                message: "Active profile has no Jamf Pro URL configured. Set one in Settings to enable console links.",
                style: .danger
            )
            return
        }
        SystemActions.open(url)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.Colors.gold.opacity(0.5))
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color.white.opacity(0.01))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func severityIcon(_ severity: String) -> some View {
        let s = severity.uppercased()
        let (symbolName, color, label) = {
            switch s {
            case "CRITICAL":
                return ("octagon.fill", Theme.Colors.danger, "Critical severity")
            case "WARNING":
                return ("exclamationmark.triangle.fill", Theme.Colors.warn, "Warning severity")
            case "INFO":
                return ("info.circle.fill", Theme.Colors.info, "Info severity")
            default:
                return ("questionmark.circle.fill", Theme.Colors.fgMuted, "Unknown severity")
            }
        }()
        return Image(systemName: symbolName)
            .foregroundStyle(color)
            .font(.system(size: 12))
            .accessibilityLabel(label)
    }

    private func pillTone(_ severity: String) -> Pill.Tone {
        let s = severity.uppercased()
        if s == "CRITICAL" { return .danger }
        if s == "WARNING" { return .warn }
        return .teal
    }

    private func groupTypePill(_ type: String) -> Pill {
        type.lowercased() == "static"
            ? Pill(text: "Static", tone: .gold)
            : Pill(text: "Smart", tone: .teal)
    }

    private func groupMemberPill(_ count: Int) -> Pill {
        if count == 0 { return Pill(text: "0", tone: .danger) }
        if count <= 5 { return Pill(text: "\(count)", tone: .warn) }
        return Pill(text: "\(count)", tone: .muted)
    }

    private func tableHeight(rowCount: Int, maxHeight: CGFloat = 420) -> CGFloat {
        min(max(CGFloat(rowCount) * 36 + 48, 152), maxHeight)
    }

    private func lastRunLabel(_ date: Date?, empty: String) -> String {
        guard let date else { return empty }
        return "Last run: \(FileDisplay.date(date))"
    }

    private func copyGroupIDs() {
        let ids = unusedGroups.map(\.id).joined(separator: "\n")
        SystemActions.copyToClipboard(ids)
    }

    private func copyAllGroups() {
        let rows = sortedHygiene.map { "\($0.id)\t\($0.name)" }.joined(separator: "\n")
        SystemActions.copyToClipboard(rows)
    }

    @MainActor
    private func exportFindings() async {
        let panel = NSSavePanel()
        let dateStr = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withFullDate]
        )
        panel.nameFieldStringValue = "audit-findings-\(workspace.profile)-\(dateStr).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SystemActions.userExportTargetIsAllowed(url) else { return }
        let header = "Severity,Name,Category,Affected,Recommendation\n"
        let body = findings.map { f in
            [f.severity, f.name, f.category, "\(f.affected)", f.recommendation]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: ",")
        }.joined(separator: "\n")
        do {
            try (header + body).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            showExportError = true
        }
    }

    private func loadCached() async {
        if workspace.demoMode {
            findings = []
            unusedGroups = []
            newFindingKeys = []
            resolvedFindings = []
            integritySummary = nil
            return
        }

        findings = []
        unusedGroups = []
        lastAuditDate = nil
        lastHygieneDate = nil
        newFindingKeys = []
        resolvedFindings = []
        await loadIntegritySummary()

        let decoder = JSONDecoder()
        let auditSnapshots = await bridge.cachedJSONSnapshots(profile: workspace.profile, type: "audit", limit: 2)
        if let current = auditSnapshots.first,
           let decoded = try? decoder.decode([AuditFinding].self, from: current.data) {
            findings = decoded
            lastAuditDate = current.modified

            let currentKeys = Set(decoded.map(\.driftKey))
            if let previousSnapshot = auditSnapshots.dropFirst().first {
                do {
                    let previous = try decoder.decode([AuditFinding].self, from: previousSnapshot.data)
                    let previousKeys = Set(previous.map(\.driftKey))
                    newFindingKeys = currentKeys.subtracting(previousKeys)
                    resolvedFindings = previous.filter { !currentKeys.contains($0.driftKey) }
                } catch {
                    AppLogger.ui.warning(
                        "AuditView: previous snapshot decode failed — \(error, privacy: .private)"
                    )
                    // newFindingKeys and resolvedFindings are already reset above;
                    // leave them empty rather than misreporting all current findings as new.
                }
            }
        }

        let hygieneSnapshots = await bridge.cachedJSONSnapshots(
            profile: workspace.profile,
            type: "group-tools-analyze",
            limit: 1
        )
        if let latestHygiene = hygieneSnapshots.first,
           let decoded = try? decoder.decode([UnusedGroup].self, from: latestHygiene.data) {
            let groupsSnapshots = await bridge.cachedJSONSnapshots(
                profile: workspace.profile,
                type: "groups",
                limit: 1
            )
            unusedGroups = UnusedGroup.merging(decoded, withGroupCounts: groupsSnapshots.first?.data)
            lastHygieneDate = latestHygiene.modified
        }
    }

    /// PR-10 / threat-model T-11: scan the workspace's jamf-cli-data/<type>
    /// dirs and aggregate per-snapshot verification results so the
    /// integrity card can warn when any are unverified.
    ///
    /// PR-11 / threat-model T-12 / security-reviewer 2nd-pass S-01:
    /// ALSO scan `snapshots/computers/summaries/` so tampered per-log
    /// summaries appear in the integrity card alongside data-snapshot
    /// integrity issues.
    private func loadIntegritySummary() async {
        let profile = workspace.profile
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            integritySummary = nil
            return
        }
        let summariesDir = try? WorkspacePaths.summariesDir(for: profile)
        // PR-22 T-14: also scan <state-dir>/*.last files. The state manifest
        // is rewritten by StateFileStore on every recordRun, so a tampered
        // .last surfaces here as .mismatch the same way a tampered snapshot
        // JSON does.
        let stateDir = try? WorkspacePaths.stateDir(for: profile)
        let summary = await Task.detached(priority: .userInitiated) {
            var s = SnapshotManifest.scanWorkspace(dataDir: dataDir)
            if let summariesDir {
                s = s + SnapshotManifest.scanFlatDir(summariesDir)
            }
            if let stateDir {
                s = s + SnapshotManifest.scanStateDir(stateDir)
            }
            return s
        }.value
        // Profile may have switched while the detached scan ran — gate.
        guard workspace.profile == profile else { return }
        integritySummary = summary
    }

    private func runAudit() {
        isRunningAudit = true
        workspace.globalStatus = "audit · profile=\(workspace.profile)"
        Task {
            let profile = workspace.profile
            // Late-arriving onLine callbacks would otherwise overwrite the
            // post-await `globalStatus = nil` and leave a stale status line.
            // Guarding on `isRunningAudit` makes the running flag the single
            // source of truth for "show CLI output."
            let code: Int32
            do {
                code = try await bridge.audit(profile: profile, category: nil) { [weak workspace] line in
                    Task { @MainActor in
                        guard let workspace, self.isRunningAudit else { return }
                        workspace.globalStatus = line.text
                    }
                }
            } catch {
                isRunningAudit = false
                workspace.globalStatus = nil
                workspace.toast = Toast(message: "Audit failed · \(error.localizedDescription)", style: .danger)
                return
            }
            isRunningAudit = false
            workspace.globalStatus = nil
            if code == 0 {
                workspace.toast = Toast(message: "Instance Health Audit completed", style: .success)
                await loadCached()
            } else {
                workspace.toast = Toast(message: "Audit failed · exit \(code)", style: .danger)
            }
        }
    }

    private func runHygiene() {
        isRunningHygiene = true
        workspace.globalStatus = "group-tools analyze · profile=\(workspace.profile)"
        Task {
            let profile = workspace.profile
            let code: Int32
            do {
                code = try await bridge.groupHygiene(profile: profile) { [weak workspace] line in
                    Task { @MainActor in
                        guard let workspace, self.isRunningHygiene else { return }
                        workspace.globalStatus = line.text
                    }
                }
            } catch {
                isRunningHygiene = false
                workspace.globalStatus = nil
                workspace.toast = Toast(message: "Analysis failed · \(error.localizedDescription)", style: .danger)
                return
            }
            isRunningHygiene = false
            workspace.globalStatus = nil
            if code == 0 {
                workspace.toast = Toast(message: "Group Hygiene analysis completed", style: .success)
                await loadCached()
            } else {
                workspace.toast = Toast(message: "Analysis failed · exit \(code)", style: .danger)
            }
        }
    }
}

private struct CompactMetricTile: View {
    let label: String
    let value: String
    let tone: Pill.Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(text: label)
                Text(value)
                    .font(Theme.Fonts.serif(24, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Circle()
                .fill(toneColor(tone))
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.winBG2)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }
}

private struct AffectedBar: View {
    let value: Int
    let maxValue: Int
    let tone: Pill.Tone

    private var fraction: CGFloat {
        guard maxValue > 0 else { return 0 }
        return min(max(CGFloat(value) / CGFloat(maxValue), 0), 1)
    }

    private var fillColor: Color {
        switch tone {
        case .danger: Theme.Colors.danger.opacity(0.55)
        case .warn:   Theme.Colors.warn.opacity(0.55)
        default:      toneColor(tone).opacity(0.45)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 80, height: 16)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fillColor)
                .frame(width: value == 0 ? 0 : max(4, 80 * fraction), height: 16)
            Text("\(value)")
                // Pinned: fixed 80×16 gauge — the numeral must not scale
                // with Dynamic Type or it clips the bar.
                .font(.custom("IBM Plex Mono", size: 11).weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
                .frame(width: 80, height: 16)
        }
        .frame(width: 80, height: 16)
    }
}

private struct FindingDetailPopover: View {
    let finding: AuditFinding
    let tone: Pill.Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.name)
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.fg)
                    HStack(spacing: 6) {
                        Pill(text: finding.severity, tone: tone)
                        Pill(text: finding.category, tone: .muted)
                        Mono(text: "\(finding.affected) affected")
                    }
                }
                Spacer()
            }

            Divider().background(Theme.Colors.hairline)

            VStack(alignment: .leading, spacing: 6) {
                Kicker(text: "Recommendation")
                Text(finding.recommendation)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                PNPButton(title: "Copy", icon: "doc.on.doc", size: .sm) {
                    let text = "[\(finding.severity)] \(finding.name)\n\(finding.category)\n\(finding.recommendation)"
                    SystemActions.copyToClipboard(text)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Theme.Colors.winBG)
    }
}

private func toneColor(_ tone: Pill.Tone) -> Color {
    switch tone {
    case .muted: Theme.Colors.fgMuted
    case .gold: Theme.Colors.gold
    case .teal: Theme.Colors.teal
    case .warn: Theme.Colors.warn
    case .danger: Theme.Colors.danger
    }
}
