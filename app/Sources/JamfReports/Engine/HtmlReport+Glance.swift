import Foundation

// MARK: - HtmlReport+Glance
//
// The top of the report: six figures with their change over about a week, and a short list
// of what needs attention. A reader who stops here has the picture; everything below is for
// looking a number up.

extension HtmlReport {

    /// The "At a glance" section, and what the header and appendix take from it.
    struct Glance {
        let html: String
        /// Why there is no section; nil when there is one.
        let omission: String?
        /// The date of the summary the figures come from.
        let asOf: String?
        /// The date of the summary the changes compare with.
        let since: String?
        /// Figures the summary had no value for, so they are not drawn.
        let missing: [String]
    }

    /// One figure's definition: how to read it from a summary and how it moves.
    private struct FigureSpec {
        let label: String
        let unit: String
        let polarity: FleetInsightInput.Polarity
        let read: (DailySummary) -> Double?
        let format: (Double) -> String
        /// False when two summaries measured the figure differently, so a difference between
        /// them would be the definition changing, not the fleet.
        let comparable: (DailySummary, DailySummary) -> Bool
    }

    private func figureSpecs(current: DailySummary) -> [FigureSpec] {
        func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
        func always(_: DailySummary, _: DailySummary) -> Bool { true }
        let staleDays = config.thresholds?.resolvedStaleDays ?? 30
        return [
            FigureSpec(label: "Security score", unit: "%", polarity: .higherIsBetter,
                       read: { $0.securityScore }, format: { String(format: "%.1f", $0) },
                       comparable: { $0.securityScoreBasis == $1.securityScoreBasis }),
            FigureSpec(label: "P0 security gaps", unit: "", polarity: .lowerIsBetter,
                       read: { $0.actionItemsP0.map(Double.init) },
                       format: { String(format: "%.0f", $0) }, comparable: always),
            FigureSpec(label: "Patch compliance", unit: "%", polarity: .higherIsBetter,
                       read: { $0.patchPct }, format: percent,
                       comparable: { $0.patchPctBasis == $1.patchPctBasis }),
            FigureSpec(label: "On current macOS", unit: "%", polarity: .higherIsBetter,
                       read: { $0.osCurrentPct }, format: percent, comparable: always),
            FigureSpec(label: "Stale Macs (>\(staleDays) days)", unit: "",
                       polarity: .lowerIsBetter, read: { $0.staleCount.map(Double.init) },
                       format: { String(format: "%.0f", $0) }, comparable: always),
            FigureSpec(label: complianceLabel(isProxy: current.complianceIsProxy), unit: "%",
                       polarity: .higherIsBetter, read: { $0.compliancePct }, format: percent,
                       comparable: { $0.complianceIsProxy == $1.complianceIsProxy }),
        ]
    }

    /// The compliance figure's name: the configured benchmark label, or the generic
    /// "Compliance Benchmark"; "Compliance (4-control proxy)" when the summary's figure is the
    /// proxy built from the four security controls, not a benchmark's failure count.
    func complianceLabel(isProxy: Bool?) -> String {
        if isProxy == true { return "Compliance (4-control proxy)" }
        let label = config.compliance?.baselineLabel?.trimmingCharacters(in: .whitespaces) ?? ""
        return label.isEmpty ? TrendSeries.Metric.compliance.displayLabel : label
    }

    /// The six figures from the newest daily summary, each against the summary about seven
    /// days earlier (`FleetReportEmitter.priorSummary`, the lookback the fleet report uses;
    /// the caption names the date it found). The change is worded as the Trends screen does.
    func buildAtAGlance(_ inputs: Inputs) -> Glance {
        guard let current = inputs.summaries.last else {
            return Glance(html: "", omission: "no daily summary yet; a collect writes one",
                          asOf: nil, since: nil, missing: [])
        }
        let prior = FleetReportEmitter.priorSummary(inputs.summaries, lookbackDays: 7)
        var tiles: [String] = []
        var missing: [String] = []
        for spec in figureSpecs(current: current) {
            guard let value = spec.read(current) else {
                missing.append(spec.label)
                continue
            }
            tiles.append(glanceTile(spec, value: value, current: current, prior: prior))
        }
        let f = HtmlSectionFormatters.self
        let caption = prior.map { "As of \(current.date). Changes compare with \($0.date)." }
            ?? "As of \(current.date). No earlier summary to compare with."
        let html = """
        <section class="summary-block" id="at-a-glance">
          <h2>At a glance</h2>
          <p class="glance-note">\(f.escapeHTML(caption))</p>
          <div class="glance-grid">
        \(tiles.joined(separator: "\n"))
          </div>
        </section>
        """
        return Glance(
            html: tiles.isEmpty ? "" : html,
            omission: tiles.isEmpty ? "the daily summary has none of the six figures" : nil,
            asOf: current.date, since: prior?.date, missing: missing)
    }

    private func glanceTile(
        _ spec: FigureSpec, value: Double, current: DailySummary, prior: DailySummary?
    ) -> String {
        let f = HtmlSectionFormatters.self
        var changeClass = "none"
        var changeText = "No earlier figure"
        var was = ""
        if let prior, let before = spec.read(prior) {
            if spec.comparable(current, prior) {
                let change = TrendChange(
                    unit: spec.unit, polarity: spec.polarity, first: before, last: value)
                was = "was \(spec.format(before))"
                switch change.verdict {
                case _ where change.direction == .flat:
                    changeClass = "flat"
                    changeText = "No change"
                case .better:
                    changeClass = "better"
                    changeText = "\(change.pillText) · better"
                case .worse:
                    changeClass = "worse"
                    changeText = "\(change.pillText) · worse"
                case .neutral:
                    changeClass = "flat"
                    changeText = change.pillText
                }
            } else {
                changeText = "Not comparable with the earlier figure"
            }
        }
        let wasHTML = was.isEmpty ? "" : "<span class=\"glance-was\">\(f.escapeHTML(was))</span>"
        return """
            <div class="glance-tile">
              <div class="glance-label">\(f.escapeHTMLBreakable(spec.label))</div>
              <div class="glance-value">\(f.escapeHTML(spec.format(value)))</div>
              <div class="glance-change \(changeClass)">\(f.escapeHTML(changeText))\(wasHTML)</div>
            </div>
        """
    }

    // MARK: - Needs attention

    /// Block anchors a "Needs attention" line can link to.
    private static let attentionAnchors: [SectionID: String] = [
        .securityTiles: "security-controls", .agentHealth: "agent-health",
        .patchQueue: "patch-queue", .interventionList: "intervention-list",
        .profileTable: "profile-status", .appTable: "app-status",
        .recentFailures: "recent-failures",
    ]

    /// Where a line about `id` links: its own block when the report has it, else its group
    /// when the report has that, else nowhere. A link never points at something absent.
    private func attentionAnchor(
        _ id: SectionID, group: HtmlDetailGroup, shown: Set<SectionID>
    ) -> String? {
        if shown.contains(id), let anchor = Self.attentionAnchors[id] { return anchor }
        return group.members.contains(where: shown.contains) ? group.anchor : nil
    }

    /// One sentence per rule, each only while its count is above zero:
    /// - Macs stale under the stale rule (`thresholds.stale_device_days`, `stale_basis`),
    /// - P0 security gaps (FileVault, SIP or Firewall off at the `fail` level),
    /// - patch titles under 50% on the latest version,
    /// - configuration profiles and apps with install errors,
    /// - devices with failed patch or software update runs,
    /// - security agents installed on fewer than every Mac.
    func attentionItems(
        _ inputs: Inputs, shown: Set<SectionID>
    ) -> [(text: String, anchor: String?)] {
        let latest = inputs.summaries.last
        let rule = config.staleRule
        var items: [(text: String, anchor: String?)] = []
        func add(_ id: SectionID, _ group: HtmlDetailGroup, _ text: String) {
            items.append((text, attentionAnchor(id, group: group, shown: shown)))
        }

        // The figure the "At a glance" tile shows, so the two cannot disagree at the top; the
        // computers snapshot stands in when the summary has no count.
        let stale = latest?.staleCount ?? (inputs.computers.isEmpty ? 0 : inputs.staleMacCount)
        if stale > 0 {
            add(.interventionList, .devices, Self.staleSentence(stale, rule: rule))
        }
        let p0 = inputs.p0 ?? 0
        if p0 > 0 {
            add(.securityTiles, .security, p0 == 1
                ? "1 P0 security gap needs action: FileVault, SIP or Firewall is off."
                : "\(p0) P0 security gaps need action: FileVault, SIP or Firewall is off.")
        }
        let weak = inputs.patchStatus.filter { (patchTitlePct($0) ?? 100) < 50 }.count
        if weak > 0 {
            add(.patchQueue, .patching, weak == 1
                ? "1 patch title is under 50% on its latest version."
                : "\(weak) patch titles are under 50% on their latest version.")
        }
        let profiles = inputs.profileStatus?.failures.count ?? 0
        if profiles > 0 {
            add(.profileTable, .policies, profiles == 1
                ? "1 configuration profile is failing to install on devices."
                : "\(profiles) configuration profiles are failing to install on devices.")
        }
        let apps = inputs.appStatus?.failures.count ?? 0
        if apps > 0 {
            add(.appTable, .policies, apps == 1
                ? "1 app is failing to install on devices."
                : "\(apps) apps are failing to install on devices.")
        }
        let runs = inputs.patchFailures.count + inputs.updateFailures.count
        if runs > 0 {
            add(.recentFailures, .failures, runs == 1
                ? "1 device has a failed patch or software update run."
                : "\(runs) devices have failed patch or software update runs.")
        }
        let partial = agentCoverage(inputs).filter { $0.pct < 100 }
        if !partial.isEmpty {
            let list = partial.map { "\($0.name) \(String(format: "%.1f%%", $0.pct))" }
            add(.agentHealth, .security,
                "Security agents are not on every Mac: \(list.joined(separator: ", ")).")
        }
        return items
    }

    /// "3 Macs have not checked in for more than 30 days." On the default basis, the check-in
    /// alone; otherwise the dates the rule counts.
    static func staleSentence(_ count: Int, rule: StaleRule) -> String {
        let mac = count == 1 ? "1 Mac has" : "\(count) Macs have"
        if rule.usesDefaultBasis { return "\(mac) not checked in for more than \(rule.days) days." }
        return "\(mac) gone more than \(rule.days) days without a \(rule.basisPhrase)."
    }

    /// The "Needs attention" section: a sentence per rule that fires, each a link to the part
    /// of the report that lists it, or a plain line when the report has no such part.
    func buildNeedsAttention(_ inputs: Inputs, shown: Set<SectionID>) -> String {
        let f = HtmlSectionFormatters.self
        let items = attentionItems(inputs, shown: shown)
        let body: String
        if items.isEmpty {
            body = "<p class=\"attention-clear\">Nothing needs attention right now.</p>"
        } else {
            let lis = items.map { item -> String in
                let text = f.escapeHTML(item.text)
                guard let anchor = item.anchor else { return "<li>\(text)</li>" }
                return "<li><a href=\"#\(f.escapeHTML(anchor))\">\(text)</a></li>"
            }.joined(separator: "\n")
            body = "<ul class=\"attention-list\">\n\(lis)\n</ul>"
        }
        return """
        <section class="summary-block" id="needs-attention">
          <h2>Needs attention</h2>
          \(body)
        </section>
        """
    }
}
