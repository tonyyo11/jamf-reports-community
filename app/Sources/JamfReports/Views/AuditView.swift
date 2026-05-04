import SwiftUI

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
}

struct AuditView: View {
    @Environment(WorkspaceStore.self) private var workspace
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
    @FocusState private var isSearchFocused: Bool

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
                                .font(.system(size: 13))
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
                                title: isRunningAudit ? "Running..." : "Run Audit",
                                icon: "play.fill",
                                style: .gold
                            ) {
                                runAudit()
                            }
                            .disabled(isRunningAudit || workspace.demoMode)
                        } else {
                            PNPButton(title: "Copy IDs", icon: "doc.on.doc", style: .neutral) {
                                copyGroupIDs()
                            }
                            .disabled(unusedGroups.isEmpty)
                            PNPButton(
                                title: isRunningHygiene ? "Analyzing..." : "Analyze Groups",
                                icon: "magnifyingglass",
                                style: .gold
                            ) {
                                runHygiene()
                            }
                            .disabled(isRunningHygiene || workspace.demoMode)
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
                                Text(f.name).font(.system(size: 13, weight: .semibold))
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
                            Text(f.category.capitalized).font(.system(size: 12.5))
                        }
                        TableColumn("Affected", value: \.affected) { f in
                            AffectedBar(value: f.affected, maxValue: maxAffected, tone: pillTone(f.severity))
                        }
                        TableColumn("Recommendation") { f in
                            HStack(spacing: 8) {
                                Text(f.recommendation)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.Colors.fgMuted)
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
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.ok)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.fg)
                                        .strikethrough(true, color: Theme.Colors.fgMuted)
                                    Text(finding.recommendation)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.Colors.fgMuted)
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
                                Text(g.name).font(.system(size: 12.5, weight: .semibold))
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
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Colors.fgMuted)
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
        let jamfURL = workspace.org.jamfURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard !jamfURL.isEmpty else { return }

        // Typical Jamf Pro computer group URL:
        // https://tenant.jamfcloud.com/smartComputerGroups.html?id=123&o=r
        // https://tenant.jamfcloud.com/staticComputerGroups.html?id=123&o=r
        let page = group.type.lowercased() == "static" ? "staticComputerGroups.html" : "smartComputerGroups.html"
        let urlString = "\(jamfURL)/\(page)?id=\(group.id)&o=r"

        if let url = URL(string: urlString) {
            SystemActions.open(url)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.Colors.gold.opacity(0.5))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color.white.opacity(0.01))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func severityIcon(_ severity: String) -> some View {
        let s = severity.uppercased()
        let color = s == "CRITICAL" ? Theme.Colors.danger :
                    s == "WARNING" ? Theme.Colors.warn : Theme.Colors.ok
        return Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(color)
            .font(.system(size: 12))
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
        let auditSnapshots = await bridge.cachedJSONSnapshots(profile: workspace.profile, type: "audit", limit: 2)
        if let current = auditSnapshots.first,
           let decoded = try? decoder.decode([AuditFinding].self, from: current.data) {
            findings = decoded
            lastAuditDate = current.modified

            let previous = auditSnapshots.dropFirst().first
                .flatMap { try? decoder.decode([AuditFinding].self, from: $0.data) } ?? []
            let currentKeys = Set(decoded.map(\.driftKey))
            let previousKeys = Set(previous.map(\.driftKey))
            newFindingKeys = auditSnapshots.count > 1 ? currentKeys.subtracting(previousKeys) : []
            resolvedFindings = previous.filter { !currentKeys.contains($0.driftKey) }
        }

        let hygieneSnapshots = await bridge.cachedJSONSnapshots(
            profile: workspace.profile,
            type: "group-tools-analyze",
            limit: 1
        )
        if let latestHygiene = hygieneSnapshots.first,
           let decoded = try? decoder.decode([UnusedGroup].self, from: latestHygiene.data) {
            unusedGroups = decoded
            lastHygieneDate = latestHygiene.modified
        }
    }

    private func runAudit() {
        isRunningAudit = true
        workspace.globalStatus = "jrc audit · profile=\(workspace.profile)"
        Task {
            let profile = workspace.profile
            let code = await bridge.audit(profile: profile, category: nil) { line in
                Task { @MainActor in
                    workspace.globalStatus = "jrc · \(line.text)"
                }
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
        workspace.globalStatus = "jrc group-tools analyze · profile=\(workspace.profile)"
        Task {
            let profile = workspace.profile
            let code = await bridge.groupHygiene(profile: profile) { line in
                Task { @MainActor in
                    workspace.globalStatus = "jrc · \(line.text)"
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
                .font(Theme.Fonts.mono(11, weight: .semibold))
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
                        .font(.system(size: 15, weight: .semibold))
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
                    .font(.system(size: 12.5))
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
