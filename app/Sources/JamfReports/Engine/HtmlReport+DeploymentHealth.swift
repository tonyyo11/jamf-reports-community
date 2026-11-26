import Foundation

extension HtmlReport {
    /// One "Needs attention" sentence per source while a current snapshot has a row at a level.
    /// A snapshot no longer current is not a current warning; the section says "as of".
    static func deploymentSentences(_ inputs: Inputs) -> [String] {
        let levels = inputs.deploymentLevels
        return DeploymentHealth.Source.allCases.compactMap { source in
            guard case .rows(let rows, nil, _) = inputs.deployments[source] ?? .notCollected
            else { return nil }
            let count = DeploymentHealth.atLevel(rows, levels: levels).count
            guard count > 0 else { return nil }
            switch source {
            case .appInstallers:
                return count == 1
                    ? "1 App Installers deployment has failed installs on \(levels.warning)% or more of its Macs."
                    : "\(count) App Installers deployments have failed installs on \(levels.warning)% or more of their Macs."
            case .patchPolicy:
                return count == 1
                    ? "1 patch policy has failed on \(levels.warning)% or more of its Macs."
                    : "\(count) patch policies have failed on \(levels.warning)% or more of their Macs."
            }
        }
    }

    /// The rows at a level for each source, critical first, capped; each source not listed
    /// says why.
    func buildDeploymentHealth(_ inputs: Inputs) -> HtmlBlock {
        let levels = inputs.deploymentLevels
        let states = DeploymentHealth.Source.allCases.map { ($0, inputs.deployments[$0] ?? .notCollected) }
        guard states.contains(where: { $0.1 != .notCollected }) else {
            return .omitted("no App Installers deployment or patch policy snapshot")
        }
        let f = HtmlSectionFormatters.self
        var body = "<p class=\"block-note\">" + f.escapeHTML(
            "Warning at \(levels.warning)% failed, critical at \(levels.critical)%, judged "
                + "with at least \(DeploymentHealth.minimumInScope) Macs in scope.") + "</p>"
        for (source, state) in states {
            body += "<h3>\(f.escapeHTML(source.displayName))</h3>"
            if let text = DeploymentHealth.stateText(state) {
                body += "<p class=\"empty\">\(f.escapeHTML(text))</p>"
                continue
            }
            if case .rows(_, let asOf?, _) = state {
                body += "<p class=\"block-note\">" + f.escapeHTML(
                    "As of \(ISO8601Time.string(asOf)), no longer current.") + "</p>"
            }
            if case .rows(_, _, let leftOut) = state, leftOut > 0 {
                body += "<p class=\"block-note\">"
                    + f.escapeHTML(DeploymentHealth.leftOutText(leftOut) + ".") + "</p>"
            }
            let atLevel = DeploymentHealth.atLevel(state.rows, levels: levels)
            guard !atLevel.isEmpty else {
                body += "<p class=\"empty\">None at a level.</p>"
                continue
            }
            let rows = atLevel.map { entry -> [String] in
                [entry.row.displayName,
                 DeploymentHealth.judgementText(entry.judgement),
                 "\(entry.failed) of \(entry.inScope) Macs",
                 DeploymentHealth.shareText(entry.row, levels: levels, format: config.percentFormat)]
            }
            body += f.renderCappedTable(
                headers: ["Name", "Level", "Failed", "Failed %"], rows: rows,
                maxRows: f.maxFailureRows, expanded: expandAll)
        }
        return .shown(f.block(id: "deployment-health", title: "Deployments and patch policies",
                              body: body))
    }
}
