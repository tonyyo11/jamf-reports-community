import Foundation

extension CoreDashboard {
    /// App Installers deployments and patch policies, judged by `DeploymentHealth` against the
    /// organization's levels: a section per source, every source state in the card's words.
    func writeDeploymentHealth() throws {
        let levels = config.thresholds?.resolvedDeploymentLevels ?? .defaults
        let states = DeploymentHealth.load(
            dataDir: dataDir, now: now, maxAgeHours: config.jamfCli?.resolvedMaxCacheAgeHours)
        try requireDeploymentData(states)

        let ws = workbook.addSheet(SheetID.deploymentHealth.rawValue)
        var row = ws.writeSheetHeader(
            title: t("Deployment Health"),
            subtitle: "Warning at \(levels.warning)% failed, critical at \(levels.critical)% | "
                + "Judged with at least \(DeploymentHealth.minimumInScope) Macs in scope | "
                + "Generated: \(ISO8601Time.string(now))",
            ncols: 11)
        ws.setColumnWidth(0, 0, 34)
        ws.setColumnWidth(1, 10, 14)
        for source in DeploymentHealth.Source.allCases {
            row = writeDeploymentSection(ws, source, states[source] ?? .notCollected,
                                         levels: levels, row: row)
            row += 1
        }
    }

    private func writeDeploymentSection(
        _ ws: Worksheet, _ source: DeploymentHealth.Source, _ state: DeploymentHealth.SourceState,
        levels: DeploymentHealth.Levels, row start: Int
    ) -> Int {
        var row = start
        ws.write(source.displayName, row: row, col: 0, format: .header)
        if case .rows(_, let asOf?, _) = state {
            ws.write("As of \(ISO8601Time.string(asOf)), no longer current", row: row, col: 1,
                     format: .yellow)
        }
        row += 1
        if let text = DeploymentHealth.stateText(state) {
            let warns: Bool
            switch state {
            case .unreadable, .failed: warns = true
            default: warns = false
            }
            ws.write(text, row: row, col: 0, format: warns ? .yellow : .cell)
            if case .rows(_, _, let leftOut) = state, leftOut > 0 {
                ws.write(DeploymentHealth.leftOutText(leftOut), row: row + 1, col: 0,
                         format: .yellow)
                return row + 2
            }
            return row + 1
        }
        let headers = source == .appInstallers
            ? ["Name", "Enabled", "Macs in scope", "Failed", "Failed %", "Level",
               "Assigned to another deployment", "Deployed version", "Latest version", "Version"]
            : ["Name", "Enabled", "Macs in scope", "Completed", "Deferred", "Pending", "Failed",
               "Failed %", "Level", "Target version", "Patch title"]
        for (col, header) in headers.enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        let ordered = DeploymentHealth.tabOrder(state.rows, levels: levels)
        var wroteDisabledHeading = false
        for entry in ordered {
            let judgement = DeploymentHealth.judge(entry, levels: levels)
            if judgement == .notJudged, !wroteDisabledHeading {
                ws.write("Not enabled", row: row, col: 0, format: .header)
                row += 1
                wroteDisabledHeading = true
            }
            writeDeploymentRow(ws, entry, judgement: judgement, row: row)
            row += 1
        }
        if case .rows(_, _, let leftOut) = state, leftOut > 0 {
            ws.write(DeploymentHealth.leftOutText(leftOut), row: row, col: 0, format: .yellow)
            row += 1
        }
        return row
    }

    private func writeDeploymentRow(
        _ ws: Worksheet, _ entry: DeploymentHealth.Row, judgement: DeploymentHealth.Judgement,
        row: Int
    ) {
        let format: CellFormat = judgement == .critical ? .red
            : judgement == .warning ? .yellow : .cell
        let pctFormat: CellFormat = judgement == .critical ? .pctRed
            : judgement == .warning ? .pctYellow : .pct
        var col = 0
        func put(_ text: String?) {
            ws.write(text ?? "", row: row, col: col, format: format); col += 1
        }
        func put(_ number: Int?) {
            if let number { ws.write(number, row: row, col: col, format: format) }
            col += 1
        }
        put(entry.displayName)
        put(entry.enabled.map { $0 ? "Yes" : "No" })
        put(entry.inScope)
        if entry.source == .patchPolicy {
            put(entry.completed)
            put(entry.deferred)
            put(entry.pending)
        }
        put(entry.failed)
        if let share = DeploymentHealth.share(entry) {
            ws.write(share, row: row, col: col, format: pctFormat)
        }
        col += 1
        put(DeploymentHealth.judgementText(judgement))
        if entry.source == .appInstallers {
            put(entry.assignedElsewhere)
            put(entry.deployedVersion.map(ConfigSchema.displayText))
            put(entry.latestVersion.map(ConfigSchema.displayText))
            put(DeploymentHealth.versionText(DeploymentHealth.versionState(entry)))
        } else {
            put(entry.targetVersion.map(ConfigSchema.displayText))
            put(entry.softwareTitle.map(ConfigSchema.displayText))
        }
    }

    /// Skipped only when neither source was ever collected. An unreadable snapshot is named in
    /// the run log; the tab still says so in its section.
    private func requireDeploymentData(_ states: [DeploymentHealth.Source: DeploymentHealth.SourceState]) throws {
        for (source, state) in states where state == .unreadable {
            let line = "[warn] Deployment Health: the \(source.kind) snapshot could not be read."
            if let onLine {
                onLine(.init(timestamp: Date(), level: .warn, text: line))
            } else {
                print("  " + line)
            }
        }
        if states.values.allSatisfy({ $0 == .notCollected }) {
            throw CoreDashboardError.noCachedData(
                names: DeploymentHealth.Source.allCases.map(\.kind))
        }
    }
}
