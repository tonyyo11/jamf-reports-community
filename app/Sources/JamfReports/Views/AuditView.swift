import SwiftUI

struct AuditFinding: Identifiable, Codable {
    let id = UUID()
    let name: String
    let affected: Int
    let category: String
    let recommendation: String
    let severity: String

    enum CodingKeys: String, CodingKey {
        case name, affected, category, recommendation, severity
    }
}

struct UnusedGroup: Identifiable, Codable {
    let id: String
    let name: String
    let memberCount: Int
    let type: String
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
    
    @State private var selectedTab = 0
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                
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
        .onAppear(perform: loadCached)
    }
    
    private var header: some View {
        PageHeader(
            kicker: "Health & Hygiene",
            title: selectedTab == 0 ? "Instance Health Audit" : "Computer Group Hygiene",
            subtitle: selectedTab == 0 
                ? "Automated checks for security, compliance, and hygiene"
                : "Identifying unused or redundant configuration objects"
        ) {
            AnyView(
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
            )
        }
    }
    
    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if findings.isEmpty {
                emptyState(
                    icon: "shield.checkered",
                    text: "No audit findings yet. Run an audit to scan your instance."
                )
            } else {
                Card(padding: 0) {
                    Table(findings) {
                        TableColumn("Finding") { f in
                            HStack {
                                severityIcon(f.severity)
                                Text(f.name).font(.system(size: 13, weight: .semibold))
                            }
                        }
                        TableColumn("Severity") { f in
                            Pill(text: f.severity, tone: pillTone(f.severity))
                        }
                        TableColumn("Category") { f in
                            Text(f.category.capitalized).font(.system(size: 12.5))
                        }
                        TableColumn("Affected") { f in
                            Mono(text: "\(f.affected)")
                        }
                        TableColumn("Recommendation") { f in
                            Text(f.recommendation).font(.system(size: 12.5)).foregroundStyle(Theme.Colors.fgMuted)
                        }
                    }
                    .frame(minHeight: 400)
                }
            }
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
                        
                        Table(unusedGroups) {
                            TableColumn("Group Name") { g in
                                Text(g.name).font(.system(size: 12.5, weight: .semibold))
                            }
                            TableColumn("Type") { g in
                                Text(g.type.capitalized).font(.system(size: 12.5))
                            }
                            TableColumn("ID") { g in
                                Mono(text: g.id)
                            }
                            TableColumn("Members") { g in
                                Mono(text: "\(g.memberCount)")
                            }
                            TableColumn("Actions") { g in
                                PNPButton(title: "View", size: .sm) {
                                    openInJamfPro(g)
                                }
                            }
                        }
                        .frame(minHeight: 400)
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
    
    private func loadCached() {
        if workspace.demoMode {
            // Load demo data
            return
        }
        
        // Attempt to load from jamf-cli-data/audit and jamf-cli-data/group-tools-analyze
        guard let url = ProfileService.workspaceURL(for: workspace.profile) else { return }
        
        let auditDir = url.appendingPathComponent("jamf-cli-data/audit")
        if let latestAudit = latestJson(in: auditDir) {
            if let data = try? Data(contentsOf: latestAudit),
               let decoded = try? JSONDecoder().decode([AuditFinding].self, from: data) {
                findings = decoded
                lastAuditDate = try? latestAudit.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        }
        
        let hygieneDir = url.appendingPathComponent("jamf-cli-data/group-tools-analyze")
        if let latestHygiene = latestJson(in: hygieneDir) {
            if let data = try? Data(contentsOf: latestHygiene),
               let decoded = try? JSONDecoder().decode([UnusedGroup].self, from: data) {
                unusedGroups = decoded
                lastHygieneDate = try? latestHygiene.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        }
    }
    
    private func latestJson(in directory: URL) -> URL? {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        guard let entries else { return nil }
        
        let jsonFiles = entries.filter { $0.pathExtension == "json" }
        return jsonFiles.sorted { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return d1 > d2
        }.first
    }
    
    private func runAudit() {
        isRunningAudit = true
        Task {
            let profile = workspace.profile
            let code = await bridge.audit(profile: profile, category: nil) { _ in }
            if code == 0 {
                loadCached()
            }
            isRunningAudit = false
        }
    }
    
    private func runHygiene() {
        isRunningHygiene = true
        Task {
            let profile = workspace.profile
            let code = await bridge.groupHygiene(profile: profile) { _ in }
            if code == 0 {
                loadCached()
            }
            isRunningHygiene = false
        }
    }
}
