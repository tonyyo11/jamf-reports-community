import Foundation

// MARK: - HtmlBlock

/// What one detail section contributes to the report: markup for a block inside a detail
/// group, or the reason it left none. A section with nothing to show is not drawn as an
/// empty box; the audit appendix lists it with its reason instead.
struct HtmlBlock {
    let html: String
    /// Why the section is not in the report. Nil when it has markup.
    let omission: String?

    var isShown: Bool { omission == nil }

    static func shown(_ html: String) -> HtmlBlock { .init(html: html, omission: nil) }
    static func omitted(_ reason: String) -> HtmlBlock { .init(html: "", omission: reason) }
}

// MARK: - Groups

extension SectionID {
    /// The section's name in the audit appendix's list of what a report leaves out.
    var title: String {
        switch self {
        case .aiNarrative: "AI fleet summary"
        case .atAGlance: "At a glance"
        case .needsAttention: "Needs attention"
        case .jamfDashboard: "Jamf fleet dashboard"
        case .auditAppendix: "Audit appendix"
        case .securityTiles: "Security controls"
        case .complianceBands: "Compliance posture"
        case .agentHealth: "Security agent health"
        case .exceptionList: "Exception list"
        case .protectAlerts: "Protect alerts"
        case .insightsDrift: "Protect insights drift"
        case .auditEvidence: "Audit findings"
        case .patchBar: "Patch compliance chart"
        case .patchQueue: "Patch titles behind"
        case .osAdoptionChart: "OS version distribution"
        case .osCurrency: "OS currency"
        case .interventionList: "Macs needing intervention"
        case .policyTable: "Policy findings"
        case .profileTable: "Configuration profile failures"
        case .appTable: "App install failures"
        case .cleanupAnalysis: "Cleanup analysis"
        case .timeline: "Historical trends"
        case .recentFailures: "Recent failures"
        case .purchaseCohorts: "Purchase cohorts"
        case .buildingBreakdown: "Buildings"
        case .departmentBreakdown: "Departments"
        case .orgInfo: "Catalog overview"
        }
    }
}

/// The collapsed groups under the dashboard, in reading order. Each is one `<details>`
/// whose summary carries the group's name and its headline numbers; the sections a template
/// lists decide which groups a report has.
enum HtmlDetailGroup: String, CaseIterable {
    case security, patching, devices, policies, trends, failures, breakdowns

    var title: String {
        switch self {
        case .security: "Security and compliance"
        case .patching: "Patching"
        case .devices: "Devices needing intervention"
        case .policies: "Policies and profiles"
        case .trends: "Trends"
        case .failures: "Recent failures"
        case .breakdowns: "Breakdowns"
        }
    }

    /// The sections a group holds, in the order they appear inside it.
    var members: [SectionID] {
        switch self {
        case .security:
            [.securityTiles, .complianceBands, .agentHealth, .exceptionList, .protectAlerts,
             .insightsDrift, .auditEvidence]
        case .patching: [.patchBar, .patchQueue, .osAdoptionChart, .osCurrency]
        case .devices: [.interventionList]
        case .policies: [.policyTable, .profileTable, .appTable, .cleanupAnalysis]
        case .trends: [.timeline]
        case .failures: [.recentFailures]
        case .breakdowns: [.purchaseCohorts, .buildingBreakdown, .departmentBreakdown, .orgInfo]
        }
    }

    /// The element id "Needs attention" links to when the group is in the report.
    var anchor: String { "grp-\(rawValue)" }
}

// MARK: - Assembly

extension HtmlReport {

    /// A section the report left out and why.
    struct Omission {
        let title: String
        let reason: String
    }

    /// The sections the jamf-cli dashboard already shows, and what the report says when the
    /// dashboard is in it. The dashboard is built from the same `pro audit` and inventory
    /// reads, so these three would repeat it.
    static func dashboardDuplicateReason(_ id: SectionID) -> String? {
        switch id {
        case .osAdoptionChart, .auditEvidence, .orgInfo:
            "shown in the Jamf fleet dashboard above"
        default:
            nil
        }
    }

    /// One detail group rendered, and the sections that made it.
    struct RenderedGroup {
        let html: String
        let shown: Set<SectionID>
    }

    /// The whole document for `sections`, in the fixed reading order: header, AI summary,
    /// figures, attention list, dashboard, detail groups, appendix. `sections` decides what is
    /// in the report; their order in the list does not.
    func buildTemplatedHTML(
        outputURL: URL,
        profileName: String,
        sections: [SectionID]
    ) -> String {
        let wanted = Set(sections)
        let inputs = loadInputs(for: wanted)
        var omissions: [Omission] = []

        let dashboard: DashboardState = wanted.contains(.jamfDashboard)
            ? dashboardState() : .absent(nil)
        let dashboardHTML = renderDashboard(dashboard, omissions: &omissions)

        let groups = HtmlDetailGroup.allCases.compactMap {
            renderGroup(
                $0, wanted: wanted, inputs: inputs, outputURL: outputURL,
                dashboardEmbedded: dashboard.isEmbedded, omissions: &omissions)
        }
        let shown = groups.reduce(into: Set<SectionID>()) { $0.formUnion($1.shown) }

        let glance = wanted.contains(.atAGlance) ? buildAtAGlance(inputs) : nil
        if let glance, let reason = glance.omission {
            omissions.append(.init(title: SectionID.atAGlance.title, reason: reason))
        }
        let attention = wanted.contains(.needsAttention)
            ? buildNeedsAttention(inputs, shown: shown) : ""
        var narrative = ""
        if wanted.contains(.aiNarrative), let text = aiNarrative, !text.isEmpty {
            narrative = buildAINarrativeSection(text)
        }
        let appendix = wanted.contains(.auditAppendix)
            ? buildAuditAppendix(inputs, omissions: omissions, glance: glance) : ""

        let parts = [narrative, glance?.html ?? "", attention, dashboardHTML]
            + groups.map(\.html) + [appendix]
        let mainBody = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        return buildDocument(
            outputURL: outputURL, mainBody: mainBody, inputs: inputs,
            profile: profileName.isEmpty ? config.jamfCli?.resolvedProfile ?? "" : profileName,
            glance: glance)
    }

    /// The dashboard section, and a line for the appendix when it is not in the report.
    private func renderDashboard(
        _ state: DashboardState, omissions: inout [Omission]
    ) -> String {
        switch state {
        case .embedded(let html), .notEmbedded(let html):
            return "<section class=\"group-section\">\(html)</section>"
        case .absent(let reason):
            if let reason {
                omissions.append(.init(title: SectionID.jamfDashboard.title, reason: reason))
            }
            return ""
        }
    }

    /// One group: the blocks of its sections that have something to show, under a summary
    /// line. Nil when none do. A section the dashboard repeats is left out and listed.
    private func renderGroup(
        _ group: HtmlDetailGroup,
        wanted: Set<SectionID>,
        inputs: Inputs,
        outputURL: URL,
        dashboardEmbedded: Bool,
        omissions: inout [Omission]
    ) -> RenderedGroup? {
        var parts: [String] = []
        var shown: Set<SectionID> = []
        for id in group.members where wanted.contains(id) {
            if dashboardEmbedded, let reason = Self.dashboardDuplicateReason(id) {
                omissions.append(.init(title: id.title, reason: reason))
                continue
            }
            let block = detailBlock(id, inputs: inputs)
            guard block.isShown else {
                omissions.append(.init(title: id.title, reason: block.omission ?? "empty"))
                continue
            }
            parts.append(block.html)
            shown.insert(id)
        }
        if group == .trends, shown.contains(.timeline) {
            parts.append(buildHistorySection(security: inputs.security, outputURL: outputURL))
        }
        guard !shown.isEmpty else { return nil }

        let summary = groupSummary(group, shown: shown, inputs: inputs)
        let isOpen = expandAll || !openSections.isDisjoint(with: group.members)
        let headline = summary.isEmpty ? "" : " — \(HtmlSectionFormatters.escapeHTML(summary))"
        let html = """
        <section class="group-section">
        <details class="group" id="\(group.anchor)"\(isOpen ? " open" : "")>
          <summary><span class="grp-title">\(HtmlSectionFormatters.escapeHTML(group.title))</span>\
        <span class="grp-sum">\(headline)</span></summary>
          <div class="group-body">
        \(parts.filter { !$0.isEmpty }.joined(separator: "\n"))
          </div>
        </details>
        </section>
        """
        return RenderedGroup(html: html, shown: shown)
    }

    /// The block for one detail section.
    private func detailBlock(_ id: SectionID, inputs: Inputs) -> HtmlBlock {
        switch id {
        case .securityTiles: return buildSecurityControls(inputs)
        case .complianceBands:
            return buildComplianceBands(
                deviceCompliance: inputs.deviceCompliance, computers: inputs.computers)
        case .agentHealth:
            return buildAgentHealth(eaRows: inputs.eaRows, fleet: inputs.totalDevices)
        case .exceptionList: return buildExceptionList()
        case .protectAlerts: return buildProtectAlerts(protectDataDir: protectDir)
        case .insightsDrift: return buildInsightsDrift(protectDataDir: protectDir)
        case .auditEvidence: return buildAuditEvidence(auditFindings: inputs.auditFindings)
        case .patchBar:
            return buildPatchChart(patchStatus: inputs.patchStatus)
        case .patchQueue: return buildPatchQueue(patchStatus: inputs.patchStatus)
        case .osAdoptionChart:
            return buildOSChart(osVersions: inputs.security.filter {
                $0["section"] as? String == "os_version"
            })
        case .osCurrency: return buildOSCurrencySection()
        case .interventionList: return buildInterventionList(computersInventory: inputs.computers)
        case .policyTable: return buildPolicyHealthSection(inputs.policyStatus)
        case .profileTable:
            return buildProfileStatusSection(
                inputs.profileStatus, profileCount: inputs.profileList.count)
        case .appTable: return buildAppStatusSection(inputs.appStatus)
        case .cleanupAnalysis:
            return buildCleanupAnalysis(
                classicPolicies: loadJSONList(kinds: ["policies", "classic-policies"]),
                classicProfiles: inputs.profileList,
                packages: loadJSONList(kinds: ["packages"]),
                scripts: loadJSONList(kinds: ["scripts"]))
        case .timeline: return buildTimelineSection()
        case .recentFailures:
            return buildRecentFailures(
                patchFailures: inputs.patchFailures, updateFailures: inputs.updateFailures)
        case .purchaseCohorts: return buildPurchaseCohorts(computersInventory: inputs.computers)
        case .buildingBreakdown: return buildBuildingBreakdown(computersInventory: inputs.computers)
        case .departmentBreakdown:
            return buildDepartmentBreakdown(computersInventory: inputs.computers)
        case .orgInfo: return buildCatalogSection(counts: inputs.catalogCounts)
        case .aiNarrative, .atAGlance, .needsAttention, .jamfDashboard, .auditAppendix:
            return .omitted("drawn outside the detail groups")
        }
    }

    /// Protect's kind directories sit beside every other snapshot; nil when Protect is off.
    private var protectDir: URL? { config.protect?.isEnabled == true ? dataDir : nil }

    // MARK: Group summary lines

    /// The group's headline numbers, "118 titles behind · 12 under 50%". Empty when the
    /// group's sections carry none.
    func groupSummary(
        _ group: HtmlDetailGroup, shown: Set<SectionID>, inputs: Inputs
    ) -> String {
        let f = HtmlSectionFormatters.self
        var parts: [String] = []
        switch group {
        case .security:
            if shown.contains(.securityTiles), let p0 = inputs.p0 {
                parts.append(f.plural(p0, "P0 gap"))
            }
            if shown.contains(.auditEvidence) {
                parts.append(f.plural(inputs.auditFindings.count, "audit finding"))
            }
            if shown.contains(.agentHealth), let low = lowestAgentCoverage(inputs) {
                parts.append("\(low.name) on \(String(format: "%.0f%%", low.pct))")
            }
            if shown.contains(.exceptionList) {
                parts.append(f.plural(config.exceptions?.count ?? 0, "exception"))
            }
        case .patching:
            let behind = inputs.patchStatus.filter { (asInt($0["on_other"]) ?? 0) > 0 }.count
            let weak = inputs.patchStatus.filter { (patchTitlePct($0) ?? 100) < 50 }.count
            if !inputs.patchStatus.isEmpty {
                parts.append(f.plural(behind, "title") + " behind")
                parts.append("\(weak) under 50%")
            }
        case .devices:
            let days = config.thresholds?.resolvedStaleDays ?? 30
            parts.append("\(f.plural(staleComputers(inputs.computers).count, "Mac")) idle "
                + "over \(days) days")
        case .policies:
            if shown.contains(.policyTable) {
                let n = (inputs.policyStatus.first?["config_findings"] as? [Any])?.count ?? 0
                parts.append(f.plural(n, "policy finding"))
            }
            if shown.contains(.profileTable) {
                parts.append(f.plural(inputs.profileStatus?.failures.count ?? 0, "profile")
                    + " failing")
            }
            if shown.contains(.appTable) {
                parts.append(f.plural(inputs.appStatus?.failures.count ?? 0, "app") + " failing")
            }
        case .trends:
            if let latest = inputs.summaries.last {
                parts.append("\(f.plural(inputs.summaries.count, "day")) of history, "
                    + "latest \(latest.date)")
            }
        case .failures:
            parts.append("\(inputs.patchFailures.count) patch · "
                + "\(f.plural(inputs.updateFailures.count, "update failure"))")
        case .breakdowns:
            parts = group.members.filter { shown.contains($0) }.map { $0.title.lowercased() }
        }
        return parts.joined(separator: " · ")
    }

    /// The configured security agent with the lowest coverage, as a share of the fleet.
    func lowestAgentCoverage(_ inputs: Inputs) -> (name: String, pct: Double)? {
        agentCoverage(inputs).min { $0.pct < $1.pct }
    }

    /// Each configured agent's coverage over the fleet; an agent no Mac reports has none.
    func agentCoverage(_ inputs: Inputs) -> [(name: String, pct: Double)] {
        guard let rows = inputs.eaRows, !rows.isEmpty else { return [] }
        let total = inputs.totalDevices > 0
            ? inputs.totalDevices : MSCPComplianceService.allDistinctDeviceIds(in: rows).count
        return SecurityAgentCoverage.compute(rows: rows, agents: config.securityAgents ?? [])
            .compactMap { agent -> (name: String, pct: Double)? in
                guard agent.reporting > 0,
                      let pct = SecurityAgentCoverage.percent(
                        installed: agent.installed, fleet: total) else { return nil }
                return (agent.name, pct)
            }
    }
}
