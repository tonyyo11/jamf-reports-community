import Foundation

// MARK: - HtmlReport+Sections
//
// The 14 section renderers that Phase 4 Lane H left as placeholders.
// Each renderer is a pure instance method — it reads from cached JSON already
// loaded in `buildSectionMap` and passes data through `HtmlSectionFormatters`.
//
// All user-controlled strings MUST go through `HtmlSectionFormatters.escapeHTML(_:)`
// before interpolation. No exceptions.

extension HtmlReport {

    // MARK: - 1. execSummary

    /// Three-paragraph executive narrative synthesised from KPI snapshots.
    /// No invented metrics — only values available from loaded JSON.
    func buildExecSummary(
        totalDevices: Int,
        fileVaultPct: Double,
        sipPct: Double,
        firewallPct: Double,
        deviceCompliance: [[String: Any]],
        patchStatus: [[String: Any]]
    ) -> String {
        let f = HtmlSectionFormatters.self

        // Compliance summary
        let complianceTotal = deviceCompliance.count
        let compliancePassing = deviceCompliance.filter {
            (asInt($0["failure_count"]) ?? asInt($0["failures_count"]) ?? 0) == 0
        }.count
        let compliancePct = complianceTotal > 0
            ? Double(compliancePassing) / Double(complianceTotal) * 100 : -1.0

        // Patch summary: titles below 100%
        let belowFullPatch = patchStatus.filter { item -> Bool in
            let s = item["compliance_pct"] as? String ?? "100"
            let v = Double(s.replacingOccurrences(of: "%", with: "")) ?? 100
            return v < 100
        }.count

        let fleetP: String
        if totalDevices > 0 {
            fleetP = """
            The fleet comprises \(totalDevices) managed \(totalDevices == 1 ? "device" : "devices"). \
            FileVault encryption stands at \(String(format: "%.1f", fileVaultPct))%, \
            SIP at \(String(format: "%.1f", sipPct))%, \
            and Firewall at \(String(format: "%.1f", firewallPct))%.
            """
        } else {
            fleetP = "Fleet device count could not be determined from available snapshots."
        }

        let complianceP: String
        if complianceTotal > 0 {
            let pctStr = String(format: "%.0f", compliancePct)
            complianceP = "\(pctStr)% of devices (\(compliancePassing) of \(complianceTotal)) " +
                "meet all compliance requirements. " +
                "\(complianceTotal - compliancePassing) device\(complianceTotal - compliancePassing == 1 ? "" : "s") " +
                "require remediation."
        } else {
            complianceP = "No device compliance data is available in the current snapshot. " +
                "Run <code>jamf-cli pro collect</code> to populate compliance records."
        }

        let patchP: String
        if !patchStatus.isEmpty {
            patchP = "\(belowFullPatch) patch title\(belowFullPatch == 1 ? "" : "s") " +
                "of \(patchStatus.count) tracked \(belowFullPatch == 1 ? "has" : "have") " +
                "devices pending updates."
        } else {
            patchP = "No patch-status data is available in the current snapshot."
        }

        return """
        <section class="content-section" id="exec-summary">
          <h2>Executive Summary</h2>
          <p>\(f.escapeHTML(fleetP))</p>
          <p>\(f.escapeHTML(complianceP))</p>
          <p>\(f.escapeHTML(patchP))</p>
        </section>
        """
    }

    // MARK: - 2. recentFailures

    /// Last 25 device-level patch and update failures sorted by recency.
    func buildRecentFailures(
        patchFailures: [[String: Any]],
        updateFailures: [[String: Any]]
    ) -> String {
        let f = HtmlSectionFormatters.self

        struct FailureRow {
            let device: String
            let serial: String
            let title: String
            let source: String
            let date: String
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
                source: "Patch", date: date, daysAgo: daysAgo(from: date)
            ))
        }

        for item in updateFailures {
            let device = item["name"] as? String ?? ""
            let serial = item["serial"] as? String ?? ""
            let title = item["version"] as? String ?? item["product_key"] as? String ?? ""
            let date = item["updated"] as? String ?? item["last_event"] as? String ?? ""
            rows.append(FailureRow(
                device: device, serial: serial, title: title,
                source: "Update", date: date, daysAgo: daysAgo(from: date)
            ))
        }

        guard !rows.isEmpty else {
            return """
            <section class="content-section" id="recent-failures">
              <h2>Recent Failures</h2>
              \(f.emptyState("No patch or update failures found in the current snapshot. " +
                "Run jamf-cli collect to refresh."))
            </section>
            """
        }

        let sorted = rows.sorted { $0.daysAgo < $1.daysAgo }.prefix(25)
        let tableRows = sorted.map { row -> [String] in
            let daysLabel = row.daysAgo >= 0 ? "\(row.daysAgo)d ago" : "—"
            return [row.device, row.serial, row.title, row.source, daysLabel]
        }

        return """
        <section class="content-section" id="recent-failures">
          <h2>Recent Failures (last \(min(rows.count, 25)))</h2>
          \(f.renderTable(
              headers: ["Device", "Serial", "Title", "Source", "Age"],
              rows: Array(tableRows)
          ))
        </section>
        """
    }

    // MARK: - 3. interventionList

    /// Devices past `thresholds.stale_device_days` with last check-in and primary user.
    func buildInterventionList(computersInventory: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self
        let staleDays = config.thresholds?.resolvedStaleDays ?? 30

        let stale = computersInventory.filter { item -> Bool in
            let raw = inventoryLastContact(item)
            let days = daysAgo(from: raw)
            return days >= staleDays
        }

        guard !stale.isEmpty else {
            return """
            <section class="content-section" id="intervention-list">
              <h2>Intervention Required</h2>
              \(f.emptyState("No devices found exceeding the \(staleDays)-day check-in " +
                "threshold. Update thresholds.stale_device_days in config.yaml to adjust."))
            </section>
            """
        }

        let sorted = stale.sorted { lhsItem, rhsItem -> Bool in
            daysAgo(from: inventoryLastContact(lhsItem)) >
                daysAgo(from: inventoryLastContact(rhsItem))
        }

        let tableRows = sorted.prefix(100).map { item -> [String] in
            let name = inventoryName(item)
            let serial = inventorySerial(item)
            let user = inventoryUsername(item)
            let raw = inventoryLastContact(item)
            let days = daysAgo(from: raw)
            let daysLabel = days >= 0 ? "\(days)" : "—"
            return [name, serial, user, daysLabel]
        }

        return """
        <section class="content-section" id="intervention-list">
          <h2>Intervention Required (\(stale.count) device\(stale.count == 1 ? "" : "s")
            &gt; \(staleDays) days)</h2>
          \(f.renderTable(
              headers: ["Device", "Serial", "Primary User", "Days Since Check-in"],
              rows: Array(tableRows)
          ))
          \(stale.count > 100 ? "<p class=\"empty\">\(stale.count - 100) additional devices " +
            "omitted — see the workbook for the full list.</p>" : "")
        </section>
        """
    }

    // MARK: - 4. patchQueue

    /// Patch titles with `on_other` > 0, ordered by gap size descending.
    func buildPatchQueue(patchStatus: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self

        let pending = patchStatus.filter { item -> Bool in
            (asInt(item["on_other"]) ?? 0) > 0
        }.sorted { lhs, rhs -> Bool in
            (asInt(lhs["on_other"]) ?? 0) > (asInt(rhs["on_other"]) ?? 0)
        }

        guard !pending.isEmpty else {
            return """
            <section class="content-section" id="patch-queue">
              <h2>Patch Queue</h2>
              \(f.emptyState("No patch titles with pending devices found. " +
                "All tracked titles are at the latest version, or patch-status data is absent."))
            </section>
            """
        }

        let tableRows = pending.prefix(50).map { item -> [String] in
            let title = item["title"] as? String ?? ""
            let latest = item["latest"] as? String ?? "—"
            let onOther = asInt(item["on_other"]) ?? 0
            let total = asInt(item["total"]) ?? 0
            let pctStr = item["compliance_pct"] as? String ?? "—"
            return [title, latest, "\(onOther)", "\(total)", pctStr]
        }

        return """
        <section class="content-section" id="patch-queue">
          <h2>Patch Queue (\(pending.count) title\(pending.count == 1 ? "" : "s") pending)</h2>
          \(f.renderTable(
              headers: ["Title", "Latest Version", "Pending", "Total", "Compliance"],
              rows: Array(tableRows)
          ))
        </section>
        """
    }

    // MARK: - 5. auditEvidence

    /// Audit findings grouped by severity, top 10 per severity.
    func buildAuditEvidence(auditFindings: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self

        guard !auditFindings.isEmpty else {
            return """
            <section class="content-section" id="audit-evidence">
              <h2>Audit Evidence</h2>
              \(f.emptyState("No audit findings available. Run " +
                "<code>jamf-cli pro audit --checks all</code> and re-collect."))
            </section>
            """
        }

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
            for item in items.prefix(10) {
                let device = item["device"] as? String
                    ?? item["computer_name"] as? String ?? ""
                guard !device.isEmpty else { continue }
                let slug = deviceAnchorSlug(device)
                if seenDeviceSlugs.insert(slug).inserted {
                    deviceAnchors += "<div class=\"device-anchor\" " +
                        "id=\"audit-dev-\(f.escapeHTML(slug))\"></div>\n"
                }
            }

            let tableRows = items.prefix(10).map { item -> [String] in
                let check = item["check"] as? String
                    ?? item["rule_id"] as? String ?? ""
                let detail = item["detail"] as? String
                    ?? item["message"] as? String ?? ""
                let resource = item["policy"] as? String
                    ?? item["resource"] as? String ?? ""
                return [check, resource, detail]
            }
            parts.append("""
            <div class="audit-severity-group">
              \(deviceAnchors)<h3>\(pill) \(HtmlSectionFormatters.escapeHTML(sev.capitalized)) (\(items.count))</h3>
              \(f.renderTable(
                  headers: ["Check", "Policy / Resource", "Detail"],
                  rows: Array(tableRows)
              ))
              \(items.count > 10 ? "<p class=\"empty\">\(items.count - 10) additional " +
                "\(HtmlSectionFormatters.escapeHTML(sev)) findings omitted.</p>" : "")
            </div>
            """)
        }

        return """
        <section class="content-section" id="audit-evidence">
          <h2>Audit Evidence (\(auditFindings.count) finding\(auditFindings.count == 1 ? "" : "s"))</h2>
          \(parts.joined(separator: "\n"))
        </section>
        """
    }

    // MARK: - 6. exceptionList

    /// Compliance exceptions from `config.yaml`.
    ///
    /// Primary source: `exceptions:` list of structured `ConfigException` entries.
    /// Fallback: `custom_eas` list (legacy behavior from Phase 5), shown with a
    /// migration hint when that path is taken.
    func buildExceptionList() -> String {
        let f = HtmlSectionFormatters.self
        let framework = config.compliance?.displayFramework ?? "Not configured"

        let exceptions = config.exceptions ?? []
        if !exceptions.isEmpty {
            return buildExceptionListFromExceptions(exceptions, framework: framework)
        }

        // Fallback to custom_eas-based rendering with migration tip.
        let eas = config.customEas ?? []
        guard !eas.isEmpty else {
            return """
            <section class="content-section" id="exception-list">
              <h2>Exception List</h2>
              \(f.emptyState("No exceptions configured. " +
                "Add an exceptions: block in config.yaml to document waivers " +
                "for \(f.escapeHTML(framework))."))
            </section>
            """
        }

        let tip = """
        <p class="empty-hint">Tip: prefer a dedicated <code>exceptions:</code> block \
        in <code>config.yaml</code> for documented waivers.</p>
        """

        let tableRows = eas.map { ea -> [String] in
            let typeStr = ea.type.rawValue
            let threshold: String
            switch ea.type {
            case .boolean:
                threshold = ea.trueValue.map { "Pass value: \(f.escapeHTML($0))" } ?? "—"
            case .percentage:
                let warn = ea.warningThreshold.map { "\($0)%" } ?? "—"
                let crit = ea.criticalThreshold.map { "\($0)%" } ?? "—"
                threshold = "Warn: \(warn) / Crit: \(crit)"
            case .version:
                threshold = ea.currentVersions.map { $0.joined(separator: ", ") } ?? "—"
            case .date:
                threshold = ea.warningDays.map { "Warn within \($0) days" } ?? "—"
            case .text:
                threshold = "—"
            }
            return [f.escapeHTML(ea.name), f.escapeHTML(ea.column), typeStr, threshold]
        }

        return """
        <section class="content-section" id="exception-list">
          <h2>Exception List — \(f.escapeHTML(framework))</h2>
          \(tip)
          \(f.renderTable(
              headers: ["EA Name", "Column", "Type", "Threshold / Pass Value"],
              rows: tableRows
          ))
        </section>
        """
    }

    private func buildExceptionListFromExceptions(
        _ exceptions: [ConfigException],
        framework: String
    ) -> String {
        let f = HtmlSectionFormatters.self

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

        let headers = ["ID", "Description", "Signed off by", "Signed off", "Expires", "Linked finding"]
        let ths = headers.map { "<th>\(f.escapeHTML($0))</th>" }.joined()

        return """
        <section class="content-section" id="exception-list">
          <h2>Exception List — \(f.escapeHTML(framework)) (\(exceptions.count))</h2>
          <table class="data-table">
            <thead><tr>\(ths)</tr></thead>
            <tbody>\(tableRows.joined(separator: "\n"))</tbody>
          </table>
        </section>
        """
    }

    // MARK: - 7. assetMap

    /// Per-device asset_tag / serial / department from inventory, paginated at 100.
    func buildAssetMap(computersInventory: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self

        guard !computersInventory.isEmpty else {
            return """
            <section class="content-section" id="asset-map">
              <h2>Asset Map</h2>
              \(f.emptyState("No inventory data available. Run jamf-cli pro collect, " +
                "then re-generate the report."))
            </section>
            """
        }

        let tableRows = computersInventory.prefix(100).map { item -> [String] in
            let name = inventoryName(item)
            let serial = inventorySerial(item)
            let asset = inventoryAssetTag(item)
            let dept = inventoryDepartment(item)
            let building = inventoryBuilding(item)
            return [name, serial, asset, dept, building]
        }

        let total = computersInventory.count
        let overflow = total > 100

        return """
        <section class="content-section" id="asset-map">
          <h2>Asset Map (\(total) device\(total == 1 ? "" : "s"))</h2>
          \(f.renderTable(
              headers: ["Device Name", "Serial", "Asset Tag", "Department", "Building"],
              rows: Array(tableRows)
          ))
          \(overflow ? "<p class=\"empty\">\(total - 100) additional devices omitted. " +
            "See the Asset Inventory workbook for the full list.</p>" : "")
        </section>
        """
    }

    // MARK: - 8. warrantyTable

    /// Devices grouped by warranty status: expired / expiring < 90 days / current.
    func buildWarrantyTable(computersInventory: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self

        let withWarranty = computersInventory.filter { item -> Bool in
            let raw = inventoryWarrantyExpires(item)
            return !raw.trimmingCharacters(in: .whitespaces).isEmpty
        }

        guard !withWarranty.isEmpty else {
            return """
            <section class="content-section" id="warranty-table">
              <h2>Warranty Status</h2>
              \(f.emptyState("No warranty_expires field found in inventory data. " +
                "Map the field under columns.warranty_expires in config.yaml, or ensure " +
                "jamf-cli inventory-csv exports that field."))
            </section>
            """
        }

        struct WarrantyRow {
            let name: String; let serial: String; let expires: String; let daysLeft: Int
        }
        let rows: [WarrantyRow] = withWarranty.map { item in
            let name = inventoryName(item)
            let serial = inventorySerial(item)
            let raw = inventoryWarrantyExpires(item)
            let days = daysUntil(raw)
            return WarrantyRow(name: name, serial: serial, expires: raw, daysLeft: days)
        }

        let expired = rows.filter { $0.daysLeft < 0 }
            .sorted { abs($0.daysLeft) > abs($1.daysLeft) }
        let expiring = rows.filter { $0.daysLeft >= 0 && $0.daysLeft < 90 }
            .sorted { $0.daysLeft < $1.daysLeft }
        let current = rows.filter { $0.daysLeft >= 90 }
            .sorted { $0.daysLeft < $1.daysLeft }

        func groupBlock(_ title: String, _ group: [WarrantyRow]) -> String {
            guard !group.isEmpty else { return "" }
            let tableRows = group.prefix(25).map { row -> [String] in
                let status = row.daysLeft < 0 ? "Expired" : "\(row.daysLeft) days"
                return [row.name, row.serial, row.expires, status]
            }
            return """
            <h3>\(f.escapeHTML(title)) (\(group.count))</h3>
            \(f.renderTable(
                headers: ["Device", "Serial", "Expiry Date", "Status"],
                rows: Array(tableRows)
            ))
            \(group.count > 25 ? "<p class=\"empty\">\(group.count - 25) more — " +
              "see workbook for full list.</p>" : "")
            """
        }

        return """
        <section class="content-section" id="warranty-table">
          <h2>Warranty Status</h2>
          \(groupBlock("Expired", expired))
          \(groupBlock("Expiring within 90 days", expiring))
          \(groupBlock("Current", current))
        </section>
        """
    }

    // MARK: - 9. purchaseCohorts

    /// Devices grouped by purchase-date year with a CSS bar chart.
    func buildPurchaseCohorts(computersInventory: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self

        let withDate = computersInventory.compactMap { item -> (String, String)? in
            let name = inventoryName(item)
            let raw = inventoryPurchaseDate(item)
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (name, raw)
        }

        guard !withDate.isEmpty else {
            return """
            <section class="content-section" id="purchase-cohorts">
              <h2>Purchase Cohorts</h2>
              \(f.emptyState("No purchase_date field found in inventory data. " +
                "Map the field under columns.purchase_date in config.yaml, or ensure " +
                "jamf-cli inventory-csv exports that field."))
            </section>
            """
        }

        // Group by year
        var byYear: [String: Int] = [:]
        for (_, raw) in withDate {
            let year = String(raw.prefix(4))
            guard !year.isEmpty, year.allSatisfy(\.isNumber) else { continue }
            byYear[year, default: 0] += 1
        }

        let sortedYears = byYear.keys.sorted()
        let maxCount = byYear.values.max() ?? 1

        let bars = sortedYears.map { year -> String in
            let count = byYear[year] ?? 0
            let pct = Int((Double(count) / Double(maxCount) * 100).rounded())
            return """
            <div class="cohort-bar-row">
              <span class="cohort-bar-key">\(f.escapeHTML(year))</span>
              <div class="cohort-bar-bg">
                <div class="cohort-bar-fill" style="width:\(pct)%" aria-label="\(count) devices"></div>
              </div>
              <span class="cohort-bar-n">\(count)</span>
            </div>
            """
        }.joined(separator: "\n")

        let tableRows = sortedYears.map { year -> [String] in
            [year, "\(byYear[year] ?? 0)"]
        }

        return """
        <section class="content-section" id="purchase-cohorts">
          <h2>Purchase Cohorts (\(withDate.count) device\(withDate.count == 1 ? "" : "s"))</h2>
          <div class="cohort-bar-section">\(bars)</div>
          \(f.renderTable(headers: ["Year", "Devices"], rows: tableRows))
        </section>
        """
    }

    // MARK: - 10. buildingBreakdown

    /// Device count per building with a CSS bar chart.
    func buildBuildingBreakdown(computersInventory: [[String: Any]]) -> String {
        buildGroupBreakdown(
            computersInventory: computersInventory,
            field: "building",
            fallbackFields: ["buildingName"],
            sectionID: "building-breakdown",
            title: "Building Breakdown",
            emptyHint: "No building field found in inventory data. " +
                "Map the field under columns.building in config.yaml."
        )
    }

    // MARK: - 11. departmentBreakdown

    /// Device count per department with a CSS bar chart.
    func buildDepartmentBreakdown(computersInventory: [[String: Any]]) -> String {
        buildGroupBreakdown(
            computersInventory: computersInventory,
            field: "department",
            fallbackFields: ["departmentName"],
            sectionID: "department-breakdown",
            title: "Department Breakdown",
            emptyHint: "No department field found in inventory data. " +
                "Map the field under columns.department in config.yaml."
        )
    }

    // Shared CSS-bar breakdown builder for building / department.
    private func buildGroupBreakdown(
        computersInventory: [[String: Any]],
        field: String,
        fallbackFields: [String],
        sectionID: String,
        title: String,
        emptyHint: String
    ) -> String {
        let f = HtmlSectionFormatters.self

        var counts: [String: Int] = [:]
        for item in computersInventory {
            // Use dedicated accessors for building/department to handle nested shape.
            var value: String
            if field == "building" {
                value = inventoryBuilding(item)
                if value == "—" { value = "" }
            } else if field == "department" {
                value = inventoryDepartment(item)
                if value == "—" { value = "" }
            } else {
                value = item[field] as? String ?? ""
                if value.isEmpty {
                    for fb in fallbackFields {
                        if let v = item[fb] as? String, !v.isEmpty { value = v; break }
                    }
                }
            }
            let key = value.isEmpty ? "(unassigned)" : value
            counts[key, default: 0] += 1
        }

        guard !counts.isEmpty else {
            return """
            <section class="content-section" id="\(sectionID)">
              <h2>\(HtmlSectionFormatters.escapeHTML(title))</h2>
              \(f.emptyState(emptyHint))
            </section>
            """
        }

        let sorted = counts.sorted { $0.value > $1.value }
        let maxCount = sorted.first?.value ?? 1

        let bars = sorted.map { key, count -> String in
            let pct = Int((Double(count) / Double(maxCount) * 100).rounded())
            return """
            <div class="cohort-bar-row">
              <span class="cohort-bar-key">\(f.escapeHTML(key))</span>
              <div class="cohort-bar-bg">
                <div class="cohort-bar-fill" style="width:\(pct)%"
                     aria-label="\(f.escapeHTML(key)): \(count) devices"></div>
              </div>
              <span class="cohort-bar-n">\(count)</span>
            </div>
            """
        }.joined(separator: "\n")

        let tableRows = sorted.map { key, count -> [String] in [key, "\(count)"] }

        return """
        <section class="content-section" id="\(sectionID)">
          <h2>\(HtmlSectionFormatters.escapeHTML(title))</h2>
          <div class="cohort-bar-section">\(bars)</div>
          \(f.renderTable(headers: [title.components(separatedBy: " ").first ?? "Group",
                                    "Devices"], rows: Array(tableRows)))
        </section>
        """
    }

    // MARK: - 12. protectAlerts

    /// Protect alerts grouped by severity, capped by `html.section_limits.protect_alerts`
    /// (default 25, bounded [1, 200]).
    func buildProtectAlerts(protectDataDir: URL?) -> String {
        let f = HtmlSectionFormatters.self
        let cap = config.html?.sectionLimits?.resolvedProtectAlerts ?? 25

        guard let dir = protectDataDir else {
            return """
            <section class="content-section" id="protect-alerts">
              <h2>Protect Alerts</h2>
              \(f.emptyState("Jamf Protect is not configured. Set protect.enabled: true " +
                "in config.yaml and provide protect.profile to enable Protect data collection."))
            </section>
            """
        }

        let alerts = loadProtectJSON(kind: "alerts", dataDir: dir)

        guard !alerts.isEmpty else {
            return """
            <section class="content-section" id="protect-alerts">
              <h2>Protect Alerts</h2>
              \(f.emptyState("No Protect alerts found in the cache at \(dir.lastPathComponent)/. " +
                "Run jamf-cli protect collect to populate alert data."))
            </section>
            """
        }

        var bySeverity: [String: [[String: Any]]] = [:]
        for alert in alerts {
            let sev = (alert["severity"] as? String ?? "unknown").lowercased()
            bySeverity[sev, default: []].append(alert)
        }

        let severityOrder = ["critical", "high", "medium", "low", "info", "unknown"]
        let orderedKeys = severityOrder.filter { bySeverity[$0] != nil }
            + bySeverity.keys.filter { !severityOrder.contains($0) }.sorted()

        var parts: [String] = []
        var totalShown = 0
        for sev in orderedKeys {
            guard let sevAlerts = bySeverity[sev], !sevAlerts.isEmpty else { continue }
            let take = max(0, min(sevAlerts.count, cap - totalShown))
            guard take > 0 else { continue }

            let pill = f.renderSeverityPill(sev)
            let alertRows = sevAlerts.prefix(take).map { alert -> String in
                let rawDevice = alert["device"] as? String
                    ?? alert["computer_name"] as? String ?? ""
                let description = alert["name"] as? String
                    ?? alert["title"] as? String
                    ?? alert["description"] as? String ?? "—"
                let date = alert["created"] as? String
                    ?? alert["timestamp"] as? String ?? "—"

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
                    "<td>\(f.escapeHTML(String(date.prefix(10))))</td></tr>"
            }
            let alertTable = """
            <table class="data-table">
              <thead><tr><th>Device</th><th>Alert</th><th>Date</th></tr></thead>
              <tbody>\(alertRows.joined(separator: "\n"))</tbody>
            </table>
            """
            totalShown += take
            parts.append("""
            <div class="audit-severity-group">
              <h3>\(pill) (\(sevAlerts.count))</h3>
              \(alertTable)
            </div>
            """)
        }

        return """
        <section class="content-section" id="protect-alerts">
          <h2>Protect Alerts (showing \(totalShown) of \(alerts.count))</h2>
          \(parts.joined(separator: "\n"))
        </section>
        """
    }

    // MARK: - 13. insightsDrift

    /// Protect insights snapshot comparison, using up to
    /// `html.section_limits.insights_drift_snapshots` (default 2, bounded [1, 12]) snapshots.
    ///
    /// When more than two snapshots are requested, the table gains one column per additional
    /// snapshot labelled "N ago" (oldest first, current last).
    func buildInsightsDrift(protectDataDir: URL?) -> String {
        let f = HtmlSectionFormatters.self
        let snapshotCap = config.html?.sectionLimits?.resolvedInsightsDriftSnapshots ?? 2

        guard let dir = protectDataDir else {
            return """
            <section class="content-section" id="insights-drift">
              <h2>Insights Drift</h2>
              \(f.emptyState("Jamf Protect is not configured. Set protect.enabled: true " +
                "in config.yaml to enable Protect data collection."))
            </section>
            """
        }

        let allSnapshots = loadProtectInsightSnapshots(dataDir: dir)

        guard allSnapshots.count >= 2 else {
            let count = allSnapshots.count
            return """
            <section class="content-section" id="insights-drift">
              <h2>Insights Drift</h2>
              \(f.emptyState("Comparison requires N≥2 cached snapshots; " +
                "\(count) snapshot\(count == 1 ? "" : "s") found. " +
                "Run jamf-cli protect collect on two or more separate days to enable drift charts."))
            </section>
            """
        }

        // Take the most recent `snapshotCap` snapshots; fall back to all available if fewer.
        let window = Array(allSnapshots.suffix(snapshotCap))

        // Collect all insight keys across the window.
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
                let stepsBack = window.count - 1 - idx
                headers.append("\(stepsBack) ago")
            }
        }

        let tableRows = insightKeys.map { key -> [String] in
            var row = [f.escapeHTML(key)]
            for snapshot in window {
                row.append(snapshot[key].map { f.escapeHTML("\($0)") } ?? "—")
            }
            return row
        }

        return """
        <section class="content-section" id="insights-drift">
          <h2>Insights Drift (\(window.count) of \(allSnapshots.count) snapshots)</h2>
          \(f.renderTable(headers: headers, rows: tableRows))
        </section>
        """
    }

    // MARK: - 14. agentHealth

    /// Per-security-agent (CrowdStrike, etc.) installed/missing/unknown counts
    /// from the computers inventory cross-referenced with config.security_agents.
    func buildAgentHealth(computersInventory: [[String: Any]]) -> String {
        let f = HtmlSectionFormatters.self
        let agents = config.securityAgents ?? []

        guard !agents.isEmpty else {
            return """
            <section class="content-section" id="agent-health">
              <h2>Security Agent Health</h2>
              \(f.emptyState("No security agents configured. Add entries under " +
                "security_agents in config.yaml to track CrowdStrike Falcon and other agents."))
            </section>
            """
        }

        guard !computersInventory.isEmpty else {
            return """
            <section class="content-section" id="agent-health">
              <h2>Security Agent Health</h2>
              \(f.emptyState("No inventory data available. Run jamf-cli pro collect to " +
                "populate device inventory."))
            </section>
            """
        }

        var tableRows: [[String]] = []
        var barCards: [HtmlSectionFormatters.SectionCard] = []

        for agent in agents {
            var installed = 0
            var missing = 0
            var unknown = 0

            for device in computersInventory {
                let raw = inventoryEAValue(device, column: agent.column)
                if raw.isEmpty {
                    unknown += 1
                } else if raw.lowercased().contains(agent.connectedValue.lowercased()) {
                    installed += 1
                } else {
                    missing += 1
                }
            }

            let total = installed + missing + unknown
            let pct = total > 0 ? Double(installed) / Double(total) * 100 : 0
            tableRows.append([
                agent.name,
                "\(installed)",
                "\(missing)",
                "\(unknown)",
                String(format: "%.1f%%", pct),
            ])
            barCards.append(HtmlSectionFormatters.SectionCard(
                name: agent.name,
                value: String(format: "%.0f%%", pct),
                sublabel: "\(installed) of \(total) installed"
            ))
        }

        return """
        <section class="content-section" id="agent-health">
          <h2>Security Agent Health</h2>
          \(f.renderCardGrid(cards: barCards))
          \(f.renderTable(
              headers: ["Agent", "Installed", "Missing", "Unknown", "Coverage"],
              rows: tableRows
          ))
        </section>
        """
    }

    // MARK: - Protect helpers

    /// Load JSON from the Protect-specific data directory.
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
        guard let newest = candidates.max(by: { lhs, rhs in
            let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return a < b
        }) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: newest)
        } catch {
            AppLogger.engine.warning(
                "loadProtectJSON: could not read '\(newest.path, privacy: .private)' — \(error, privacy: .private)"
            )
            return []
        }
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            AppLogger.engine.warning(
                "loadProtectJSON: JSON parse failed for '\(newest.path, privacy: .private)'"
            )
            return []
        }
        return result
    }

    /// Load all Protect insight snapshot files, returning them in chronological order.
    private func loadProtectInsightSnapshots(dataDir: URL) -> [[String: Any]] {
        let fm = FileManager.default
        let subdir = dataDir.appendingPathComponent("insights", isDirectory: true)
        guard fm.fileExists(atPath: subdir.path),
              let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return a < b
            }
            .compactMap { url -> [String: Any]? in
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    AppLogger.engine.warning(
                        // swiftlint:disable:next line_length
                        "loadProtectInsightSnapshots: could not read \(url.path, privacy: .private) — \(error, privacy: .private)"
                    )
                    return nil
                }
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    AppLogger.engine.warning(
                        "loadProtectInsightSnapshots: JSON parse failed for '\(url.path, privacy: .private)'"
                    )
                    return nil
                }
                return parsed
            }
    }

    // MARK: - 15. cleanupAnalysis

    /// Jamf instance hygiene: disabled policies, unscoped policies/profiles,
    /// unused packages, and unused scripts.
    ///
    /// Requires per-policy detail fields (`general.enabled`, `scope.*`,
    /// `package_configuration.packages`, `scripts`) that are only present when
    /// jamf-cli collects individual policy detail records. The flat
    /// `classic-policies` list snapshot (id + name only) cannot satisfy these
    /// requirements. When no detail fields are found, the section renders an
    /// honest "detail not available" note rather than incorrect "none found" results.
    func buildCleanupAnalysis(
        classicPolicies: [[String: Any]],
        classicProfiles: [[String: Any]],
        packages: [[String: Any]],
        scripts: [[String: Any]]
    ) -> String {
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
            let policyNote = classicPolicies.isEmpty
                ? "No classic-policies snapshot available."
                : "classic-policies snapshot has \(classicPolicies.count) " +
                  "record\(classicPolicies.count == 1 ? "" : "s") (id + name only) — " +
                  "per-policy detail required for enabled/scope/package/script analysis " +
                  "is not present in this snapshot."
            return """
            <section class="content-section" id="cleanup-analysis">
              <h2>Cleanup Analysis</h2>
              \(f.emptyState(policyNote +
                " Run jamf-cli pro collect to refresh, or check that per-policy detail " +
                "collection is enabled."))
            </section>
            """
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
                body = f.renderList(items: items)
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

        let detailNote: String
        let policiesWithDetail = classicPolicies.filter { $0["general"] != nil }.count
        let profilesWithDetail = classicProfiles.filter { $0["general"] != nil }.count
        if policiesWithDetail > 0 || profilesWithDetail > 0 {
            detailNote = "Based on \(policiesWithDetail) " +
                "polic\(policiesWithDetail == 1 ? "y" : "ies") and " +
                "\(profilesWithDetail) profile\(profilesWithDetail == 1 ? "" : "s") " +
                "with cached detail."
        } else {
            detailNote = ""
        }

        return """
        <section class="content-section" id="cleanup-analysis">
          <h2>Cleanup Analysis</h2>
          \(detailNote.isEmpty ? "" : "<p class=\"cleanup-note\">\(f.escapeHTML(detailNote))</p>")
          <div class="cleanup-tabs" role="tablist" aria-label="Cleanup categories">
            \(tabs)
          </div>
          \(panes)
        </section>
        """
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

    // MARK: - 16. timeline

    /// OS adoption and security metric trends from workspace `summary_*.json` snapshots.
    ///
    /// Reads from `<dataDir>/../snapshots/summaries/summary_*.json` — the same
    /// directory `TrendStore` reads, but parsed independently (Engine layer must not
    /// depend on Services). Plots available scalar series: total devices,
    /// FileVault %, SIP %, and compliance %.
    ///
    /// Note: Python's `_render_timeline_section` renders per-OS-version lines from a
    /// `{ts, versions:[{v,c}]}` history file. Summary snapshots carry only aggregate
    /// scalars (no per-version counts), so per-version trend lines cannot be reproduced
    /// from this data source; scalar metric trends are rendered instead.
    func buildTimelineSection() -> String {
        let f = HtmlSectionFormatters.self
        let (summaries, skipped) = loadSummarySnapshots()
        let skippedNote = skipped > 0
            ? "<p class=\"timeline-warn\">\(skipped) snapshot file\(skipped == 1 ? "" : "s") could not be parsed.</p>"
            : ""

        guard !summaries.isEmpty else {
            return HtmlSectionFormatters.emptySection(
                title: "Historical Trends",
                dataKind: "snapshots/summaries/summary_*.json"
            ) + skippedNote
        }

        // Build the trend table rows (date + key metrics), newest last.
        let tableRows: [[String]] = summaries.map { s in
            let fvStr = s.fileVaultPct.map { String(format: "%.1f%%", $0) } ?? "—"
            let sipStr = s.sipPct.map { String(format: "%.1f%%", $0) } ?? "—"
            let compStr = s.compliancePct.map { String(format: "%.1f%%", $0) } ?? "—"
            return [
                f.escapeHTML(s.date),
                f.escapeHTML("\(s.totalDevices)"),
                f.escapeHTML(fvStr),
                f.escapeHTML(sipStr),
                f.escapeHTML(compStr),
            ]
        }

        let tableHTML = f.renderTable(
            headers: ["Date", "Total Devices", "FileVault", "SIP", "Compliance"],
            rows: tableRows
        )

        if summaries.count == 1 {
            return """
            <section class="content-section" id="timeline">
              <h2>Historical Trends</h2>
              <p class="empty-note">Only 1 snapshot available — collect more runs to see trends.</p>
              \(skippedNote)
              \(tableHTML)
            </section>
            """
        }

        let svgHTML = renderTimelineSVG(summaries: summaries)

        return """
        <section class="content-section" id="timeline">
          <h2>Historical Trends</h2>
          <p class="timeline-note">\(f.escapeHTML("\(summaries.count) snapshot\(summaries.count == 1 ? "" : "s")")) &middot; metrics from workspace summaries</p>
          \(skippedNote)
          \(svgHTML)
          \(tableHTML)
        </section>
        """
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
            .filter { $0.lastPathComponent.hasPrefix("summary_") && $0.pathExtension == "json" }

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
            AppLogger.engine.warning(
                "loadSummarySnapshots: \(skipped, privacy: .public) snapshot file(s) could not be parsed and were skipped"
            )
        }

        return (snapshots: snapshots.sorted { $0.date < $1.date }, skipped: skipped)
    }

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
            // Dots for all non-nil points
            for i in 0 ..< n {
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

    // MARK: - Date helpers

    /// Days until a future date (positive = future, negative = past/expired).
    func daysUntil(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Int.min }
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            df.dateFormat = fmt
            if let date = df.date(from: trimmed) {
                return Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? Int.min
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? Int.min
        }
        return Int.min
    }
}

// MARK: - buildSectionMap extension

extension HtmlReport {

    /// Register all 16 section renderers into the section map produced by `buildSectionMap`.
    ///
    /// Called from `buildSectionMap` after the original 9 entries are populated.
    /// Returns a dictionary that merges into the base map.
    func buildNewSectionEntries(
        security: [[String: Any]],
        deviceCompliance: [[String: Any]],
        patchStatus: [[String: Any]],
        patchFailures: [[String: Any]],
        updateFailures: [[String: Any]],
        computersInventory: [[String: Any]],
        auditFindings: [[String: Any]],
        classicPolicies: [[String: Any]] = [],
        classicProfiles: [[String: Any]] = [],
        packages: [[String: Any]] = [],
        scripts: [[String: Any]] = []
    ) -> [SectionID: String] {
        let secSummary = security.first { $0["section"] as? String == "summary" }
        let secData = secSummary?["data"] as? [String: Any] ?? [:]
        let totalDevices = asInt(secData["total_devices"]) ?? overviewDeviceCount([])
        let fileVaultPct = computePct(asInt(secData["filevault_encrypted"]),
                                      total: totalDevices)
        let sipPct = computePct(asInt(secData["sip_enabled"]), total: totalDevices)
        let firewallPct = computePct(asInt(secData["firewall_enabled"]),
                                     total: totalDevices)

        let protectDir: URL? = {
            guard config.protect?.isEnabled == true else { return nil }
            let dir = config.protect?.resolvedDataDir ?? "jamf-cli-data/protect"
            if dir.hasPrefix("/") {
                return URL(fileURLWithPath: dir)
            }
            return dataDir.deletingLastPathComponent().appendingPathComponent(dir)
        }()

        return [
            .execSummary: buildExecSummary(
                totalDevices: totalDevices,
                fileVaultPct: fileVaultPct,
                sipPct: sipPct,
                firewallPct: firewallPct,
                deviceCompliance: deviceCompliance,
                patchStatus: patchStatus
            ),
            .recentFailures: buildRecentFailures(
                patchFailures: patchFailures,
                updateFailures: updateFailures
            ),
            .interventionList: buildInterventionList(
                computersInventory: computersInventory
            ),
            .patchQueue: buildPatchQueue(patchStatus: patchStatus),
            .auditEvidence: buildAuditEvidence(auditFindings: auditFindings),
            .exceptionList: buildExceptionList(),
            .assetMap: buildAssetMap(computersInventory: computersInventory),
            .warrantyTable: buildWarrantyTable(computersInventory: computersInventory),
            .purchaseCohorts: buildPurchaseCohorts(
                computersInventory: computersInventory
            ),
            .buildingBreakdown: buildBuildingBreakdown(
                computersInventory: computersInventory
            ),
            .departmentBreakdown: buildDepartmentBreakdown(
                computersInventory: computersInventory
            ),
            .protectAlerts: buildProtectAlerts(protectDataDir: protectDir),
            .insightsDrift: buildInsightsDrift(protectDataDir: protectDir),
            .agentHealth: buildAgentHealth(computersInventory: computersInventory),
            .cleanupAnalysis: buildCleanupAnalysis(
                classicPolicies: classicPolicies,
                classicProfiles: classicProfiles,
                packages: packages,
                scripts: scripts
            ),
            .timeline: buildTimelineSection(),
            .osCurrency: buildOSCurrencySection(),
        ]
    }

    // MARK: - OS Currency section

    /// Build the OS Currency HTML section from cached SOFA feeds.
    /// Renders a summary table; renders a note row when no feeds are cached.
    func buildOSCurrencySection() -> String {
        let sofaSnapshot = SOFAFeedService.load(dataDir: dataDir)
        guard !sofaSnapshot.rows.isEmpty else {
            let note = "SOFA feed unavailable — run Collect to refresh or check network access."
            return "<div class=\"section\" id=\"os-currency\"><h2>OS Currency</h2>" +
                   "<p class=\"note\">\(HtmlSectionFormatters.escapeHTML(note))</p></div>"
        }

        // HTML section shows SOFA latest data only — fleet counts require the
        // security/mobile-inventory snapshots, which are not joined here.
        let headers = ["Platform", "OS Family", "Latest Version", "Released",
                       "Days Since Release", "CVEs Exploited"]
        var rowsHTML = ""
        for entry in sofaSnapshot.rows {
            let days = entry.daysSinceRelease.map { String($0) } ?? "—"
            let released = entry.releaseDate.isEmpty ? "—" : entry.releaseDate
            let cveStyle = entry.activelyExploitedCVEs > 0 ? " style=\"color:var(--red)\"" : ""
            rowsHTML += "<tr>"
            rowsHTML += "<td>\(HtmlSectionFormatters.escapeHTML(entry.platform))</td>"
            rowsHTML += "<td>\(HtmlSectionFormatters.escapeHTML(entry.osFamily))</td>"
            rowsHTML += "<td>\(HtmlSectionFormatters.escapeHTML(entry.productVersion))</td>"
            rowsHTML += "<td>\(HtmlSectionFormatters.escapeHTML(released))</td>"
            rowsHTML += "<td>\(HtmlSectionFormatters.escapeHTML(days))</td>"
            rowsHTML += "<td\(cveStyle)>\(entry.activelyExploitedCVEs)</td>"
            rowsHTML += "</tr>"
        }

        let headerCells = headers
            .map { "<th>\(HtmlSectionFormatters.escapeHTML($0))</th>" }
            .joined()
        return "<div class=\"section\" id=\"os-currency\">" +
               "<h2>OS Currency</h2>" +
               "<p class=\"note\">Source: SOFA (sofa.macadmins.io)</p>" +
               "<div class=\"table-wrapper\"><table>" +
               "<thead><tr>\(headerCells)</tr></thead>" +
               "<tbody>\(rowsHTML)</tbody>" +
               "</table></div></div>"
    }

}
