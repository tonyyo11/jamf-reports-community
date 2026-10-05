import Foundation

// MARK: - HtmlReport+Sections
//
// The detail-section renderers. Each is a pure instance method that takes the snapshot rows
// `HtmlReport.loadInputs` read and returns an `HtmlBlock`: markup for a block inside a detail
// group, or the reason the section left none (it is listed in the audit appendix).
//
// All user-controlled strings MUST go through `HtmlSectionFormatters.escapeHTML(_:)`
// before interpolation. No exceptions.

extension HtmlReport {

    // MARK: - 0. aiNarrative (F3 — GUI-generate only)

    /// AI-generated executive narrative, rendered above the figures. Model output is
    /// untrusted dynamic text — always escaped.
    func buildAINarrativeSection(_ narrative: String) -> String {
        let f = HtmlSectionFormatters.self
        return """
        <section class="summary-block" id="ai-narrative">
          <h2>AI Fleet Summary</h2>
          <p>\(f.escapeHTML(narrative))</p>
          <p class="ai-note">AI-generated summary — verify against the metrics below.</p>
        </section>
        """
    }

    /// The security sentence of the Security and compliance group, worded from the counts its
    /// tiles show (`SecurityFleetCounts`, under the workspace's security policy). A gap is a Mac
    /// measured off for a control at the `fail` level; the counts are per control, so a Mac
    /// missing two controls appears in both. device-compliance rows carry no failure count,
    /// so they cannot say how many Macs meet a requirement.
    static func securityGapSentence(_ fleet: SecurityFleetCounts?) -> String {
        guard let fleet, fleet.totalDevices > 0 else {
            return "No security control counts are available in the current snapshot."
        }
        let evaluated = SecurityControl.allCases.filter {
            guard let control = fleet.controls[$0] else { return false }
            return control.level != .ignore
        }
        guard !evaluated.isEmpty else {
            return "No security control is counted under this workspace's security policy."
        }
        let gaps = evaluated.compactMap { control -> String? in
            let n = fleet.controls[control]?.fail ?? 0
            guard n > 0 else { return nil }
            return "\(CompliancePostureService.label(control)) off on \(n) Mac\(n == 1 ? "" : "s")"
        }
        var sentence = gaps.isEmpty
            ? "No Mac has a gap in " + evaluated.map(CompliancePostureService.label)
                .joined(separator: ", ") + "."
            : "Security gaps to remediate: " + gaps.joined(separator: ", ") + "."
        let unreported = evaluated.reduce(0) { $0 + (fleet.controls[$1]?.notReported ?? 0) }
        if unreported > 0 {
            sentence += " \(unreported) control value\(unreported == 1 ? " was" : "s were") not "
                + "reported by Jamf and not counted as gaps."
        }
        return sentence
    }

    // MARK: - recentFailures

    /// The `update-device-failures` snapshot is one envelope (`[{error_devices, failed_plans,
    /// ...}]`, either list `null` when empty), not a list of failures. This returns its
    /// failure rows; an element carrying neither list is already a row and passes through.
    static func updateFailureRows(from snapshot: [[String: Any]]) -> [[String: Any]] {
        snapshot.flatMap { element -> [[String: Any]] in
            guard element["error_devices"] != nil || element["failed_plans"] != nil else {
                return [element]
            }
            return (element["error_devices"] as? [[String: Any]] ?? [])
                + (element["failed_plans"] as? [[String: Any]] ?? [])
        }
    }

    private static func ageRank(_ daysAgo: Int) -> Int { daysAgo < 0 ? Int.max : daysAgo }

    /// Device-level patch and update failures, newest first: ten shown, the rest behind
    /// "Show all". A row with no readable date is not the newest; it sorts last.
    func buildRecentFailures(
        patchFailures: [[String: Any]],
        updateFailures: [[String: Any]]
    ) -> HtmlBlock {
        struct FailureRow {
            let device: String
            let serial: String
            let title: String
            let source: String
            let daysAgo: Int
        }

        var rows: [FailureRow] = []

        for item in patchFailures {
            let device = item["device"] as? String ?? item["name"] as? String ?? ""
            let serial = item["serial"] as? String ?? item["serial_number"] as? String ?? ""
            let title = item["policy"] as? String ?? item["title"] as? String ?? ""
            let date = item["status_date"] as? String ?? ""
            rows.append(FailureRow(
                device: device, serial: serial, title: title,
                source: "Patch", daysAgo: daysAgo(from: date)
            ))
        }

        for item in updateFailures {
            let device = item["name"] as? String ?? ""
            let serial = item["serial"] as? String ?? ""
            let title = item["version"] as? String ?? item["product_key"] as? String ?? ""
            let date = item["updated"] as? String ?? item["last_event"] as? String ?? ""
            rows.append(FailureRow(
                device: device, serial: serial, title: title,
                source: "Update", daysAgo: daysAgo(from: date)
            ))
        }

        guard !rows.isEmpty else { return .omitted("no patch or update failures in the snapshots") }

        let tableRows = rows.sorted { Self.ageRank($0.daysAgo) < Self.ageRank($1.daysAgo) }
            .map { row -> [String] in
                let daysLabel = row.daysAgo >= 0 ? "\(row.daysAgo)d ago" : "—"
                return [row.device, row.serial, row.title, row.source, daysLabel]
            }

        return .shown(HtmlSectionFormatters.block(
            id: "recent-failures",
            title: "Recent failures (\(rows.count))",
            body: HtmlSectionFormatters.renderCappedTable(
                headers: ["Device", "Serial", "Title", "Source", "Age"],
                rows: tableRows, expanded: expandAll)))
    }

    // MARK: - interventionList

    /// The Macs that are stale under the stale rule (`thresholds.stale_device_days` and
    /// `stale_basis`), oldest first, each with its stale age. A Mac without a date the rule
    /// counts has never had it, so it is the oldest of all.
    func staleComputers(
        _ computers: [[String: Any]], now: Date = Date()
    ) -> [(item: [String: Any], age: StaleAge)] {
        let rule = config.staleRule
        return computers.compactMap { item -> (item: [String: Any], age: StaleAge)? in
            let dates = ComputerDates(item: item)
            let inputs = StaleInputs(
                checkIn: dates.checkIn, inventory: dates.inventory, contact: dates.contact,
                carriesDates: true)
            guard let age = rule.age(of: inputs, now: now), age > .days(rule.days)
            else { return nil }
            return (item, age)
        }.sorted { $0.age > $1.age }
    }

    /// Macs that are stale under the stale rule, with the oldest counted date's age and the
    /// primary user.
    func buildInterventionList(computersInventory: [[String: Any]]) -> HtmlBlock {
        let rule = config.staleRule
        guard !computersInventory.isEmpty else { return .omitted("no computers snapshot") }
        let stale = staleComputers(computersInventory)
        guard !stale.isEmpty else {
            return .omitted(
                "no Mac has gone more than \(rule.days) days without a \(rule.basisPhrase)")
        }
        let tableRows = stale.map { entry -> [String] in
            [inventoryName(entry.item), inventorySerial(entry.item),
             inventoryUsername(entry.item), entry.age.days.map(String.init) ?? "never"]
        }
        return .shown(HtmlSectionFormatters.block(
            id: "intervention-list",
            title: "Macs with no \(rule.basisPhrase) for more than \(rule.days) days "
                + "(\(stale.count))",
            body: HtmlSectionFormatters.renderCappedTable(
                headers: ["Device", "Serial", "Primary User", "Days Since \(rule.basisHeading)"],
                rows: tableRows, expanded: expandAll)))
    }

    // MARK: - patchQueue

    /// A patch title's share of devices on its latest version: the row's own
    /// `compliance_pct` ("83%") when it reads, else `on_latest` over `total`. Nil when
    /// neither does, so a title with no devices is not a 0%.
    func patchTitlePct(_ item: [String: Any]) -> Double? {
        if let text = item["compliance_pct"] as? String,
           let value = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
            return value
        }
        guard let total = asInt(item["total"]), total > 0,
              let onLatest = asInt(item["on_latest"]) else { return nil }
        return Double(onLatest) / Double(total) * 100
    }

    /// Patch titles with devices on another version, largest gap first.
    func buildPatchQueue(patchStatus: [[String: Any]]) -> HtmlBlock {
        guard !patchStatus.isEmpty else { return .omitted("no patch-status snapshot") }
        let pending = patchStatus.filter { (asInt($0["on_other"]) ?? 0) > 0 }
            .sorted { (asInt($0["on_other"]) ?? 0) > (asInt($1["on_other"]) ?? 0) }
        guard !pending.isEmpty else {
            return .omitted("every tracked patch title is on its latest version")
        }
        let tableRows = pending.map { item -> [String] in
            [item["title"] as? String ?? "", item["latest"] as? String ?? "—",
             "\(asInt(item["on_other"]) ?? 0)", "\(asInt(item["total"]) ?? 0)",
             item["compliance_pct"] as? String ?? "—"]
        }
        return .shown(HtmlSectionFormatters.block(
            id: "patch-queue",
            title: "Patch titles behind (\(pending.count))",
            body: HtmlSectionFormatters.renderCappedTable(
                headers: ["Title", "Latest Version", "Behind", "Total", "Compliance"],
                rows: tableRows, expanded: expandAll)))
    }

    // MARK: - auditEvidence

    /// Audit findings grouped by severity. A finding is `{name, category, severity, affected,
    /// recommendation}` from `pro audit`; the older `check`, `policy` and `detail` spellings
    /// still read.
    func buildAuditEvidence(auditFindings: [[String: Any]]) -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        guard !auditFindings.isEmpty else { return .omitted("no audit findings in the snapshot") }

        // Group by severity, preserving severity display order
        let severityOrder = ["critical", "high", "error", "medium", "moderate",
                             "warning", "warn", "info", "low"]
        var grouped: [String: [[String: Any]]] = [:]
        for finding in auditFindings {
            let sev = (finding["severity"] as? String ?? "unknown").lowercased()
            grouped[sev, default: []].append(finding)
        }

        var parts: [String] = []
        let orderedKeys = severityOrder.filter { grouped[$0] != nil }
            + grouped.keys.filter { !severityOrder.contains($0) }.sorted()

        for sev in orderedKeys {
            guard let items = grouped[sev], !items.isEmpty else { continue }
            let pill = f.renderSeverityPill(sev)

            // Collect invisible device anchors for every unique device named in findings.
            var seenDeviceSlugs: Set<String> = []
            var deviceAnchors = ""
            for item in items {
                let device = item["device"] as? String
                    ?? item["computer_name"] as? String ?? ""
                guard !device.isEmpty else { continue }
                let slug = deviceAnchorSlug(device)
                if seenDeviceSlugs.insert(slug).inserted {
                    deviceAnchors += "<div class=\"device-anchor\" " +
                        "id=\"audit-dev-\(f.escapeHTML(slug))\"></div>\n"
                }
            }

            let showsAffected = items.contains { $0["affected"] != nil }
            let tableRows = items.map { item -> [String] in
                let check = item["check"] as? String
                    ?? item["rule_id"] as? String ?? item["name"] as? String ?? ""
                let detail = item["detail"] as? String
                    ?? item["message"] as? String ?? item["recommendation"] as? String ?? ""
                let resource = item["policy"] as? String
                    ?? item["resource"] as? String ?? item["category"] as? String ?? ""
                let row = [check, resource, detail]
                return showsAffected ? row + [item["affected"].map { "\($0)" } ?? ""] : row
            }
            let headers = ["Check", "Policy / Resource", "Detail"]
                + (showsAffected ? ["Affected"] : [])
            parts.append("""
            <div class="audit-severity-group">
              \(deviceAnchors)<h4>\(pill) \(f.escapeHTML(sev.capitalized)) (\(items.count))</h4>
              \(f.renderCappedTable(headers: headers, rows: tableRows, expanded: expandAll))
            </div>
            """)
        }

        return .shown(f.block(
            id: "audit-evidence",
            title: "Audit findings (\(auditFindings.count))",
            body: parts.joined(separator: "\n")))
    }

    // MARK: - exceptionList

    /// Compliance exceptions from `config.yaml`'s `exceptions:` list. Omitted when none are
    /// configured: custom EAs are not exceptions, and an older build listed them here.
    func buildExceptionList() -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        let exceptions = config.exceptions ?? []
        guard !exceptions.isEmpty else {
            return .omitted("not configured: no exceptions: block in config.yaml")
        }
        let framework = config.compliance?.displayFramework ?? "Not configured"

        // ISO-8601 date parser for expires_date — yyyy-MM-dd only.
        let isoDF: DateFormatter = {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            return df
        }()
        let today = Calendar.current.startOfDay(for: Date())

        let tableRows: [String] = exceptions.map { ex -> String in
            let isExpired: Bool
            if let raw = ex.expiresDate, let date = isoDF.date(from: raw) {
                isExpired = date < today
            } else {
                isExpired = false
            }

            let expiresCell: String
            if let raw = ex.expiresDate, !raw.isEmpty {
                let pill = isExpired
                    ? "<span class=\"sev-pill sev-error\">Expired</span>"
                    : f.escapeHTML(raw)
                expiresCell = "<td>\(pill)</td>"
            } else {
                expiresCell = "<td>—</td>"
            }

            let rowClass = isExpired ? " class=\"exception-expired\"" : ""
            return """
            <tr\(rowClass)>
              <td>\(f.escapeHTML(ex.id))</td>
              <td>\(f.escapeHTML(ex.description))</td>
              <td>\(f.escapeHTML(ex.signedOffBy))</td>
              <td>\(f.escapeHTML(ex.signedOffDate))</td>
              \(expiresCell)
              <td>\(ex.linkedFinding.map { f.escapeHTML($0) } ?? "—")</td>
            </tr>
            """
        }

        let headers = ["ID", "Description", "Signed off by", "Signed off", "Expires",
                       "Linked finding"]
        return .shown(f.block(
            id: "exception-list",
            title: "Exceptions — \(framework) (\(exceptions.count))",
            body: f.renderCappedRows(headers: headers, rowHTML: tableRows, expanded: expandAll)))
    }

    // MARK: - purchaseCohorts

    /// Macs grouped by purchase-date year, as bars.
    func buildPurchaseCohorts(computersInventory: [[String: Any]]) -> HtmlBlock {
        let dates = computersInventory.map { inventoryPurchaseDate($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !dates.isEmpty else { return .omitted("no purchase dates in the inventory") }

        var byYear: [String: Int] = [:]
        for raw in dates {
            let year = String(raw.prefix(4))
            guard !year.isEmpty, year.allSatisfy(\.isNumber) else { continue }
            byYear[year, default: 0] += 1
        }
        guard !byYear.isEmpty else { return .omitted("no purchase date with a readable year") }

        let rows = byYear.keys.sorted().map { (label: $0, count: byYear[$0] ?? 0) }
        return .shown(HtmlSectionFormatters.block(
            id: "purchase-cohorts",
            title: "Purchase cohorts (\(dates.count) Mac\(dates.count == 1 ? "" : "s"))",
            body: HtmlSectionFormatters.renderBars(rows, expanded: expandAll)))
    }

    // MARK: - buildingBreakdown

    /// Macs per building, as bars.
    func buildBuildingBreakdown(computersInventory: [[String: Any]]) -> HtmlBlock {
        buildGroupBreakdown(
            computersInventory: computersInventory, sectionID: "building-breakdown",
            title: "Buildings", value: inventoryBuilding)
    }

    // MARK: - departmentBreakdown

    /// Macs per department, as bars.
    func buildDepartmentBreakdown(computersInventory: [[String: Any]]) -> HtmlBlock {
        buildGroupBreakdown(
            computersInventory: computersInventory, sectionID: "department-breakdown",
            title: "Departments", value: inventoryDepartment)
    }

    /// Shared bars for building / department, largest first. Omitted when no Mac is assigned
    /// to any: a single "(unassigned)" bar says nothing.
    private func buildGroupBreakdown(
        computersInventory: [[String: Any]],
        sectionID: String,
        title: String,
        value: ([String: Any]) -> String
    ) -> HtmlBlock {
        guard !computersInventory.isEmpty else { return .omitted("no computers snapshot") }
        var counts: [String: Int] = [:]
        for item in computersInventory {
            let name = value(item)
            counts[name == "—" || name.isEmpty ? "(unassigned)" : name, default: 0] += 1
        }
        guard counts.keys.contains(where: { $0 != "(unassigned)" }) else {
            return .omitted("every Mac is unassigned")
        }
        let sorted = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (label: $0.key, count: $0.value) }
        return .shown(HtmlSectionFormatters.block(
            id: sectionID, title: "\(title) (\(sorted.count))",
            body: HtmlSectionFormatters.renderBars(sorted, expanded: expandAll)))
    }

    // MARK: - protectAlerts

    /// Protect alerts grouped by severity, capped by `html.section_limits.protect_alerts`
    /// (default 25, bounded [1, 200]). Reads jamf-cli's flattened alert rows from the
    /// `protect-alerts` kind directory `ReportEngine.protectCollect` writes.
    func buildProtectAlerts(protectDataDir: URL?) -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        let cap = config.html?.sectionLimits?.resolvedProtectAlerts ?? 25

        guard let dir = protectDataDir else {
            return .omitted("not configured: protect.enabled is off in config.yaml")
        }
        let alerts = loadProtectJSON(kind: "protect-alerts", dataDir: dir)
        guard !alerts.isEmpty else { return .omitted("no Protect alerts in the snapshot") }

        var bySeverity: [String: [[String: Any]]] = [:]
        for alert in alerts {
            let sev = (alert["severity"] as? String ?? "unknown").lowercased()
            bySeverity[sev, default: []].append(alert)
        }

        // Protect's severity enum: High, Medium, Low, Informational (no Critical).
        let severityOrder = ["high", "medium", "low", "informational"]
        let orderedKeys = severityOrder.filter { bySeverity[$0] != nil }
            + bySeverity.keys.filter { !severityOrder.contains($0) }.sorted()

        var parts: [String] = []
        var totalShown = 0
        for sev in orderedKeys {
            guard let sevAlerts = bySeverity[sev], !sevAlerts.isEmpty else { continue }
            let take = max(0, min(sevAlerts.count, cap - totalShown))
            guard take > 0 else { continue }

            let alertRows = sevAlerts.prefix(take).map { alert -> String in
                // jamf-cli's flattened row: `computer` is the host name (string,
                // absent when the alert has no computer); `eventType` names the
                // alert, falling back to the comma-joined `analytics` list.
                let rawDevice = alert["computer"] as? String ?? ""
                let eventType = alert["eventType"] as? String ?? ""
                let description = !eventType.isEmpty
                    ? eventType
                    : ((alert["analytics"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                let date = (alert["created"] as? String).map { String($0.prefix(10)) } ?? "—"

                // Wrap device cell in a link to its audit-evidence anchor when known.
                let deviceCell: String
                if rawDevice.isEmpty {
                    deviceCell = "<td>—</td>"
                } else {
                    let slug = deviceAnchorSlug(rawDevice)
                    deviceCell = "<td><a href=\"#audit-dev-\(f.escapeHTML(slug))\" " +
                        "class=\"device-link\">\(f.escapeHTML(rawDevice))</a></td>"
                }
                return "<tr>\(deviceCell)" +
                    "<td>\(f.escapeHTML(description))</td>" +
                    "<td>\(f.escapeHTML(date))</td></tr>"
            }
            totalShown += take
            parts.append("""
            <div class="audit-severity-group">
              <h4>\(f.renderSeverityPill(sev)) (\(sevAlerts.count))</h4>
              \(f.renderCappedRows(
                  headers: ["Device", "Alert", "Date"], rowHTML: Array(alertRows),
                  expanded: expandAll))
            </div>
            """)
        }

        return .shown(f.block(
            id: "protect-alerts",
            title: "Protect alerts (showing \(totalShown) of \(alerts.count))",
            body: parts.joined(separator: "\n")))
    }

    // MARK: - insightsDrift

    /// Protect insights snapshot comparison, using up to
    /// `html.section_limits.insights_drift_snapshots` (default 2, bounded [1, 12]) snapshots.
    /// Values are failing-device counts (`totalFail`) per insight, read from the
    /// `protect-insights` kind directory `ReportEngine.protectCollect` writes.
    ///
    /// When more than two snapshots are requested, the table gains one column per additional
    /// snapshot labelled "N ago" (oldest first, current last).
    func buildInsightsDrift(protectDataDir: URL?) -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        let snapshotCap = config.html?.sectionLimits?.resolvedInsightsDriftSnapshots ?? 2

        guard let dir = protectDataDir else {
            return .omitted("not configured: protect.enabled is off in config.yaml")
        }
        let allSnapshots = loadProtectInsightSnapshots(dataDir: dir)
        guard allSnapshots.count >= 2 else {
            return .omitted("needs two or more Protect insights snapshots; "
                + "\(allSnapshots.count) found")
        }

        // Take the most recent `snapshotCap` snapshots; fall back to all available if fewer.
        let window = Array(allSnapshots.suffix(snapshotCap))

        // Collect all insight labels across the window.
        var insightKeys: [String] = []
        for snapshot in window {
            for key in snapshot.keys where !insightKeys.contains(key) {
                insightKeys.append(key)
            }
        }
        insightKeys.sort()

        // Build headers: "Insight", then one column per snapshot from oldest → "Current".
        var headers = ["Insight"]
        for idx in 0 ..< window.count {
            if idx == window.count - 1 {
                headers.append("Current")
            } else if idx == window.count - 2 {
                headers.append("Previous")
            } else {
                headers.append("\(window.count - 1 - idx) ago")
            }
        }

        // Plain text: renderTable escapes every cell.
        let tableRows = insightKeys.map { key -> [String] in
            var row = [key]
            for snapshot in window {
                row.append(snapshot[key].map { "\($0)" } ?? "—")
            }
            return row
        }

        return .shown(f.block(
            id: "insights-drift",
            title: "Protect insights drift (\(window.count) of \(allSnapshots.count) snapshots)",
            body: """
            <p class="empty-hint">Values are failing-device counts per insight.</p>
            \(f.renderCappedTable(headers: headers, rows: tableRows, expanded: expandAll))
            """))
    }

    // MARK: - agentHealth

    /// Per-security-agent (CrowdStrike, etc.) installed/missing/unknown counts from the
    /// `ea-results` snapshot, through `SecurityAgentCoverage` like the Overview card and the
    /// daily summary's EDR figure. Coverage is over `fleet` Macs, so a Mac with no value
    /// counts as unknown; `fleet` falls back to the Macs ea-results knows when it is 0.
    func buildAgentHealth(eaRows: [EAResultRow]?, fleet: Int) -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        let agents = config.securityAgents ?? []
        guard !agents.isEmpty else {
            return .omitted("not configured: no security_agents in config.yaml")
        }
        guard let eaRows, !eaRows.isEmpty else {
            return .omitted("no extension attribute results in the snapshot")
        }

        let coverage = SecurityAgentCoverage.compute(rows: eaRows, agents: agents)
        guard coverage.contains(where: { $0.reporting > 0 }) else {
            return .omitted("no Mac reports the extension attribute of any configured agent ("
                + coverage.map(\.column).joined(separator: ", ") + ")")
        }
        let total = fleet > 0 ? fleet : MSCPComplianceService.allDistinctDeviceIds(in: eaRows).count
        var tableRows: [[String]] = []
        var barCards: [HtmlSectionFormatters.SectionCard] = []
        for agent in coverage {
            // An agent no Mac reports (a column that matches no EA) has no coverage to state.
            let pct = agent.reporting > 0
                ? SecurityAgentCoverage.percent(installed: agent.installed, fleet: total) : nil
            tableRows.append([
                agent.name,
                "\(agent.installed)",
                "\(max(agent.reporting - agent.installed, 0))",
                "\(max(total - agent.reporting, 0))",
                pct.map { String(format: "%.1f%%", $0) } ?? "\u{2014}",
            ])
            barCards.append(HtmlSectionFormatters.SectionCard(
                name: agent.name,
                value: pct.map { String(format: "%.0f%%", $0) } ?? "\u{2014}",
                sublabel: agent.reporting > 0
                    ? "\(agent.installed) of \(total) installed"
                    : "no Mac reports \(agent.column)"
            ))
        }
        return .shown(f.block(id: "agent-health", title: "Security agent health", body: """
            \(f.renderCardGrid(cards: barCards))
            \(f.renderTable(
                headers: ["Agent", "Installed", "Missing", "Unknown", "Coverage"],
                rows: tableRows
            ))
            """))
    }

    // MARK: - Protect helpers

    /// Load JSON for a Protect kind (e.g. `protect-alerts`) from `dataDir`.
    /// Same algorithm as `loadJSON(kind:)`, parameterized for test callers.
    private func loadProtectJSON(kind: String, dataDir: URL) -> [[String: Any]] {
        let fm = FileManager.default
        let subdir = dataDir.appendingPathComponent(kind, isDirectory: true)
        var candidates: [URL] = []
        if fm.fileExists(atPath: subdir.path),
           let files = try? fm.contentsOfDirectory(
            at: subdir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
           ) {
            candidates = files.filter { $0.pathExtension == "json" }
        }
        if let files = try? fm.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates += files.filter {
                $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(kind + "_")
            }
        }
        // Shared rule (filename stamp, manifest + conflict copies excluded).
        guard let newest = FileManager.newestSnapshot(among: candidates) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: newest)
        } catch {
            AppLogger.platform.debug(
                "loadProtectJSON: could not read '\(newest.path, privacy: .private)' — \(error, privacy: .private)"
            )
            return []
        }
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            AppLogger.platform.debug(
                "loadProtectJSON: JSON parse failed for '\(newest.path, privacy: .private)'"
            )
            return []
        }
        return result
    }

    /// Load Protect insights snapshots, reduced to failing-device counts
    /// (`totalFail`) per insight label, oldest first.
    private func loadProtectInsightSnapshots(dataDir: URL) -> [[String: Int]] {
        let fm = FileManager.default
        let subdir = dataDir.appendingPathComponent("protect-insights", isDirectory: true)
        guard fm.fileExists(atPath: subdir.path),
              let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            // Shared rule (`FileSystemHelpers`): order by the filename stamp,
            // excluding the manifest, `.partial` staging files and sync-conflict
            // copies. Raw mtime mis-ordered the series on a synced volume — the
            // provider re-stamps on materialize — and counted a conflict copy as
            // an extra day of drift.
            .filter(FileManager.isSelectableSnapshot)
            .sorted { FileManager.isOlderSnapshot($0, than: $1) }
            .compactMap { url -> [String: Int]? in
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    AppLogger.platform.debug(
                        // swiftlint:disable:next line_length
                        "loadProtectInsightSnapshots: could not read \(url.path, privacy: .private) — \(error, privacy: .private)"
                    )
                    return nil
                }
                // jamf-cli's flattened row: label, section, enabled,
                // totalPass/totalFail/totalNone, cisIDs — a bare array, not a dict.
                let parsed = try? JSONSerialization.jsonObject(with: data)
                guard let rows = parsed as? [[String: Any]] else {
                    AppLogger.platform.debug(
                        "loadProtectInsightSnapshots: JSON parse failed for '\(url.path, privacy: .private)'"
                    )
                    return nil
                }
                var byLabel: [String: Int] = [:]
                for row in rows {
                    guard let label = row["label"] as? String else { continue }
                    byLabel[label] = asInt(row["totalFail"]) ?? 0
                }
                return byLabel
            }
    }

    // MARK: - cleanupAnalysis

    /// Jamf instance hygiene: disabled policies, unscoped policies/profiles,
    /// unused packages, and unused scripts.
    ///
    /// Requires per-policy detail fields (`general.enabled`, `scope.*`,
    /// `package_configuration.packages`, `scripts`) that are only present when
    /// jamf-cli collects individual policy detail records. The flat
    /// `classic-policies` list snapshot (id + name only) cannot satisfy these
    /// requirements, so the section is left out with that reason instead of reporting
    /// "none found". It is also left out when the detail is present and nothing needs
    /// cleaning up.
    func buildCleanupAnalysis(
        classicPolicies: [[String: Any]],
        classicProfiles: [[String: Any]],
        packages: [[String: Any]],
        scripts: [[String: Any]]
    ) -> HtmlBlock {
        let f = HtmlSectionFormatters.self

        // Detect whether any record carries the per-policy detail fields needed.
        let hasDetailFields = classicPolicies.contains { policy in
            policy["general"] != nil || policy["scope"] != nil
                || policy["package_configuration"] != nil
                || policy["scripts"] != nil
        }
        let hasProfileDetailFields = classicProfiles.contains { profile in
            profile["general"] != nil || profile["scope"] != nil
        }

        // When no detail is present the section must say so honestly.
        guard hasDetailFields || hasProfileDetailFields else {
            return .omitted(classicPolicies.isEmpty
                ? "no classic-policies snapshot"
                : "the classic-policies snapshot lists id and name only; the per-policy detail "
                    + "this analysis needs is not in it")
        }

        let disabled = cleanupDisabledPolicies(classicPolicies)
        let unscopedPolicies = cleanupUnscopedPolicies(classicPolicies)
        let unscopedProfiles = cleanupUnscopedProfiles(classicProfiles)
        let unusedPackages = cleanupUnusedPackages(packages, policies: classicPolicies)
        let unusedScripts = cleanupUnusedScripts(scripts, policies: classicPolicies)

        // Each category gets its own presence flag so a pane never renders
        // "None found — good!" when its specific detail type is absent, even
        // when other detail types are present on the same policy records.
        let hasPolicyGeneralDetail = classicPolicies.contains { $0["general"] != nil }
        let hasPackageDetail = classicPolicies.contains { $0["package_configuration"] != nil }
        let hasScriptDetail = classicPolicies.contains { $0["scripts"] != nil }

        let categories: [(String, String, [String], Bool)] = [
            ("Disabled Policies",  "disabled-policies",   disabled,         hasPolicyGeneralDetail),
            ("Unscoped Policies",  "unscoped-policies",   unscopedPolicies, hasPolicyGeneralDetail),
            ("Unscoped Profiles",  "unscoped-profiles",   unscopedProfiles, hasProfileDetailFields),
            ("Unused Packages",    "unused-packages",     unusedPackages,   hasPackageDetail),
            ("Unused Scripts",     "unused-scripts",      unusedScripts,    hasScriptDetail),
        ]
        guard categories.contains(where: { $0.3 && !$0.2.isEmpty }) else {
            return .omitted("nothing to clean up: no disabled or unscoped policies, unscoped "
                + "profiles, or unused packages or scripts")
        }

        let tabs = categories.enumerated().map { idx, tuple -> String in
            let (label, tabID, items, hasData) = tuple
            let badge = hasData ? "\(items.count)" : "?"
            let activeAttr = idx == 0 ? " active" : ""
            return """
            <button type="button"
              class="cleanup-tab\(activeAttr)"
              id="ctab-\(f.escapeHTML(tabID))"
              role="tab"
              aria-controls="cpane-\(f.escapeHTML(tabID))"
              aria-selected="\(idx == 0 ? "true" : "false")"
              tabindex="\(idx == 0 ? "0" : "-1")"
              data-target="cpane-\(f.escapeHTML(tabID))">
              \(f.escapeHTML(label))
              <span class="cleanup-badge">\(f.escapeHTML(badge))</span>
            </button>
            """
        }.joined(separator: "\n")

        let panes = categories.enumerated().map { idx, tuple -> String in
            let (_, tabID, items, hasData) = tuple
            let activeAttr = idx == 0 ? " active" : ""
            let body: String
            if !hasData {
                body = f.emptyState(
                    "Per-policy/profile detail not present in this snapshot."
                )
            } else if items.isEmpty {
                body = "<p class=\"cleanup-ok\">None found — good!</p>"
            } else {
                body = f.renderCappedList(items: items, expanded: expandAll)
            }
            return """
            <div class="cleanup-pane\(activeAttr)"
              id="cpane-\(f.escapeHTML(tabID))"
              role="tabpanel"
              aria-labelledby="ctab-\(f.escapeHTML(tabID))"
              tabindex="0">
              \(body)
            </div>
            """
        }.joined(separator: "\n")

        let policiesWithDetail = classicPolicies.filter { $0["general"] != nil }.count
        let profilesWithDetail = classicProfiles.filter { $0["general"] != nil }.count
        let detailNote = policiesWithDetail > 0 || profilesWithDetail > 0
            ? "Based on \(policiesWithDetail) "
                + "polic\(policiesWithDetail == 1 ? "y" : "ies") and "
                + "\(profilesWithDetail) profile\(profilesWithDetail == 1 ? "" : "s") "
                + "with cached detail."
            : ""

        return .shown(f.block(id: "cleanup-analysis", title: "Cleanup analysis", body: """
            \(detailNote.isEmpty ? "" : "<p class=\"cleanup-note\">\(f.escapeHTML(detailNote))</p>")
            <div class="cleanup-tabs" role="tablist" aria-label="Cleanup categories">
              \(tabs)
            </div>
            \(panes)
            """))
    }

    // MARK: Cleanup helpers — field-presence aware

    /// Names of disabled policies (requires `general.enabled` field).
    func cleanupDisabledPolicies(_ policies: [[String: Any]]) -> [String] {
        policies.compactMap { policy -> String? in
            guard let general = policy["general"] as? [String: Any] else { return nil }
            guard general["enabled"] as? Bool == false else { return nil }
            return general["name"] as? String ?? policy["name"] as? String
        }.sorted()
    }

    /// Names of enabled policies with no scope targets (requires `general` + `scope`).
    func cleanupUnscopedPolicies(_ policies: [[String: Any]]) -> [String] {
        policies.compactMap { policy -> String? in
            guard let general = policy["general"] as? [String: Any] else { return nil }
            // Skip disabled policies — they are reported separately.
            if general["enabled"] as? Bool == false { return nil }
            guard let scope = policy["scope"] as? [String: Any] else { return nil }
            // "All Computers" scoped policies are not unscoped.
            if scope["all_computers"] as? Bool == true { return nil }
            let computers = (scope["computers"] as? [[String: Any]])?.isEmpty != false
            let groups = (scope["computer_groups"] as? [[String: Any]])?.isEmpty != false
            let buildings = (scope["buildings"] as? [[String: Any]])?.isEmpty != false
            let departments = (scope["departments"] as? [[String: Any]])?.isEmpty != false
            guard computers && groups && buildings && departments else { return nil }
            return general["name"] as? String ?? policy["name"] as? String
        }.sorted()
    }

    /// Names of macOS config profiles with no scope targets (requires `general` + `scope`).
    func cleanupUnscopedProfiles(_ profiles: [[String: Any]]) -> [String] {
        profiles.compactMap { profile -> String? in
            guard let scope = profile["scope"] as? [String: Any] else { return nil }
            if scope["all_computers"] as? Bool == true { return nil }
            let computers = (scope["computers"] as? [[String: Any]])?.isEmpty != false
            let groups = (scope["computer_groups"] as? [[String: Any]])?.isEmpty != false
            let buildings = (scope["buildings"] as? [[String: Any]])?.isEmpty != false
            let departments = (scope["departments"] as? [[String: Any]])?.isEmpty != false
            guard computers && groups && buildings && departments else { return nil }
            let general = profile["general"] as? [String: Any]
            return general?["name"] as? String ?? profile["name"] as? String
        }.sorted()
    }

    /// Package names not referenced in any policy's `package_configuration`.
    ///
    /// Returns an empty array when no policy carries `package_configuration` data — this
    /// prevents falsely reporting every package as unused when detail is absent.
    func cleanupUnusedPackages(
        _ packages: [[String: Any]],
        policies: [[String: Any]]
    ) -> [String] {
        let referencedIDs: Set<String> = {
            var ids: Set<String> = []
            for policy in policies {
                guard let pkgCfg = policy["package_configuration"] as? [String: Any],
                      let pkgs = pkgCfg["packages"] as? [[String: Any]] else { continue }
                for pkg in pkgs {
                    let idStr = pkg["id"].map { "\($0)" } ?? ""
                    if !idStr.isEmpty { ids.insert(idStr) }
                }
            }
            return ids
        }()
        // When no policy carries package_configuration, we have no evidence to
        // determine which packages are unused — return empty rather than all.
        let hasPackageDetail = policies.contains { $0["package_configuration"] != nil }
        guard hasPackageDetail else { return [] }
        return packages.compactMap { pkg -> String? in
            let idStr = pkg["id"].map { "\($0)" } ?? ""
            let name = pkg["packageName"] as? String ?? pkg["name"] as? String ?? ""
            guard !idStr.isEmpty, !name.isEmpty, !referencedIDs.contains(idStr) else {
                return nil
            }
            return name
        }.sorted()
    }

    /// Script names not referenced in any policy's `scripts` list.
    ///
    /// Returns an empty array when no policy carries script reference data — this
    /// prevents falsely reporting every script as unused when detail is absent.
    func cleanupUnusedScripts(
        _ scripts: [[String: Any]],
        policies: [[String: Any]]
    ) -> [String] {
        let referencedIDs: Set<String> = {
            var ids: Set<String> = []
            for policy in policies {
                guard let scriptsList = policy["scripts"] as? [[String: Any]] else { continue }
                for scr in scriptsList {
                    let idStr = scr["id"].map { "\($0)" } ?? ""
                    if !idStr.isEmpty { ids.insert(idStr) }
                }
            }
            return ids
        }()
        let hasScriptDetail = policies.contains { $0["scripts"] != nil }
        guard hasScriptDetail else { return [] }
        return scripts.compactMap { scr -> String? in
            let idStr = scr["id"].map { "\($0)" } ?? ""
            let name = scr["name"] as? String ?? ""
            guard !idStr.isEmpty, !name.isEmpty, !referencedIDs.contains(idStr) else {
                return nil
            }
            return name
        }.sorted()
    }

    // MARK: - timeline

    /// OS adoption and security metric trends from workspace `summary_*.json` snapshots.
    ///
    /// Reads from `<dataDir>/../snapshots/summaries/summary_*.json` — the same
    /// directory `TrendStore` reads, but parsed independently (Engine layer must not
    /// depend on Services). Plots available scalar series: FileVault %, SIP %, and
    /// compliance %. The chart is visible; the daily values sit in a nested block of their
    /// own, since a year of days is a table nobody scrolls.
    ///
    /// Note: Python's `_render_timeline_section` renders per-OS-version lines from a
    /// `{ts, versions:[{v,c}]}` history file. Summary snapshots carry only aggregate
    /// scalars (no per-version counts), so per-version trend lines cannot be reproduced
    /// from this data source; scalar metric trends are rendered instead.
    func buildTimelineSection() -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        let (summaries, skipped) = loadSummarySnapshots()
        guard !summaries.isEmpty else { return .omitted("no daily summaries yet") }
        let skippedNote = skipped > 0
            ? "<p class=\"timeline-warn\">\(skipped) snapshot file\(skipped == 1 ? "" : "s") "
                + "could not be parsed.</p>"
            : ""

        // Date + key metrics, oldest first.
        let tableRows: [[String]] = summaries.map { s in
            let fvStr = s.fileVaultPct.map { String(format: "%.1f%%", $0) } ?? "—"
            let sipStr = s.sipPct.map { String(format: "%.1f%%", $0) } ?? "—"
            let compStr = s.compliancePct.map { String(format: "%.1f%%", $0) } ?? "—"
            return [s.date, "\(s.totalDevices)", fvStr, sipStr, compStr]
        }
        let daily = f.disclosure(
            label: "Daily values (\(summaries.count))",
            body: f.renderTable(
                headers: ["Date", "Total Devices", "FileVault", "SIP", "Compliance"],
                rows: tableRows),
            expanded: expandAll)

        if summaries.count == 1 {
            return .shown(f.block(id: "timeline", title: "Historical trends", body: """
                <p class="empty-note">Only 1 snapshot available — collect more runs to see
                trends.</p>
                \(skippedNote)
                \(daily)
                """))
        }
        let count = summaries.count
        return .shown(f.block(id: "timeline", title: "Historical trends", body: """
            <p class="timeline-note">\(count) snapshots &middot; metrics from workspace
            summaries</p>
            \(skippedNote)
            \(renderTimelineSVG(summaries: summaries))
            \(daily)
            """))
    }

    // MARK: Timeline helpers

    /// Minimal summary snapshot — only the fields needed for trend rendering.
    struct SummarySnapshot: Sendable {
        let date: String
        let totalDevices: Int
        let fileVaultPct: Double?
        let sipPct: Double?
        let compliancePct: Double?
    }

    /// Load and parse `summary_*.json` files from `<dataDir>/../snapshots/summaries/`.
    ///
    /// Parses only the scalar fields needed for timeline rendering. Accepts both
    /// camelCase (Swift/Python-emitted) and snake_case key spellings for each field.
    /// Returns entries sorted oldest-first by date string (ISO format sorts correctly).
    /// The `skipped` count reports files that were present but could not be decoded.
    func loadSummarySnapshots() -> (snapshots: [SummarySnapshot], skipped: Int) {
        let summariesDir = dataDir
            .deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: summariesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return ([], 0) }

        let candidates = files
            .filter { CloudStorage.isCanonicalSummaryFilename($0.lastPathComponent) }

        var skipped = 0
        var snapshots: [SummarySnapshot] = []
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any],
                  let date = dict["date"] as? String
            else { skipped += 1; continue }

            // Accept both camelCase (current Swift + Python writers) and snake_case
            // (defensive: hand-authored or third-party summaries). Both writers emit camelCase.
            func intVal(_ camel: String, _ snake: String) -> Int? {
                if let n = dict[camel] as? Int { return n }
                if let d = dict[camel] as? Double { return Int(d) }
                if let n = dict[snake] as? Int { return n }
                if let d = dict[snake] as? Double { return Int(d) }
                return nil
            }
            func dblVal(_ camel: String, _ snake: String) -> Double? {
                if let n = dict[camel] as? Double { return n }
                if let n = dict[camel] as? Int { return Double(n) }
                if let n = dict[snake] as? Double { return n }
                if let n = dict[snake] as? Int { return Double(n) }
                return nil
            }

            guard let total = intVal("totalDevices", "total_devices") else {
                skipped += 1; continue
            }
            snapshots.append(SummarySnapshot(
                date: date,
                totalDevices: total,
                fileVaultPct: dblVal("fileVaultPct", "filevault_pct"),
                sipPct:       dblVal("sipPct",       "sip_pct"),
                compliancePct: dblVal("compliancePct", "compliance_pct")
            ))
        }

        if skipped > 0 {
            AppLogger.report.warning(
                "loadSummarySnapshots: \(skipped, privacy: .public) snapshot file(s) could not be parsed and were skipped"
            )
        }

        return (snapshots: snapshots.sorted { $0.date < $1.date }, skipped: skipped)
    }

    /// Series up to this many days get a dot on every point.
    static let timelineDotLimit = 31

    /// Render an inline SVG multi-series line chart for summary trends.
    ///
    /// Plots up to 3 percentage series (FileVault, SIP, Compliance) on a 0–100 scale
    /// on the left y-axis. Total devices is omitted from the SVG to keep the y-axis
    /// coherent; it appears in the accompanying table.
    func renderTimelineSVG(summaries: [SummarySnapshot]) -> String {
        guard summaries.count >= 2 else {
            return "<p class=\"empty-note\">Not enough data for a trend chart.</p>"
        }

        let svgW: Double = 620
        let svgH: Double = 200
        let leftPad: Double = 48
        let topPad: Double = 16
        let rightPad: Double = 16
        let bottomPad: Double = 36
        let plotW = svgW - leftPad - rightPad
        let plotH = svgH - topPad - bottomPad
        let n = summaries.count

        func xPos(_ i: Int) -> Double {
            leftPad + Double(i) / Double(n - 1) * plotW
        }
        func yPos(_ pct: Double) -> Double {
            // y-axis is 0-100 (percent scale)
            topPad + plotH - (min(max(pct, 0), 100) / 100.0) * plotH
        }

        // Series definitions: (label, color, values)
        let f = HtmlSectionFormatters.self
        typealias Series = (label: String, color: String, values: [Double?])
        let allSeries: [Series] = [
            ("FileVault %", "#2D5EA2", summaries.map { $0.fileVaultPct }),
            ("SIP %",       "#43A047", summaries.map { $0.sipPct }),
            ("Compliance %", "#E65100", summaries.map { $0.compliancePct }),
        ]
        // Only include series that have at least one non-nil value.
        let activeSeries = allSeries.filter { $0.values.contains(where: { $0 != nil }) }

        // Y-axis grid lines (0, 25, 50, 75, 100)
        var gridLines = ""
        for tick in stride(from: 0, through: 100, by: 25) {
            let yCoord = yPos(Double(tick))
            let label = "\(tick)%"
            gridLines += """
            <line x1="\(String(format: "%.1f", leftPad))" \
            y1="\(String(format: "%.1f", yCoord))" \
            x2="\(String(format: "%.1f", svgW - rightPad))" \
            y2="\(String(format: "%.1f", yCoord))" \
            stroke="var(--border)" stroke-width="1"/>
            <text x="\(String(format: "%.1f", leftPad - 4))" \
            y="\(String(format: "%.1f", yCoord + 4))" \
            text-anchor="end" \
            style="font-size:9px;fill:var(--subtext)">\(f.escapeHTML(label))</text>
            """
        }

        // X-axis labels (show at most 6)
        var xLabels = ""
        let labelStep = max(1, n / 6)
        for i in 0 ..< n {
            guard i % labelStep == 0 || i == n - 1 else { continue }
            let xCoord = xPos(i)
            let dateLabel = String(summaries[i].date.prefix(10))
            xLabels += """
            <text x="\(String(format: "%.1f", xCoord))" \
            y="\(String(format: "%.1f", svgH - 4))" \
            text-anchor="middle" \
            style="font-size:9px;fill:var(--subtext)">\(f.escapeHTML(dateLabel))</text>
            """
        }

        // Render each series as a polyline + dots
        var seriesHTML = ""
        for series in activeSeries {
            // Build point list; skip nil values by breaking the polyline.
            var segments: [[Int]] = []
            var current: [Int] = []
            for i in 0 ..< n {
                if series.values[i] != nil {
                    current.append(i)
                } else {
                    if current.count >= 2 { segments.append(current) }
                    current = []
                }
            }
            if current.count >= 2 { segments.append(current) }

            for segment in segments {
                let points = segment.compactMap { i -> String? in
                    guard let val = series.values[i] else { return nil }
                    return "\(String(format: "%.1f", xPos(i))),\(String(format: "%.1f", yPos(val)))"
                }.joined(separator: " ")
                seriesHTML += """
                <polyline fill="none" stroke="\(series.color)" stroke-width="2"
                  stroke-linejoin="round" points="\(points)"/>
                """
            }
            // A dot on every point of a short series; a long one gets its last point only,
            // since 200 dots hide the line and weigh more than the rest of the chart.
            let lastPoint = series.values.indices.last { series.values[$0] != nil }
            let dotted = n <= Self.timelineDotLimit
                ? Array(0 ..< n) : lastPoint.map { [$0] } ?? []
            for i in dotted {
                guard let val = series.values[i] else { continue }
                seriesHTML += """
                <circle cx="\(String(format: "%.1f", xPos(i)))" \
                cy="\(String(format: "%.1f", yPos(val)))" \
                r="3" fill="\(series.color)" aria-label="\(f.escapeHTML(series.label)): \(String(format: "%.1f", val))%"/>
                """
            }
        }

        // Legend
        let legendItems = activeSeries.map { series -> String in
            """
            <g>
              <rect x="0" y="-6" width="14" height="6" fill="\(series.color)"/>
              <text x="18" y="0" style="font-size:10px;fill:var(--text)">\(f.escapeHTML(series.label))</text>
            </g>
            """
        }
        var legendX: Double = leftPad
        let legendY = topPad + plotH + bottomPad - 4
        var legendHTML = ""
        for item in legendItems {
            legendHTML += "<g transform=\"translate(\(String(format: "%.0f", legendX)),\(String(format: "%.0f", legendY)))\">"
            legendHTML += item
            legendHTML += "</g>"
            legendX += 130
        }

        return """
        <svg viewBox="0 0 \(Int(svgW)) \(Int(svgH))" class="history-svg"
          role="img" aria-label="Historical metric trends">
          \(gridLines)
          \(seriesHTML)
          \(xLabels)
          \(legendHTML)
        </svg>
        """
    }

    // MARK: - Anchor helpers

    /// Produce a stable HTML `id`-safe slug from a device name.
    ///
    /// Lowercases, replaces every non-`[a-z0-9_-]` character with `-`,
    /// collapses runs of `-` to a single `-`, and trims leading/trailing `-`.
    /// Returns `"device"` when the result would otherwise be empty.
    func deviceAnchorSlug(_ name: String) -> String {
        var slug = name.lowercased()

        // Replace non-ASCII characters with "-" before ASCII processing.
        slug = slug.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
                || v == 0x5F || v == 0x2D {
                return Character(scalar)
            }
            return "-"
        }.reduce(into: "") { $0.append($1) }

        // Collapse consecutive dashes.
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        // Trim leading/trailing dashes.
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "device" : slug
    }

    // MARK: - osCurrency

    /// The latest release per platform from the cached SOFA feed. Omitted when no feed is
    /// cached.
    func buildOSCurrencySection() -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        let sofaSnapshot = SOFAFeedService.load(dataDir: dataDir)
        guard !sofaSnapshot.rows.isEmpty else {
            return .omitted("the SOFA feed is not cached; a collect fetches it")
        }

        // HTML section shows SOFA latest data only — fleet counts require the
        // security/mobile-inventory snapshots, which are not joined here.
        let headers = ["Platform", "OS Family", "Latest Version", "Released",
                       "Days Since Release", "CVEs Exploited"]
        let rows = sofaSnapshot.rows.map { entry -> String in
            let days = entry.daysSinceRelease.map { String($0) } ?? "—"
            let released = entry.releaseDate.isEmpty ? "—" : entry.releaseDate
            let cveStyle = entry.activelyExploitedCVEs > 0 ? " style=\"color:var(--red)\"" : ""
            return "<tr>"
                + "<td>\(f.escapeHTML(entry.platform))</td>"
                + "<td>\(f.escapeHTML(entry.osFamily))</td>"
                + "<td>\(f.escapeHTML(entry.productVersion))</td>"
                + "<td>\(f.escapeHTML(released))</td>"
                + "<td>\(f.escapeHTML(days))</td>"
                + "<td\(cveStyle)>\(entry.activelyExploitedCVEs)</td></tr>"
        }
        return .shown(f.block(id: "os-currency", title: "OS currency", body: """
            <p class="note">Source: SOFA (sofa.macadmins.io)</p>
            \(f.renderCappedRows(headers: headers, rowHTML: rows, expanded: expandAll))
            """))
    }
}
