import Foundation

// MARK: - HtmlReport+Appendix
//
// The audit appendix: where the numbers came from, what they mean, which security policy
// graded them, and what the report left out. Collapsed by default; an auditor opens it, a
// reader of the summary never needs to.

extension HtmlReport {

    /// The appendix as one collapsed group. `omissions` is every section the report left out
    /// and why; `glance` carries the figures the daily summary had no value for.
    func buildAuditAppendix(
        _ inputs: Inputs, omissions: [Omission], glance: Glance?
    ) -> String {
        let f = HtmlSectionFormatters.self
        let notIncluded = notIncludedLines(omissions: omissions, glance: glance)
        let sources = dataSourceRows(inputs)
        let headline = "\(f.plural(sources.count, "data source")) · "
            + "\(notIncluded.count) not included"
        let body = [
            f.block(id: "appendix-sources", title: "Data sources", body: sources.isEmpty
                ? "<p class=\"empty\">No snapshots were read.</p>"
                : f.renderTable(headers: ["Source", "Newest snapshot"], rows: sources)),
            f.block(id: "appendix-definitions", title: "Metric definitions",
                    body: definitionList(inputs, glance: glance)),
            f.block(id: "appendix-policy", title: "Security policy in effect",
                    body: securityPolicyTable()),
            f.block(id: "appendix-omitted", title: "Not included in this report",
                    body: f.renderList(items: notIncluded)),
        ].joined(separator: "\n")
        return """
        <section class="group-section">
        <details class="group" id="audit-appendix"\(expandAll ? " open" : "")>
          <summary><span class="grp-title">Audit appendix</span>\
        <span class="grp-sum"> — \(f.escapeHTML(headline))</span></summary>
          <div class="group-body">
        \(body)
          </div>
        </details>
        </section>
        """
    }

    /// One row per snapshot the report read: its name and the date the newest file stands for.
    private func dataSourceRows(_ inputs: Inputs) -> [[String]] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HH:mm"
        var seen: Set<String> = []
        return inputs.sources
            .filter { seen.insert($0.kind).inserted }
            .sorted { $0.label < $1.label }
            .map { source in
                let date = source.date.map { day.string(from: $0) } ?? "date unknown"
                // A daily summary stands for its whole day.
                let text = source.kind == "snapshots/summaries"
                    ? String(date.prefix(10)) : date
                return ["\(source.label) (\(source.kind))", text]
            }
    }

    /// What every figure in the report means, written from the settings in force.
    private func definitionList(_ inputs: Inputs, glance: Glance?) -> String {
        let f = HtmlSectionFormatters.self
        let staleDays = config.thresholds?.resolvedStaleDays ?? 30
        let factorText = config.resolvedScoreFactors.map {
            "\($0.label(staleDays: staleDays)) \(SecurityScoreFactor.weightText($0.weight))"
        }.joined(separator: ", ")
        let compliance: String
        switch inputs.summaries.last?.complianceIsProxy {
        case true?:
            compliance = "The share of Macs with none of the four security controls failing. "
                + "A proxy: no benchmark failure count is configured."
        case false?:
            compliance = "The share of Macs with no failures against the primary benchmark "
                + "baseline."
        case nil:
            compliance = "Not available in the daily summary."
        }
        let comparison = glance?.since.map {
            "Each change compares the newest daily summary with the one dated \($0), about "
                + "seven days earlier. A figure measured differently then and now shows no change."
        } ?? "There is no earlier daily summary to compare with."
        let entries: [(String, String)] = [
            ("Stale", "A Mac with no check-in for \(staleDays) days or more "
                + "(thresholds.stale_device_days). At a glance counts from the daily summary; the "
                + "lists count from the computers snapshot."),
            ("P0 security gap", "A Mac measured off for FileVault, SIP or Firewall at the Fail "
                + "level, counted once per control."),
            ("P1 security gap", "A Mac measured off for Gatekeeper at the Fail level."),
            ("Security score", "A weighted share of the Macs that pass each factor. Factors and "
                + "weights: \(factorText). A factor with no data is dropped and the rest "
                + "renormalised."),
            ("Patch compliance", "Devices on the latest version of their patch title, over all "
                + "devices on tracked titles. Not an average of the titles' percentages."),
            ("On current macOS", "A Mac running the newest release of its own major version, "
                + "per the SOFA feed."),
            ("Compliance", compliance),
            ("Change", comparison),
        ]
        let items = entries.map { term, text in
            "<dt>\(f.escapeHTML(term))</dt><dd>\(f.escapeHTML(text))</dd>"
        }.joined(separator: "\n")
        return "<dl class=\"definitions\">\n\(items)\n</dl>"
    }

    /// Each control's level under `security_policy`, the hardware rule and where the score
    /// factors came from. A level other than Fail is the reader's cue that a gap is not
    /// counted the way the report's headings might suggest.
    private func securityPolicyTable() -> String {
        let policy = config.resolvedSecurityPolicy
        var rows = SecurityControl.allCases.map {
            [$0.displayName, policy.level(for: $0).displayName]
        }
        rows.append([
            "FileVault off on a hardware-encrypted Mac",
            policy.usesHardwareRule
                ? (policy.fileVaultOffHardwareEncrypted?.displayName ?? "")
                : "Same as FileVault",
        ])
        rows.append([
            "Score factors",
            policy.scoreFactors == nil ? "Defaults" : "Set in security_policy.score_factors",
        ])
        return HtmlSectionFormatters.renderTable(headers: ["Setting", "Level"], rows: rows)
    }

    /// The report's list of what it left out: every omitted section with its reason, the
    /// figures the summary could not fill, and the device inventory, which is never here.
    private func notIncludedLines(omissions: [Omission], glance: Glance?) -> [String] {
        var lines = omissions.map { "\($0.title) — \($0.reason)" }
        for label in glance?.missing ?? [] {
            lines.append("At a glance: \(label) — the daily summary has no value for it")
        }
        lines.append("Device inventory — full device lists are in the workbook, not in an HTML "
            + "report that is forwarded")
        return lines
    }
}
