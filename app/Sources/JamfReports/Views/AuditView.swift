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

    /// Human-readable affected count.
    ///
    /// `pro audit` is an instance-config check, not a per-device scan. It
    /// reports `affected: 0` for CRITICAL/WARNING findings when the audit
    /// source has no per-device breakdown — not because zero devices are
    /// affected. Displaying "0" alongside CRITICAL would mislead operators
    /// into thinking no remediation is needed. We show "—" in those cases
    /// so the severity still prompts action while being honest that the
    /// per-device count comes from Security Posture, not this audit source.
    ///
    /// OK findings legitimately carry `affected: 0` (the control passed)
    /// and are excluded from this substitution.
    var affectedDisplay: String {
        if affected == 0 && severity.uppercased() != "OK" { return "—" }
        return "\(affected)"
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
    @State private var duplicateSerials: DuplicateSerialService.Snapshot = .empty
    @State private var commandHealth: MDMCommandHealthService.Snapshot = .empty
    @State private var commandFindings: [AuditFinding] = []

    @State private var isRunningAudit = false
    @State private var isRunningHygiene = false
    @State private var lastAuditDate: Date?
    @State private var lastHygieneDate: Date?
    @State private var selectedFinding: AuditFinding?
    @State private var selectedCommandFinding: AuditFinding?
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

    // Config Doctor (EPIC #182) — third "Config" segment.
    @State private var doctorReport: DoctorReport?

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

            if !workspace.demoMode && selectedTab != 2 {
                let auditCacheSource = CacheSource.from(snapshotDate: lastAuditDate, withinHours: 36)
                let hygieneCacheSource = CacheSource.from(snapshotDate: lastHygieneDate, withinHours: 36)
                let activeSource = selectedTab == 0 ? auditCacheSource : hygieneCacheSource
                StaleDataBanner(source: activeSource)
            }

            HStack(spacing: 16) {
                SegmentedControl(
                    selection: Binding(
                        get: { auditTabKey(selectedTab) },
                        set: { selectedTab = auditTabIndex($0) }
                    ),
                    options: [
                        ("Audit", "Health Audit", "shield.checkered"),
                        ("Hygiene", "Group Hygiene", "wand.and.stars"),
                        ("Config", "Config Doctor", "stethoscope")
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

            switch selectedTab {
            case 0: auditSection
            case 1: hygieneSection
            default: configSection
            }
        }
        .task(id: workspace.profile) {
            await loadCached()
        }
        .task(id: doctorTaskKey) {
            loadDoctorReport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            switch selectedTab {
            case 0: runAudit()
            case 1: runHygiene()
            default: loadDoctorReport()
            }
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
            title: auditTabTitle(selectedTab),
            subtitle: auditTabSubtitle(selectedTab),
            lastModified: auditTabLastModified(selectedTab)
        ) {
            AnyView(
                VStack(alignment: .trailing, spacing: 6) {
                    if selectedTab != 2 {
                        Mono(
                            text: selectedTab == 0
                                ? lastRunLabel(lastAuditDate, empty: "Last audit: Never")
                                : lastRunLabel(lastHygieneDate, empty: "Last analysis: Never"),
                            size: 10.5
                        )
                    }
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
                        } else if selectedTab == 1 {
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
                        } else {
                            PNPButton(title: "Re-check", icon: "arrow.clockwise", style: .gold) {
                                loadDoctorReport()
                            }
                            .disabled(workspace.demoMode)
                            .help("Re-validate config.yaml against the newest CSV and cached EA results.")
                        }
                    }
                }
            )
        }
    }

    // MARK: - Config Doctor (EPIC #182)

    private func auditTabKey(_ index: Int) -> String {
        switch index { case 0: "Audit"; case 1: "Hygiene"; default: "Config" }
    }

    private func auditTabIndex(_ key: String) -> Int {
        switch key { case "Audit": 0; case "Hygiene": 1; default: 2 }
    }

    private func auditTabTitle(_ index: Int) -> String {
        switch index {
        case 0: "Instance Health Audit"
        case 1: "Computer Group Hygiene"
        default: "Config Doctor"
        }
    }

    private func auditTabSubtitle(_ index: Int) -> String {
        switch index {
        case 0: "Automated checks for security, compliance, and hygiene"
        case 1: "Identifying unused or redundant configuration objects"
        default: "Validating config.yaml against your CSV export and cached EA results"
        }
    }

    private func auditTabLastModified(_ index: Int) -> Date? {
        switch index { case 0: lastAuditDate; case 1: lastHygieneDate; default: nil }
    }

    private var doctorTaskKey: String { "\(workspace.profile)|\(selectedTab == 2)" }

    private func loadDoctorReport() {
        guard selectedTab == 2, !workspace.demoMode else {
            doctorReport = nil
            return
        }
        let profile = workspace.profile
        doctorReport = nil
        Task {
            // run() touches the filesystem (config + EA results); keep it off the
            // main actor so a large ea-results JSON never blocks the UI.
            let report = await Task.detached { ConfigDoctorService.run(profile: profile) }.value
            guard workspace.profile == profile, selectedTab == 2 else { return }
            doctorReport = report
        }
    }

    @ViewBuilder
    private var configSection: some View {
        if workspace.demoMode {
            Card(padding: 24) {
                EmptyStateView(
                    systemImage: "stethoscope",
                    title: "Config Doctor",
                    message: "Switch to a real workspace to validate its config.yaml."
                )
            }
        } else if let report = doctorReport {
            VStack(alignment: .leading, spacing: 16) {
                doctorSummaryStrip(report)
                if report.failCount == 0 && report.warnCount == 0 {
                    Card(padding: 24) {
                        EmptyStateView(
                            systemImage: "checkmark.seal.fill",
                            title: "Configuration looks healthy",
                            message: "No errors or warnings. Passing checks are listed below."
                        )
                    }
                }
                doctorRowsCard(report)
            }
        } else {
            Card(padding: 24) {
                EmptyStateView(
                    systemImage: "stethoscope",
                    title: "Checking configuration…",
                    message: "Reading config.yaml, the newest CSV export, and cached EA results."
                )
            }
        }
    }

    private func doctorSummaryStrip(_ report: DoctorReport) -> some View {
        HStack(spacing: 10) {
            CompactMetricTile(label: "Passing", value: "\(report.passCount)", tone: .teal)
            CompactMetricTile(label: "Suggestions", value: "\(report.suggestCount)", tone: .gold)
            CompactMetricTile(label: "Warnings", value: "\(report.warnCount)", tone: .warn)
            CompactMetricTile(label: "Errors", value: "\(report.failCount)", tone: .danger)
        }
    }

    private func doctorRowsCard(_ report: DoctorReport) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader(title: "Checks")
                    Spacer()
                    Pill(text: "\(report.rows.count) total", tone: .muted)
                }
                .padding(16)
                Divider().background(Theme.Colors.hairline)
                VStack(spacing: 0) {
                    ForEach(Array(report.rows.enumerated()), id: \.element.id) { idx, row in
                        DoctorRowView(row: row)
                        if idx < report.rows.count - 1 {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                }
            }
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
                EmptyStateView(
                    systemImage: "shield.checkered",
                    title: "No audit findings yet",
                    message: "Run an audit from this screen to scan your Jamf instance configuration."
                )
                .frame(maxWidth: .infinity, minHeight: 300)
                .padding(20)
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
                            AffectedBar(
                                value: f.affected,
                                maxValue: maxAffected,
                                tone: pillTone(f.severity),
                                displayText: f.affectedDisplay
                            )
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
            duplicateSerialsSection
            commandHealthSection
        }
    }

    /// v1.23.0+ data-integrity check: computer records sharing a serial number.
    /// A logic-board swap re-enrolls as a fresh record, so the old and new
    /// records collide on serial — which breaks serial-joined lookups
    /// everywhere (jamf-cli's own `--serial` resolution and any of this app's
    /// serial-keyed correlation). Independent of the `pro audit` findings
    /// table above: it renders from its own `duplicate-serials` collect kind,
    /// so it's visible even before the operator has run an audit this
    /// session. DRAFT — needs visual verification at
    /// `PageScaffold.minSupportedWidth`.
    @ViewBuilder
    private var duplicateSerialsSection: some View {
        if duplicateSerials.readFailed {
            Text("A duplicate-serials snapshot exists but couldn't be read — " +
                 "see Settings → Logging for the collect warning.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        } else if !duplicateSerials.isDetected {
            Text("Duplicate-serial detection needs jamf-cli 1.23.0 or later and a " +
                 "collect run — not yet available for this workspace.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        } else if duplicateSerials.groups.isEmpty {
            Card(padding: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.ok)
                    Text("No duplicate serials detected.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                }
            }
        } else {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader(title: "Duplicate Serials")
                        Spacer()
                        Pill(
                            text: "\(duplicateSerials.affectedRecordCount) records affected",
                            tone: .warn
                        )
                    }
                    .padding(16)
                    Divider().background(Theme.Colors.hairline)
                    Table(duplicateSerials.groups) {
                        TableColumn("Serial") { group in
                            Mono(text: group.serial)
                        }
                        .width(min: 110, ideal: 140)
                        TableColumn("Record IDs") { group in
                            Text(group.records.map(\.recordId).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.fg)
                        }
                        .width(min: 90, ideal: 120)
                        TableColumn("Names") { group in
                            Text(group.records.map(\.name).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.fg)
                                .lineLimit(1)
                        }
                        TableColumn("Last Contact") { group in
                            Text(duplicateLastContactDisplay(group))
                                .font(.footnote)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .lineLimit(1)
                        }
                    }
                    .frame(height: tableHeight(rowCount: duplicateSerials.groups.count, maxHeight: 320))
                }
            }
        }
    }

    private func duplicateLastContactDisplay(_ group: DuplicateSerialService.SerialGroup) -> String {
        group.records
            .map { $0.lastContact.isEmpty ? "—" : $0.lastContact }
            .joined(separator: ", ")
    }

    /// Per-device MDM command health from the scan snapshot. Independent of
    /// the `pro audit` findings table, like the duplicate-serials section.
    /// DRAFT — needs visual verification at `PageScaffold.minSupportedWidth`.
    @ViewBuilder
    private var commandHealthSection: some View {
        if commandHealth.readFailed {
            Text("An mdm-command-health snapshot exists but couldn't be read — " +
                 "see Settings → Logging.")
                .font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
        } else if commandHealth.isDetected {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader(title: "Command Health")
                        Spacer()
                        if let d = commandHealth.snapshotDate {
                            let stamp = d.formatted(date: .abbreviated, time: .shortened)
                            Mono(text: "snapshot " + stamp, size: 10.5)
                        }
                    }
                    .padding(16)
                    Divider().background(Theme.Colors.hairline)
                    ForEach(commandFindings) { finding in
                        HStack(spacing: 10) {
                            Pill(text: finding.severity, tone: pillTone(finding.severity))
                                .frame(width: 86, alignment: .leading)
                            Text(finding.name)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Spacer()
                            Text(finding.affectedDisplay).font(.footnote.monospacedDigit())
                            Button { selectedCommandFinding = finding } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Recommendation and where to act.")
                            .popover(isPresented: Binding(
                                get: { selectedCommandFinding?.id == finding.id },
                                set: { if !$0 { selectedCommandFinding = nil } }
                            )) {
                                FindingDetailPopover(
                                    finding: finding,
                                    tone: pillTone(finding.severity)
                                )
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    if !commandHealth.topFailedCommands.isEmpty {
                        Divider().background(Theme.Colors.hairline)
                        HStack(spacing: 6) {
                            Kicker(text: "Most failed")
                            ForEach(commandHealth.topFailedCommands.prefix(3), id: \.name) { c in
                                Pill(text: "\(c.name) ×\(c.count)", tone: .warn)
                            }
                        }
                        .padding(16)
                    }
                }
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
                                Mono(text: "\(finding.affectedDisplay) affected")
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
    /// Snapshots collected before `require_manifest` was enabled (or by
    /// pre-2.6 builds, before the manifest writer existed) verify `.absent`
    /// and would otherwise show a permanent warning card. A warning that can
    /// never clear trains the operator to ignore it, which would mask a real
    /// `.mismatch`/`.corrupt` finding. So an absent-only (or absent+omitted)
    /// result renders as a single neutral status line, not a warning card. `.mismatch`/`.corrupt`
    /// (possible tampering or bit-rot) still render the full warning/danger
    /// card with the shield icon and count pill.
    @ViewBuilder
    private var integrityCard: some View {
        if let summary = integritySummary, summary.unverified > 0 {
            if hasSecuritySensitiveFailure(summary) {
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
            } else {
                // 2.6 shipped the writer (ReportEngine.saveSnapshot ->
                // SnapshotManifest.record). This branch means no manifests were
                // found, which is the DEFAULT state, not an unreleased feature —
                // the old copy said "a future release" and talked operators out
                // of a setting they already have.
                Text("No snapshot integrity manifests found. Set " +
                     "`jamf_cli.require_manifest: true` in config.yaml to stamp a " +
                     "checksum beside each snapshot as it is collected; report " +
                     "generation then refuses to run on a snapshot that fails " +
                     "verification.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
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
                EmptyStateView(
                    systemImage: "wand.and.stars",
                    title: "No unused groups identified",
                    message: "Run analysis to scan for redundant or empty computer groups."
                )
                .frame(maxWidth: .infinity, minHeight: 300)
                .padding(20)
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
        panel.nameFieldStringValue = ExportNaming.filename(
            kind: "audit-findings", profile: workspace.profile, ext: "csv"
        )
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        // The save panel is the user's explicit, per-action consent for this
        // exact path — no additional allow-list gate. (The old gate silently
        // rejected anything outside Documents/Downloads/Desktop, which is why
        // "Export Findings" appeared to do nothing on network shares and
        // custom folders.)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = "Severity,Name,Category,Affected,Recommendation\n"
        let body = findings.map { f in
            [f.severity, f.name, f.category, f.affectedDisplay, f.recommendation]
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
            duplicateSerials = .empty
            commandHealth = .empty
            commandFindings = []
            return
        }

        findings = []
        unusedGroups = []
        lastAuditDate = nil
        lastHygieneDate = nil
        newFindingKeys = []
        resolvedFindings = []
        await loadIntegritySummary()
        duplicateSerials = DuplicateSerialService.load(profile: workspace.profile)
        commandHealth = MDMCommandHealthService.load(profile: workspace.profile)
        commandFindings = commandHealthFindings(commandHealth)

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
                code = try await bridge.audit(profile: profile, category: nil) { line in
                    Task { @MainActor in
                        guard self.isRunningAudit else { return }
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
                workspace.toast = Toast(
                    message: CLIBridge.explainExit(code, operation: "Instance Health Audit"),
                    style: .danger)
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
                code = try await bridge.groupHygiene(profile: profile) { line in
                    Task { @MainActor in
                        guard self.isRunningHygiene else { return }
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
                workspace.toast = Toast(
                    message: CLIBridge.explainExit(code, operation: "Group hygiene analysis"),
                    style: .danger)
            }
        }
    }
}

private struct CompactMetricTile: View {
    let label: String
    let value: String
    let tone: Pill.Tone

    // WCAG 1.4.4: Dynamic Type scaling for KPI numerals
    @ScaledMetric(relativeTo: .title) private var metricSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(text: label)
                Text(value)
                    .font(Theme.Fonts.serif(metricSize, weight: .bold))
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
    /// When set, replaces the numeric label (bar width still reflects `value`).
    var displayText: String? = nil

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
            Text(displayText ?? "\(value)")
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
    @Environment(\.dismiss) private var dismiss

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
                        Mono(text: "\(finding.affectedDisplay) affected")
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

            // `pro audit` returns counts, not device lists — "take action"
            // means routing to the screen that holds the underlying records.
            VStack(alignment: .leading, spacing: 6) {
                Kicker(text: "Take action")
                HStack(spacing: 8) {
                    if let destination = auditActionDestination(for: finding) {
                        PNPButton(title: destination.label, icon: "arrow.right", size: .sm) {
                            dismiss()
                            NotificationCenter.default.post(
                                name: .navigateToTab,
                                object: nil,
                                userInfo: ["tab": destination.tab.rawValue]
                            )
                        }
                        .help("Open the screen with the records behind this finding.")
                    }
                    PNPButton(title: "Generated reports", icon: "doc.text", size: .sm) {
                        dismiss()
                        NotificationCenter.default.post(
                            name: .navigateToTab,
                            object: nil,
                            userInfo: ["tab": Tab.reports.rawValue]
                        )
                    }
                    .help("Open recent reports for the per-device detail.")
                }
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

/// The two "Command health" findings, derived from the per-device scan snapshot
/// rather than `pro audit`. OK when the fleet is clean, WARNING otherwise, so
/// they sort and export like every other finding. Internal for tests.
func commandHealthFindings(_ snapshot: MDMCommandHealthService.Snapshot) -> [AuditFinding] {
    guard snapshot.isDetected else { return [] }
    let failed = snapshot.devicesWithFailures.count
    let stale = snapshot.devicesWithStalePending.count
    let staleDays = DeviceScanBuilders.pendingAgeThresholdDays
    let failedRecommendation = "Open the device's Jamf Pro record → Management → "
        + "Management Commands, read the failure text, then clear the failed "
        + "command there. The app never flushes commands."
    let staleRecommendation = "A command pending this long usually means the Mac "
        + "is offline or its APNs channel is broken. Check last contact, then "
        + "Management → Management Commands."
    return [
        AuditFinding(
            name: "Devices with failed MDM commands",
            affected: failed,
            category: "Command health",
            recommendation: failedRecommendation,
            severity: failed > 0 ? "WARNING" : "OK"
        ),
        AuditFinding(
            name: "MDM commands pending more than \(staleDays) days",
            affected: stale,
            category: "Command health",
            recommendation: staleRecommendation,
            severity: stale > 0 ? "WARNING" : "OK"
        ),
    ]
}

/// Maps a finding to the screen that can show its underlying records — by
/// finding name first, category as fallback. Internal (not private) for tests.
func auditActionDestination(for finding: AuditFinding) -> (label: String, tab: Tab)? {
    let name = finding.name.lowercased()
    if name.contains("unencrypted") || name.contains("filevault")
        || name.contains("gatekeeper") || name.contains("sip")
        || name.contains("firewall") {
        return ("Security Posture", .securityPosture)
    }
    if name.contains("stale") || name.contains("check-in") {
        return ("Offline Outreach", .outreach)
    }
    if name.contains("patch") { return ("Patch Compliance", .patch) }
    if name.contains("update") { return ("OS Updates", .updates) }
    if name.contains("polic") || name.contains("scope") || name.contains("profile") {
        return ("Policies & Profiles", .policyProfile)
    }
    if name.contains("extension attribute") { return ("Extension Attributes", .extensionAttributes) }
    if name.contains("group") { return ("Groups & Searches", .groupInventory) }
    if name.contains("mdm command") { return ("Devices", .devices) }
    switch finding.category.lowercased() {
    case "security": return ("Security Posture", .securityPosture)
    case "compliance": return ("Compliance Posture", .compliancePosture)
    case "hygiene": return ("Policies & Profiles", .policyProfile)
    default: return nil
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

// MARK: - Config Doctor row (EPIC #182)

private struct DoctorRowView: View {
    let row: DoctorRow
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Pill(text: severityLabel, tone: tone, icon: icon)
                .frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = row.hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var severityLabel: String {
        switch row.severity {
        case .pass: "OK"
        case .suggest: "Suggest"
        case .warn: "Warning"
        case .fail: "Error"
        }
    }

    private var icon: String {
        switch row.severity {
        case .pass: "checkmark.circle.fill"
        case .suggest: "lightbulb.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    private var tone: Pill.Tone {
        switch row.severity {
        case .pass: .teal
        case .suggest: .gold
        case .warn: .warn
        case .fail: .danger
        }
    }
}
