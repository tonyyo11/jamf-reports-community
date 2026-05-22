import SwiftUI

// AuditFinding and UnusedGroup are defined in AuditView.swift (shared models).

struct HealthCheckView: View {
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
    @State private var cacheDecodeError: String? = nil
    @FocusState private var isSearchFocused: Bool

    private var filteredFindings: [AuditFinding] {
        findings.filter { finding in
            query.isEmpty
                || finding.name.lowercased().contains(query.lowercased())
                || finding.category.lowercased().contains(query.lowercased())
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                HStack(spacing: 16) {
                    SegmentedControl(
                        selection: Binding(
                            get: { selectedTab == 0 ? "Audit" : "Hygiene" },
                            set: { selectedTab = ($0 == "Audit" ? 0 : 1) }
                        ),
                        options: [
                            ("Audit", "Health Check", "shield.checkered"),
                            ("Hygiene", "Group Hygiene", "wand.and.stars")
                        ]
                    )
                    .accessibilityLabel("View: \(selectedTab == 0 ? "Health Check" : "Group Hygiene")")
                    .help("Switch between Health Check audit findings and Computer Group Hygiene analysis")

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
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                        )
                    }

                    Spacer()
                }

                if let cacheDecodeError, selectedTab == 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audit cache could not be loaded")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Text("\(cacheDecodeError). Re-run the audit to rebuild.")
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.fg2)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Theme.Colors.warn.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.warn.opacity(0.3), lineWidth: 0.5)
                    )
                }

                if selectedTab == 0 {
                    auditSection
                } else {
                    hygieneSection
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
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
        .searchable(text: $query, placement: .toolbar, prompt: "Search audit findings")
    }

    private var header: some View {
        PageHeader(
            kicker: "Health & Hygiene",
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
            title: selectedTab == 0 ? "Health Check" : "Computer Group Hygiene",
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
                                title: isRunningAudit ? "Audit running…" : "Run Health Check",
                                icon: isRunningAudit ? "hourglass" : "play.fill",
                                style: .gold
                            ) {
                                runAudit()
                            }
                            .disabled(isRunningAudit || workspace.demoMode)
                            .help("Run a fresh audit against this workspace. Findings persist between runs so you can track drift.")
                        } else {
                            PNPButton(title: "Copy IDs", icon: "doc.on.doc", style: .neutral) {
                                copyGroupIDs()
                            }
                            .disabled(unusedGroups.isEmpty)
                            .help("Copy the comma-separated list of unused group IDs to the clipboard.")
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
            if findings.isEmpty {
                Card(padding: 24) {
                    EmptyStateView(
                        systemImage: "shield.checkered",
                        title: "No Findings",
                        message: "No audit findings yet. Run an audit to scan your instance.",
                        primaryAction: EmptyStateAction(
                            label: "Run Health Check",
                            icon: "play.fill"
                        ) { runAudit() }
                    )
                }
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
                                Text(f.name)
                                    .font(.callout.weight(.semibold))
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
                            Text(f.category.capitalized).font(.footnote.weight(.medium))
                        }
                        TableColumn("Affected", value: \.affected) { f in
                            AffectedBar(value: f.affected, maxValue: maxAffected, tone: pillTone(f.severity))
                        }
                        TableColumn("Recommendation") { f in
                            HStack(spacing: 8) {
                                Text(f.recommendation)
                                    .font(.footnote.weight(.medium))
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
                                    .font(.system(size: 13).weight(.semibold))
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

    private var hygieneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if unusedGroups.isEmpty {
                Card(padding: 24) {
                    EmptyStateView(
                        systemImage: "wand.and.stars",
                        title: "No Unused Groups",
                        message: "No unused groups identified. Run analysis to check for redundant groups.",
                        primaryAction: EmptyStateAction(
                            label: "Analyze Groups",
                            icon: "magnifyingglass"
                        ) { runHygiene() }
                    )
                }
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
                                    .font(.footnote.weight(.medium))
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
        let color = s == "CRITICAL" ? Theme.Colors.danger :
                    s == "WARNING" ? Theme.Colors.warn : Theme.Colors.ok
        return Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(color)
            .font(.system(size: 12, weight: .medium))
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

    private func loadCached() async {
        if workspace.demoMode {
            findings = []
            unusedGroups = []
            newFindingKeys = []
            resolvedFindings = []
            return
        }

        findings = []
        unusedGroups = []
        lastAuditDate = nil
        lastHygieneDate = nil
        newFindingKeys = []
        resolvedFindings = []

        let decoder = JSONDecoder()
        let auditSnapshots = await bridge.cachedJSONSnapshots(
            profile: workspace.profile,
            type: "audit",
            limit: 2
        )
        cacheDecodeError = nil
        if let current = auditSnapshots.first {
            do {
                let decoded = try decoder.decode([AuditFinding].self, from: current.data)
                findings = decoded
                lastAuditDate = current.modified

                let previous = auditSnapshots.dropFirst().first.flatMap { snapshot in
                    try? decoder.decode([AuditFinding].self, from: snapshot.data)
                } ?? []
                let currentKeys = Set(decoded.map(\.driftKey))
                let previousKeys = Set(previous.map(\.driftKey))
                newFindingKeys = auditSnapshots.count > 1 ? currentKeys.subtracting(previousKeys) : []
                resolvedFindings = previous.filter { !currentKeys.contains($0.driftKey) }
            } catch {
                // Distinguish "no audit run yet" (empty findings, no banner) from "audit
                // cache exists but is corrupt" (empty findings, banner prompting re-run).
                cacheDecodeError = "Audit cache is corrupt: \(error.localizedDescription)"
                findings = []
                newFindingKeys = []
                resolvedFindings = []
            }
        }

        let hygieneSnapshots = await bridge.cachedJSONSnapshots(
            profile: workspace.profile,
            type: "group-tools-analyze",
            limit: 1
        )
        if let latestHygiene = hygieneSnapshots.first,
           let decoded = try? decoder.decode([UnusedGroup].self, from: latestHygiene.data) {
            // Backfill real member counts from the platform-API groups
            // snapshot — see `UnusedGroup.merging(_:withGroupCounts:)`.
            let groupsSnapshots = await bridge.cachedJSONSnapshots(
                profile: workspace.profile,
                type: "groups",
                limit: 1
            )
            unusedGroups = UnusedGroup.merging(decoded, withGroupCounts: groupsSnapshots.first?.data)
            lastHygieneDate = latestHygiene.modified
        }
    }

    private func runAudit() {
        isRunningAudit = true
        workspace.globalStatus = "audit · profile=\(workspace.profile)"
        Task {
            let profile = workspace.profile
            // Guard `onLine` updates against `isRunningAudit`. Lines arriving
            // after the bridge call returns would otherwise race with the
            // post-await `nil` assignment and leave the status bar stuck on
            // a stale line. The flag is the single source of truth
            // for "the run is in progress" and onLine respects it.
            do {
                let code = try await bridge.audit(profile: profile, category: nil) { [weak workspace] line in
                    Task { @MainActor in
                        guard let workspace, self.isRunningAudit else { return }
                        workspace.globalStatus = line.text
                    }
                }
                isRunningAudit = false
                workspace.globalStatus = nil
                if code == 0 {
                    workspace.toast = Toast(message: "Health Check completed", style: .success)
                    await loadCached()
                } else {
                    workspace.toast = Toast(message: "Audit failed · exit \(code)", style: .danger)
                }
            } catch {
                isRunningAudit = false
                workspace.globalStatus = nil
                AppLogger.cli.error("audit failed: \(error, privacy: .private)")
                workspace.toast = Toast(message: "Audit failed — \(error.localizedDescription)", style: .danger)
            }
        }
    }

    private func runHygiene() {
        isRunningHygiene = true
        workspace.globalStatus = "group-tools analyze · profile=\(workspace.profile)"
        Task {
            let profile = workspace.profile
            do {
                let code = try await bridge.groupHygiene(profile: profile) { [weak workspace] line in
                    Task { @MainActor in
                        guard let workspace, self.isRunningHygiene else { return }
                        workspace.globalStatus = line.text
                    }
                }
                isRunningHygiene = false
                workspace.globalStatus = nil
                if code == 0 {
                    workspace.toast = Toast(message: "Group Hygiene analysis completed", style: .success)
                    await loadCached()
                } else {
                    workspace.toast = Toast(message: "Analysis failed · exit \(code)", style: .danger)
                }
            } catch {
                isRunningHygiene = false
                workspace.globalStatus = nil
                AppLogger.cli.error("groupHygiene failed: \(error, privacy: .private)")
                workspace.toast = Toast(message: "Analysis failed — \(error.localizedDescription)", style: .danger)
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
        .background(Color(nsColor: .controlBackgroundColor))
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
                // Alternating content background adapts to light/dark.
                .fill(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]))
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
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                PNPButton(title: "Copy", icon: "doc.on.doc", size: .sm) {
                    SystemActions.copyToClipboard(finding.recommendation)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
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
