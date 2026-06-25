import Foundation
import CryptoKit

// MARK: - CoreDashboard

/// Swift port of the Python `CoreDashboard` class.
/// Generates Excel sheets from cached jamf-cli JSON snapshots. No CSV required.
///
/// Each `write*` method is a single sheet. Methods follow the Python naming convention
/// exactly so diffs against the Python source are readable.
struct CoreDashboard: Sendable {

    let config: ReportConfig
    let dataDir: URL
    let workbook: Workbook
    /// Provenance captured at run start. Injected by the caller (e.g. `ReportEngine`).
    /// When nil, the Cover sheet shows placeholder values for provenance fields.
    let provenance: Provenance?

    init(
        config: ReportConfig,
        dataDir: URL,
        workbook: Workbook,
        provenance: Provenance? = nil
    ) {
        self.config = config
        self.dataDir = dataDir
        self.workbook = workbook
        self.provenance = provenance
    }

    private var accentColor: String { config.branding?.resolvedAccentColor ?? "#2D5EA2" }
    private var orgName: String { config.branding?.resolvedOrgName ?? "" }

    // MARK: - Sheet plan

    /// Ordered list of jamf-cli-driven sheet names and write closures.
    ///
    /// **Order matters** — this sequence sets the Excel tab order the user sees. Do not
    /// reorder existing sheets without updating `SheetOrderTests.swift` (which pins this
    /// contract) and verifying the new order is intentional.
    ///
    /// **Structure:** exec-priority sheets (Cover → Audit Summary) come first so directors
    /// find key numbers in the first seven tabs. Inventory, configuration health, device
    /// health, update/patch details, platform/DDM, and Protect blocks follow in that order.
    ///
    /// **All sheets in this plan are always included** — they gracefully skip (write a
    /// "no data" placeholder) when the underlying jamf-cli data is absent or malformed.
    /// Config-gating via `sheets.only` / `sheets.skip` is applied externally in `writeAll`.
    ///
    /// **Adding a new sheet:** append to the appropriate group comment, update the group
    /// range comment (e.g., "sheets 28–32"), and add a corresponding test in
    /// `SheetOrderTests.swift`.
    var sheetPlan: [(name: String, write: () throws -> Void)] {
        [
            // --- Framing / exec-priority (sheets 1–8) ---
            ("Executive Summary", writeExecutiveSummary),
            ("Cover", writeCoverSheet),
            ("Compliance Posture", writeCompliancePosture),
            ("Fleet Overview", writeOverview),
            ("Security Posture", writeSecurity),
            ("Patch Compliance", writePatch),
            ("Device Compliance", writeDeviceCompliance),
            ("Audit Summary", writeAuditSummary),
            // --- Inventory & hardware (sheets 8–11) ---
            ("Inventory Summary", writeInventorySummary),
            ("Hardware Models", writeHardwareModels),
            ("Mobile Fleet Summary", writeMobileFleetSummary),
            ("Mobile Inventory", writeMobileInventory),
            // --- Configuration health (sheets 12–20) ---
            ("Policy Health", writePolicyHealth),
            ("Profile Status", writeProfileStatus),
            ("Mobile Config Profiles", writeMobileConfigProfiles),
            ("App Status", writeAppStatus),
            ("Software Installs", writeSoftwareInstalls),
            ("Package Lifecycle", writePackageLifecycle),
            ("EA Coverage", writeEACoverage),
            ("EA Definitions", writeEADefinitions),
            ("Environment Stats", writeEnvironmentStats),
            // --- Device health (sheets 21–23) ---
            ("Check-in Health", writeCheckinHealth),
            ("Active Devices", writeActiveDevices),
            ("Group Hygiene", writeGroupHygiene),
            // --- Update & patch details (sheets 24–27) ---
            ("Patch Failures", writePatchFailures),
            ("Update Status", writeUpdateStatus),
            ("Update Failures", writeUpdateFailures),
            ("Smart Groups", writeSmartGroups),
            // --- Platform / DDM (sheets 28–31, optional) ---
            ("Compliance Devices", writeComplianceDevices),
            ("Compliance Rules", writeComplianceRules),
            ("DDM Status", writeDDMStatus),
            ("Blueprint Status", writeBlueprintStatus),
            // --- Protect (sheets 32–39, optional) ---
            ("Protect Overview", writeProtectOverview),
            ("Protect Alerts", writeProtectAlerts),
            ("Protect Computers", writeProtectComputers),
            ("Protect Insights", writeProtectInsights),
            ("Protect Plans", writeProtectPlans),
            ("Protect Threat Overview", writeProtectThreatOverview),
            // --- Parity / detail sheets (sheets 38–41) ---
            ("Patch Summary Dashboard", writePatchSummaryDashboard),
            ("Device Security State", writeDeviceSecurityState),
            ("Mobile Supervision Status", writeMobileSupervisionStatus),
            // --- OS currency (sheet 42) ---
            ("OS Currency", writeOSCurrency),
            // --- mSCP / STIG compliance (sheets 43–44) ---
            ("mSCP Compliance", writeMSCPCompliance),
            ("Compliance Trend", writeComplianceTrend),
        ]
    }

    /// Write all sheets; skip silently on missing/malformed data.
    ///
    /// Applies `sheets.only`, `sheets.skip`, and `sheets.order` from config before
    /// iterating. `selectedNames` further narrows to a caller-specified subset (used by
    /// the UI when the user wants a single sheet regenerated).
    /// Returns list of sheet names successfully written and any unexpected failures.
    @discardableResult
    func writeAll(selectedNames: Set<String>? = nil) -> (written: [String], failures: [SheetFailure]) {
        let effectivePlan = (config.sheets ?? SheetsConfig()).applyTo(sheetPlan)
        var written: [String] = []
        var failures: [SheetFailure] = []
        for (name, fn) in effectivePlan {
            if let sel = selectedNames,
               !sel.contains(name.lowercased()) {
                continue
            }
            do {
                try fn()
                written.append(name)
            } catch let skippable as SheetSkippable {
                // Cached data absent — expected for jamf-cli snapshots not yet collected.
                print("  [skip] \(name): \(skippable)")
            } catch {
                let label = "\(type(of: error)): \(error)"
                failures.append(SheetFailure(sheet: name, error: label))
                print("  [fail] \(name): unexpected error — \(label)")
            }
        }
        if let logoData = CSVDashboard.loadLogoData(from: config) {
            for name in written {
                if let ws = workbook.sheet(named: name) {
                    ws.insertImage(row: 0, col: 0, data: logoData,
                                   filename: "logo.png", xScale: 1.0, yScale: 1.0)
                }
            }
        }
        return (written, failures)
    }

    // MARK: - Sheet title helper

    private func t(_ base: String) -> String {
        orgName.isEmpty ? base : "\(orgName) \u{2014} \(base)"
    }

    // MARK: - Fleet Overview
    // Source: `jamf-cli pro overview --output json`

    func writeOverview() throws {
        let data = try loadLatestJSON(names: ["overview"])
        let ws = workbook.addSheet("Fleet Overview")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Fleet Overview"),
                                      subtitle: "Generated: \(ts)", ncols: 4)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 42)
        ws.setColumnWidth(2, 2, 24)
        ws.setColumnWidth(3, 3, 20)

        let rows = extractOverviewRows(data)
        let hasStatus = rows.contains { !($0.status ?? "").isEmpty }
        let headers = hasStatus
            ? ["Section", "Resource", "Value", "Status"]
            : ["Section", "Resource", "Value"]
        for (col, header) in headers.enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1

        for item in rows {
            ws.write(item.section, row: row, col: 0, format: .cell)
            ws.write(item.resource, row: row, col: 1, format: .cell)
            ws.write(item.value?.stringValue ?? "", row: row, col: 2, format: .cell)
            if hasStatus {
                let fmt: CellFormat
                switch (item.status ?? "").lowercased() {
                case "red":    fmt = .red
                case "yellow": fmt = .yellow
                default:       fmt = .cell
                }
                ws.write(item.status ?? "", row: row, col: 3, format: fmt)
            }
            row += 1
        }
    }

    private func extractOverviewRows(_ raw: Any) -> [OverviewRow] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.compactMap { dict -> OverviewRow? in
            guard let resource = dict["resource"] as? String else { return nil }
            let section = dict["section"] as? String ?? ""
            let value = dict["value"].map { raw -> AnyCodable in
                if let s = raw as? String { return AnyCodable(s) }
                if let i = raw as? Int { return AnyCodable(i) }
                if let d = raw as? Double { return AnyCodable(d) }
                if let b = raw as? Bool { return AnyCodable(b) }
                return AnyCodable(nil)
            }
            let status = dict["status"] as? String
            return OverviewRow(section: section, resource: resource, value: value, status: status)
        }
    }

    // MARK: - Security Posture
    // Source: `jamf-cli pro report security --output json`

    func writeSecurity() throws {
        // Migrated to typed decoder (SecurityReportItem). See migration recipe in
        // loadLatestTyped(names:as:) for the pattern.
        guard let items = loadLatestTyped(names: ["security"], as: [SecurityReportItem].self) else {
            throw CoreDashboardError.noCachedData(names: ["security"])
        }

        let ws = workbook.addSheet("Security Posture")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Security Posture"),
                                      subtitle: snapshotSubtitle(names: ["security"], generated: ts),
                                      ncols: 5)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 20)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 12)

        var summaryData: SecuritySummaryData?
        var osVersionRows: [SecurityOSVersion] = []

        for item in items {
            switch item {
            case .summary(let s): summaryData = s.data
            case .osVersion(let v): osVersionRows.append(v)
            case .device, .unknown: break
            }
        }

        // Summary block
        if let s = summaryData {
            let total = s.totalDevices ?? 0
            let fields: [(String, String)] = [
                ("Total Devices", "\(total)"),
                ("FileVault Encrypted", percentLabel(s.fileVaultEncrypted, total: total)),
                ("Gatekeeper Enabled", percentLabel(s.gatekeeperEnabled, total: total)),
                ("SIP Enabled", percentLabel(s.sipEnabled, total: total)),
                ("Firewall Enabled", percentLabel(s.firewallEnabled, total: total)),
            ]
            ws.write("Summary", row: row, col: 0, format: .header)
            ws.write("Count / %", row: row, col: 1, format: .header)
            row += 1
            for (label, value) in fields {
                ws.write(label, row: row, col: 0, format: .cell)
                ws.write(value, row: row, col: 1, format: .cell)
                row += 1
            }
            row += 1
        }

        // OS Version distribution
        if !osVersionRows.isEmpty {
            ws.write("OS Version", row: row, col: 0, format: .header)
            ws.write("Count", row: row, col: 1, format: .header)
            ws.write("Pct", row: row, col: 2, format: .header)
            row += 1
            for v in osVersionRows {
                ws.write(v.osVersion, row: row, col: 0, format: .cell)
                ws.write(v.count, row: row, col: 1, format: .cell)
                ws.write(v.pct, row: row, col: 2, format: .cell)
                row += 1
            }
        }
    }

    // MARK: - Patch Compliance
    // Source: `jamf-cli pro report patch-status --output json`

    func writePatch() throws {
        // Migrated to typed decoder (PatchStatusRow). See migration recipe in
        // loadLatestTyped(names:as:) for the pattern.
        guard let items = loadLatestTyped(
            names: ["patch-status", "patch_status"],
            as: [PatchStatusRow].self
        ), !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["patch-status"])
        }

        // Load patch release dates if available — added as optional columns.
        // Uses dataDir directly (already the workspace's jamf-cli-data directory).
        // Backward compatible: no snapshot → columns render "—".
        let releaseRows = PatchReleaseDateService.load(dataDir: dataDir)
        let releaseLookup = PatchReleaseDateService.releaseDateLookup(from: releaseRows)
        let hasReleaseDates = !releaseLookup.isEmpty

        let ncols = hasReleaseDates ? 8 : 6
        let ws = workbook.addSheet("Patch Compliance")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Patch Compliance"),
                                      subtitle: snapshotSubtitle(names: ["patch-status", "patch_status"],
                                                                  generated: ts),
                                      ncols: ncols)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 10)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 12)
        ws.setColumnWidth(4, 4, 14)
        ws.setColumnWidth(5, 5, 14)
        if hasReleaseDates {
            ws.setColumnWidth(6, 6, 16)
            ws.setColumnWidth(7, 7, 14)
        }

        var headers = ["Title", "Latest", "On Latest", "On Other", "Total", "Compliance %"]
        if hasReleaseDates { headers += ["Latest Released", "Days Behind"] }
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            ws.write(item.title, row: row, col: 0, format: .cell)
            ws.write(item.latest, row: row, col: 1, format: .cell)
            ws.write(item.onLatest, row: row, col: 2, format: .cell)
            ws.write(item.onOther, row: row, col: 3, format: .cell)
            ws.write(item.total, row: row, col: 4, format: .cell)
            ws.write(item.compliancePct, row: row, col: 5, format: colorForPctString(item.compliancePct))
            if hasReleaseDates {
                let releaseDate = releaseLookup[item.id] ?? ""
                ws.write(releaseDate.isEmpty ? "\u{2014}" : releaseDate, row: row, col: 6, format: .cell)
                // "Days Behind" is shown only for titles below 100% compliance,
                // matching Python's pct_value < 1.0 / secondary > 0 logic.
                let pct = PatchStatusService.parseCompliancePct(item.compliancePct)
                let belowFull = pct < 100.0 || item.onOther > 0
                if belowFull, let days = PatchReleaseDateService.daysBehind(releaseDate: releaseDate) {
                    ws.write(days, row: row, col: 7, format: .cell)
                } else {
                    ws.write("\u{2014}", row: row, col: 7, format: .cell)
                }
            }
            row += 1
        }
    }

    // MARK: - Patch Failures
    // Source: `jamf-cli pro report patch-status --scan-failures --output json`

    func writePatchFailures() throws {
        let raw = try loadLatestJSON(names: ["patch-device-failures", "patch_device_failures"])
        let ws = workbook.addSheet("Patch Failures")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Patch Failures"),
                                      subtitle: snapshotSubtitle(
                                          names: ["patch-device-failures", "patch_device_failures"],
                                          generated: ts),
                                      ncols: 8)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 24)
        ws.setColumnWidth(2, 2, 16)
        ws.setColumnWidth(3, 3, 14)
        ws.setColumnWidth(4, 4, 16)
        ws.setColumnWidth(5, 5, 10)
        ws.setColumnWidth(6, 6, 24)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let headers = ["Policy", "Device", "Serial", "OS Version", "Status Date", "Attempt", "Last Action"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            ws.write(item["policy"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["device"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["serial"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(item["os_version"] as? String ?? "", row: row, col: 3, format: .cell)
            ws.write(item["status_date"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(asInt(item["attempt"]) ?? 0, row: row, col: 5, format: .cell)
            ws.write(item["last_action"] as? String ?? "", row: row, col: 6, format: .cell)
            row += 1
        }
    }

    // MARK: - Update Status
    // Source: `jamf-cli pro report update-status --output json`

    func writeUpdateStatus() throws {
        // Migrated to typed decoder (UpdateStatusReport). See migration recipe in
        // loadLatestTyped(names:as:) for the pattern.
        // NOTE: The JSON is a single-element array wrapping the envelope; decode as [T] and take first.
        guard let reports = loadLatestTyped(
            names: ["update-status", "update_status"],
            as: [UpdateStatusReport].self
        ), let report = reports.first else {
            throw CoreDashboardError.noCachedData(names: ["update-status"])
        }

        let ws = workbook.addSheet("Update Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Update Status"),
                                      subtitle: snapshotSubtitle(
                                          names: ["update-status", "update_status"],
                                          generated: ts),
                                      ncols: 4)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 14)

        ws.write("Total Devices", row: row, col: 0, format: .cell)
        ws.write(report.total, row: row, col: 1, format: .cell)
        row += 2

        // Status summary
        if !report.statusSummary.isEmpty {
            ws.write("Status", row: row, col: 0, format: .header)
            ws.write("Count", row: row, col: 1, format: .header)
            row += 1
            for item in report.statusSummary {
                ws.write(item.status, row: row, col: 0, format: .cell)
                ws.write(item.count, row: row, col: 1, format: .cell)
                row += 1
            }
            row += 1
        }

        // Plan state summary
        if let planSummary = report.planStateSummary, !planSummary.isEmpty {
            ws.write("Plan State", row: row, col: 0, format: .header)
            ws.write("Count", row: row, col: 1, format: .header)
            row += 1
            for item in planSummary {
                ws.write(item.state, row: row, col: 0, format: .cell)
                ws.write(item.count, row: row, col: 1, format: .cell)
                row += 1
            }
        }
    }

    // MARK: - Update Failures
    // Source: `jamf-cli pro report update-status --scan-failures --output json`

    func writeUpdateFailures() throws {
        let raw = try loadLatestJSON(names: ["update-device-failures", "update_device_failures"])
        let ws = workbook.addSheet("Update Failures")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Update Failures"),
                                      subtitle: snapshotSubtitle(
                                          names: ["update-device-failures", "update_device_failures"],
                                          generated: ts),
                                      ncols: 8)
        ws.setColumnWidth(0, 0, 26)
        ws.setColumnWidth(1, 1, 14)
        ws.setColumnWidth(2, 2, 14)
        ws.setColumnWidth(3, 3, 14)
        ws.setColumnWidth(4, 4, 14)

        let envelope = firstDict(raw)
        let errorDevices = (envelope["error_devices"] as? [[String: Any]]) ?? []
        let failedPlans = (envelope["failed_plans"] as? [[String: Any]]) ?? []

        if !errorDevices.isEmpty {
            ws.write("Error Devices", row: row, col: 0, format: .header)
            row += 1
            let hdrs = ["Name", "Serial", "OS Version", "Status", "Product Key"]
            for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
            row += 1
            for item in errorDevices {
                ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
                ws.write(item["serial"] as? String ?? "", row: row, col: 1, format: .cell)
                ws.write(item["os_version"] as? String ?? "", row: row, col: 2, format: .cell)
                ws.write(item["status"] as? String ?? "", row: row, col: 3, format: .cell)
                ws.write(item["product_key"] as? String ?? "", row: row, col: 4, format: .cell)
                row += 1
            }
            row += 1
        }

        if !failedPlans.isEmpty {
            ws.write("Failed Plans", row: row, col: 0, format: .header)
            row += 1
            let hdrs = ["Name", "Serial", "OS Version", "State", "Action", "Version", "Error"]
            for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
            row += 1
            for item in failedPlans {
                ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
                ws.write(item["serial"] as? String ?? "", row: row, col: 1, format: .cell)
                ws.write(item["os_version"] as? String ?? "", row: row, col: 2, format: .cell)
                ws.write(item["state"] as? String ?? "", row: row, col: 3, format: .cell)
                ws.write(item["action"] as? String ?? "", row: row, col: 4, format: .cell)
                ws.write(item["version"] as? String ?? "", row: row, col: 5, format: .cell)
                ws.write(item["error"] as? String ?? "", row: row, col: 6, format: .cell)
                row += 1
            }
        }

        if errorDevices.isEmpty && failedPlans.isEmpty {
            ws.write("No update failures found.", row: row, col: 0, format: .cell)
        }
    }

    // MARK: - Inventory Summary
    // Source: `jamf-cli pro report inventory-summary --output json`
    // Shape: [{model, os_version, count}] sorted descending by count.

    func writeInventorySummary() throws {
        let raw = try loadLatestJSON(names: ["inventory-summary", "inventory_summary"])
        let ws = workbook.addSheet("Inventory Summary")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Inventory Summary"),
                                      subtitle: "Generated: \(ts)", ncols: 3)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 2, 14)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let headers = ["Model", "OS Version", "Device Count"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = items.sorted {
            let a = asInt($0["count"]) ?? 0
            let b = asInt($1["count"]) ?? 0
            return a > b
        }
        for item in sorted {
            ws.write(item["model"] as? String ?? "Unknown", row: row, col: 0, format: .cell)
            ws.write(item["os_version"] as? String ?? "Unknown", row: row, col: 1, format: .cell)
            ws.write(asInt(item["count"]) ?? 0, row: row, col: 2, format: .cell)
            row += 1
        }
    }

    // MARK: - Device Compliance
    // Source: `jamf-cli pro report device-compliance --output json`

    func writeDeviceCompliance() throws {
        let raw = try loadLatestJSON(names: ["device-compliance", "device_compliance"])
        let ws = workbook.addSheet("Device Compliance")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Device Compliance"),
                                      subtitle: snapshotSubtitle(
                                          names: ["device-compliance", "device_compliance"],
                                          generated: ts),
                                      ncols: 5)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 10)
        ws.setColumnWidth(3, 3, 10)
        ws.setColumnWidth(4, 4, 18)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let headers = ["Name", "Serial", "Managed", "Stale", "Days Since Check-in"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        for item in items {
            let isStale = asBool(item["stale"]) ?? false
            let daysSince = asInt(item["days_since_checkin"])
            let fmt: CellFormat = isStale ? .yellow : .cell
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: fmt)
            ws.write(item["serial"] as? String ?? "", row: row, col: 1, format: fmt)
            ws.write(asBool(item["managed"]).map { $0 ? "Yes" : "No" } ?? "", row: row, col: 2, format: fmt)
            ws.write(isStale ? "Yes" : "No", row: row, col: 3, format: fmt)
            if let d = daysSince {
                let daysFmt: CellFormat = d >= staleThreshold ? .yellow : .cell
                ws.write(d, row: row, col: 4, format: daysFmt)
            } else {
                ws.write("", row: row, col: 4, format: fmt)
            }
            row += 1
        }
    }

    // MARK: - Policy Health
    // Source: `jamf-cli pro report policy-status --output json`

    func writePolicyHealth() throws {
        let raw = try loadLatestJSON(names: ["policy-status", "policy_status"])
        let ws = workbook.addSheet("Policy Health")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Policy Health"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 14)
        ws.setColumnWidth(1, 1, 36)
        ws.setColumnWidth(2, 2, 24)
        ws.setColumnWidth(3, 3, 14)
        ws.setColumnWidth(4, 4, 30)

        guard let items = raw as? [[String: Any]], let first = items.first else { return }

        // Summary block
        if let summary = first["summary"] as? [String: Any] {
            let fields: [(String, Any)] = [
                ("Total Policies", asInt(summary["total_policies"]) ?? 0),
                ("Enabled", asInt(summary["enabled"]) ?? 0),
                ("Disabled", asInt(summary["disabled"]) ?? 0),
                ("Config Findings", asInt(summary["config_findings"]) ?? 0),
                ("Warnings", asInt(summary["warnings"]) ?? 0),
                ("Info", asInt(summary["info"]) ?? 0),
            ]
            ws.write("Metric", row: row, col: 0, format: .header)
            ws.write("Count", row: row, col: 1, format: .header)
            row += 1
            for (label, value) in fields {
                ws.write(label, row: row, col: 0, format: .cell)
                ws.write(value as? Int ?? 0, row: row, col: 1, format: .cell)
                row += 1
            }
            row += 1
        }

        // Config findings
        let findings = (first["config_findings"] as? [[String: Any]]) ?? []
        if !findings.isEmpty {
            ws.write("Config Findings", row: row, col: 0, format: .header)
            row += 1
            let hdrs = ["Severity", "Policy", "Check", "Detail"]
            for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
            row += 1
            for finding in findings {
                let severity = finding["severity"] as? String ?? ""
                let fmt: CellFormat = severity.lowercased() == "error" ? .red : .yellow
                ws.write(severity, row: row, col: 0, format: fmt)
                ws.write(finding["policy"] as? String ?? "", row: row, col: 1, format: .cell)
                ws.write(finding["check"] as? String ?? "", row: row, col: 2, format: .cell)
                ws.write(finding["detail"] as? String ?? "", row: row, col: 3, format: .cell)
                row += 1
            }
        }
    }

    // MARK: - Profile Status
    // Source: `jamf-cli pro classic-macos-profiles list --output json`

    func writeProfileStatus() throws {
        let raw = try loadLatestJSON(
            names: ["classic-macos-profiles", "macos-profiles", "profiles", "profile-status"]
        )
        let ws = workbook.addSheet("Profile Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Profile Status"),
                                      subtitle: snapshotSubtitle(
                                          names: ["classic-macos-profiles", "macos-profiles",
                                                  "profiles", "profile-status"],
                                          generated: ts),
                                      ncols: 5)
        ws.setColumnWidth(0, 0, 8)
        ws.setColumnWidth(1, 1, 36)
        ws.setColumnWidth(2, 2, 18)
        ws.setColumnWidth(3, 3, 14)
        ws.setColumnWidth(4, 4, 12)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let hdrs = ["ID", "Name", "Category", "Management Status", "Error Count"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let errWarn = config.thresholds?.resolvedProfileErrorWarning ?? 10
        for item in items {
            let errCount = asInt(item["error_count"]) ?? 0
            let fmt: CellFormat = errCount >= errWarn ? .yellow : .cell
            ws.write(item["id"].flatMap { asInt($0) } ?? 0, row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["category"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(item["management_status"] as? String ?? "", row: row, col: 3, format: .cell)
            ws.write(errCount, row: row, col: 4, format: fmt)
            row += 1
        }
    }

    // MARK: - App Status
    // Source: `jamf-cli pro report app-status --output json`

    func writeAppStatus() throws {
        let raw = try loadLatestJSON(names: ["app-status", "app_status"])
        let ws = workbook.addSheet("App Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("App Status"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 12)
        ws.setColumnWidth(4, 4, 12)
        ws.setColumnWidth(5, 5, 10)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let hdrs = ["Name", "Version", "Installed", "Managed", "Total", "Errors"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            let errors = asInt(item["errors"]) ?? 0
            let fmt: CellFormat = errors > 0 ? .yellow : .cell
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["version"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["installed"]) ?? 0, row: row, col: 2, format: .cell)
            ws.write(asInt(item["managed"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(asInt(item["total"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(errors, row: row, col: 5, format: fmt)
            row += 1
        }
    }

    // MARK: - Software Installs
    // Source: `jamf-cli pro report software-installs --output json`

    func writeSoftwareInstalls() throws {
        let raw = try loadLatestJSON(names: ["software-installs", "software_installs"])
        let ws = workbook.addSheet("Software Installs")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Software Installs"),
                                      subtitle: "Generated: \(ts)", ncols: 3)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 20)
        ws.setColumnWidth(2, 2, 10)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let hdrs = ["Name", "Version", "Count"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["version"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["count"]) ?? 0, row: row, col: 2, format: .cell)
            row += 1
        }
    }

    // MARK: - EA Definitions
    // Source: `jamf-cli pro computer-extension-attributes list --output json`

    func writeEADefinitions() throws {
        let raw = try loadLatestJSON(names: ["computer-extension-attributes", "ea-definitions"])
        let ws = workbook.addSheet("EA Definitions")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("EA Definitions"),
                                      subtitle: "Generated: \(ts)", ncols: 4)
        ws.setColumnWidth(0, 0, 8)
        ws.setColumnWidth(1, 1, 36)
        ws.setColumnWidth(2, 2, 14)
        ws.setColumnWidth(3, 3, 40)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let hdrs = ["ID", "Name", "Data Type", "Description"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            ws.write(item["id"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["data_type"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(item["description"] as? String ?? "", row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - EA Coverage
    // Source: `jamf-cli pro report ea-results --all --output json`

    func writeEACoverage() throws {
        let raw = try loadLatestJSON(names: ["ea-results", "ea_results"])
        let ws = workbook.addSheet("EA Coverage")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("EA Coverage"),
                                      subtitle: "Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 20)
        ws.setColumnWidth(2, 2, 16)
        ws.setColumnWidth(3, 3, 12)
        ws.setColumnWidth(4, 4, 20)

        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }

        let hdrs = ["EA Name", "Computer", "Serial", "Value"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            ws.write(item["ea_name"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["computer_name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["serial"] as? String ?? "", row: row, col: 2, format: .cell)
            let val = item["value"]
            let valStr: String
            switch val {
            case let s as String: valStr = s
            case let n as Int: valStr = "\(n)"
            case let b as Bool: valStr = b ? "true" : "false"
            default: valStr = ""
            }
            ws.write(valStr, row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - Mobile Fleet Summary
    // Sources: overview + mobile-device-inventory-details (or mobile-devices-list) + classic-ios-profiles

    func writeMobileFleetSummary() throws {
        let mobileRows = normalizeMobileInventory()
        let profileRows = normalizeMobileProfiles()
        guard !mobileRows.isEmpty || !profileRows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["mobile-device-inventory-details"])
        }

        let ws = workbook.addSheet("Mobile Fleet Summary")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Mobile Fleet Summary"),
                                      subtitle: "Generated: \(ts)", ncols: 3)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 20)
        ws.setColumnWidth(2, 2, 20)

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let summary = summarizeMobileInventory(mobileRows, staleDays: staleThreshold)

        var summaryPairs: [(String, Any)] = []
        if !mobileRows.isEmpty {
            summaryPairs += [
                ("Inventory Rows Returned", summary.total),
                ("Managed Rows", summary.managed),
                ("Unmanaged Rows", summary.unmanaged),
                ("Supervised Devices", summary.supervised),
                ("Shared iPad Devices", summary.sharedIPad),
                ("Assigned Users", summary.assigned),
                ("Activation Lock Enabled", summary.activationLock),
                ("Passcode Compliant", summary.passcodeCompliant),
                ("Inventory Older Than \(staleThreshold) Days", summary.stale),
            ]
        }
        if !profileRows.isEmpty {
            summaryPairs.append(("Mobile Config Profiles (List)", profileRows.count))
        }

        for (label, value) in summaryPairs {
            ws.write(label, row: row, col: 0, format: .cell)
            if let i = value as? Int {
                ws.write(i, row: row, col: 1, format: .cell)
            } else {
                ws.write("\(value)", row: row, col: 1, format: .cell)
            }
            row += 1
        }

        if !mobileRows.isEmpty {
            row = writeCounterBlock(ws: ws, row: row,
                                    title: "Device Family Distribution",
                                    colHeader: "Device Family",
                                    counts: summary.families)
            row = writeCounterBlock(ws: ws, row: row,
                                    title: "OS Version Distribution",
                                    colHeader: "OS Version",
                                    counts: summary.osVersions)
            writeCounterBlock(ws: ws, row: row,
                              title: "Top Models", colHeader: "Model",
                              counts: summary.models, maxRows: 10)
        }
    }

    // MARK: - Hardware Models
    // Source: inventory-summary [{model, os_version, count}], aggregated by model.

    func writeHardwareModels() throws {
        let raw = try loadLatestJSON(names: ["inventory-summary", "inventory_summary"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["inventory-summary"])
        }

        var modelCounts: [String: Int] = [:]
        for item in items {
            let model = (item["model"] as? String ?? "Unknown").trimmingCharacters(in: .whitespaces)
            modelCounts[model, default: 0] += asInt(item["count"]) ?? 0
        }
        let computerRows = modelCounts
            .map { (model: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        let ws = workbook.addSheet("Hardware Models")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Hardware Models"),
                                      subtitle: "Generated: \(ts)", ncols: 2)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 14)

        ws.write("Computer Models", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1
        for item in computerRows.prefix(20) {
            ws.write(item.model, row: row, col: 0, format: .cell)
            ws.write(item.count, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    // MARK: - Mobile Inventory
    // Source: mobile-device-inventory-details (preferred) or mobile-devices-list

    func writeMobileInventory() throws {
        let rows = normalizeMobileInventory()
        guard !rows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["mobile-device-inventory-details"])
        }

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let summary = summarizeMobileInventory(rows, staleDays: staleThreshold)

        let ws = workbook.addSheet("Mobile Inventory")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Mobile Inventory"),
                                      subtitle: "Generated: \(ts)", ncols: 20)

        let summaryPairs: [(String, Int)] = [
            ("Total Mobile Devices", summary.total),
            ("Managed", summary.managed),
            ("Unmanaged", summary.unmanaged),
            ("Supervised", summary.supervised),
            ("Shared iPad", summary.sharedIPad),
            ("Assigned Users", summary.assigned),
            ("Inventory Older Than Threshold", summary.stale),
        ]
        for (label, value) in summaryPairs {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }
        row += 1

        let headers: [String] = [
            "Jamf Pro ID", "Device Name", "Serial Number", "Device Family",
            "Managed", "Supervised", "Shared iPad", "Model", "OS Version",
            "Username", "Email", "Department", "Building",
            "Last Inventory Update", "Days Since Inventory",
            "Activation Lock", "Passcode Compliant", "Data Protection",
            "Jailbreak Status", "Ownership",
        ]
        let widths: [Double] = [12, 26, 18, 14, 11, 11, 11, 24, 12, 18, 24, 18, 18, 22, 18, 16, 18, 18, 18, 14]
        for (col, width) in widths.enumerated() { ws.setColumnWidth(col, col, width) }
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = rows.sorted {
            let fa = $0["Device Family"] as? String ?? ""
            let fb = $1["Device Family"] as? String ?? ""
            if fa != fb { return fa < fb }
            let na = $0["Device Name"] as? String ?? ""
            let nb = $1["Device Name"] as? String ?? ""
            if na != nb { return na < nb }
            return ($0["Serial Number"] as? String ?? "") < ($1["Serial Number"] as? String ?? "")
        }
        for item in sorted {
            for (col, header) in headers.enumerated() {
                let value = item[header] ?? ""
                if header == "Days Since Inventory", let days = value as? Int {
                    let fmt: CellFormat = days > staleThreshold * 2 ? .red
                        : days > staleThreshold ? .yellow : .cell
                    ws.write(days, row: row, col: col, format: fmt)
                } else if let s = value as? String {
                    ws.write(s, row: row, col: col, format: .cell)
                } else if let i = value as? Int {
                    ws.write(i, row: row, col: col, format: .cell)
                } else {
                    ws.write("", row: row, col: col, format: .cell)
                }
            }
            row += 1
        }
    }

    // MARK: - Audit Summary
    // Source: `jamf-cli pro audit --output json`

    func writeAuditSummary() throws {
        let raw = try loadLatestJSON(names: ["audit"])
        let items = (raw as? [[String: Any]]) ?? []

        let ws = workbook.addSheet("Audit Summary")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Health Audit Summary"),
                                      subtitle: "Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 35)
        ws.setColumnWidth(1, 1, 15)
        ws.setColumnWidth(2, 2, 15)
        ws.setColumnWidth(3, 3, 50)
        ws.setColumnWidth(4, 4, 15)

        let headers = ["Finding", "Category", "Severity", "Recommendation", "Affected"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            let severity = (item["severity"] as? String ?? "").uppercased()
            let fmt: CellFormat = severity == "CRITICAL" ? .red
                : severity == "WARNING" ? .yellow : .cell
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: fmt)
            ws.write(item["category"] as? String ?? "", row: row, col: 1, format: fmt)
            ws.write(severity, row: row, col: 2, format: fmt)
            ws.write(item["recommendation"] as? String ?? "", row: row, col: 3, format: fmt)
            ws.write(asInt(item["affected"]) ?? 0, row: row, col: 4, format: fmt)
            row += 1
        }
    }

    // MARK: - Group Hygiene
    // Source: `jamf-cli pro groups list --output json`
    // Shape: [{groupPlatformId, groupJamfProId, groupName, groupType, membershipCount, smart}]

    func writeGroupHygiene() throws {
        let raw = try loadLatestJSON(names: ["groups"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["groups"])
        }

        let ws = workbook.addSheet("Group Hygiene")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Group Hygiene: Unused Groups"),
                                      subtitle: "Generated: \(ts)", ncols: 4)
        ws.setColumnWidth(0, 0, 45)
        ws.setColumnWidth(1, 1, 15)
        ws.setColumnWidth(2, 2, 15)
        ws.setColumnWidth(3, 3, 15)

        let headers = ["Group Name", "Type", "Jamf ID", "Members"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let unused = items.filter { (asInt($0["membershipCount"]) ?? 0) == 0 }
        if unused.isEmpty {
            ws.write("No unused computer groups found.", row: row, col: 0, format: .cell)
            return
        }

        let sorted = unused.sorted {
            ($0["groupName"] as? String ?? "").lowercased() <
            ($1["groupName"] as? String ?? "").lowercased()
        }
        for item in sorted {
            ws.write(item["groupName"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["groupType"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["groupJamfProId"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(asInt(item["membershipCount"]) ?? 0, row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - Check-in Health
    // Source: device-compliance rows (fallback path; no native checkin-status in fixtures).

    func writeCheckinHealth() throws {
        let raw = try loadLatestJSON(names: ["device-compliance", "device_compliance"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["device-compliance"])
        }

        let threshold = config.thresholds?.resolvedStaleDays ?? 7
        let ws = workbook.addSheet("Check-in Health")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Check-in Health"),
                                      subtitle: "Threshold: \(threshold) days | Generated: \(ts)",
                                      ncols: 4)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 2, 18)
        ws.setColumnWidth(3, 3, 18)

        let total = items.count
        let overdue = items.filter { asBool($0["stale"]) == true }.count
        let current = total - overdue
        let pctCurrent = total > 0 ? Double(current) / Double(total) * 100 : 0.0
        let pctOverdue = total > 0 ? Double(overdue) / Double(total) * 100 : 0.0

        ws.write("Computers", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("% of Total", row: row, col: 2, format: .header)
        row += 1
        ws.write("Total Devices", row: row, col: 0, format: .cell)
        ws.write(total, row: row, col: 1, format: .cell)
        ws.write("", row: row, col: 2, format: .cell)
        row += 1
        ws.write("Checked In (within \(threshold) days)", row: row, col: 0, format: .cell)
        ws.write(current, row: row, col: 1, format: .cell)
        ws.write(String(format: "%.1f%%", pctCurrent), row: row, col: 2, format: .cell)
        row += 1
        let overdueFmt: CellFormat = overdue > 0 ? .red : .cell
        ws.write("Overdue (>\(threshold) days)", row: row, col: 0, format: overdueFmt)
        ws.write(overdue, row: row, col: 1, format: overdueFmt)
        ws.write(String(format: "%.1f%%", pctOverdue), row: row, col: 2, format: overdueFmt)
    }

    // MARK: - Environment Stats
    // Source: `jamf-cli pro report env-stats --output json`
    // Shape: {policies: N, config_profiles: N, scripts: N, ...}

    func writeEnvironmentStats() throws {
        let raw = try loadLatestJSON(names: ["env-stats", "env_stats"])
        guard let envelope = raw as? [String: Any], !envelope.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["env-stats"])
        }

        let displayFields: [(String, String)] = [
            ("policies", "Policies"),
            ("config_profiles", "Configuration Profiles"),
            ("scripts", "Scripts"),
            ("packages", "Packages"),
            ("smart_groups_computer", "Smart Groups — Computer"),
            ("smart_groups_mobile", "Smart Groups — Mobile"),
            ("extension_attributes", "Extension Attributes"),
            ("categories", "Categories"),
        ]
        let rows = displayFields.compactMap { key, label -> (String, Int)? in
            guard let v = envelope[key] else { return nil }
            return (label, asInt(v) ?? 0)
        }
        guard !rows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["env-stats"])
        }

        let ws = workbook.addSheet("Environment Stats")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Environment Stats"),
                                      subtitle: "Generated: \(ts)", ncols: 2)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 14)
        ws.write("Object Type", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1
        for (label, count) in rows {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    // MARK: - Mobile Config Profiles
    // Source: `jamf-cli pro classic-mobile-config-profiles list --output json`
    // Simplified fixture shape: [{id, name}]; production adds category, site, description.

    func writeMobileConfigProfiles() throws {
        let profileRows = normalizeMobileProfiles()
        guard !profileRows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["classic-ios-profiles"])
        }

        let categoryCounts = profileRows.reduce(into: [String: Int]()) { acc, row in
            let catStr = row["Category"] as? String ?? ""
            let cat = catStr.isEmpty ? "Uncategorized" : catStr
            acc[cat, default: 0] += 1
        }

        let ws = workbook.addSheet("Mobile Config Profiles")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Mobile Config Profiles"),
                                      subtitle: "Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 34)
        ws.setColumnWidth(1, 1, 14)
        ws.setColumnWidth(2, 2, 24)
        ws.setColumnWidth(3, 3, 20)
        ws.setColumnWidth(4, 4, 44)

        let uncategorized = categoryCounts["Uncategorized"] ?? 0
        let summaryPairs: [(String, Int)] = [
            ("Total Profiles", profileRows.count),
            ("Unique Categories", categoryCounts.keys.count),
            ("Uncategorized Profiles", uncategorized),
        ]
        for (label, value) in summaryPairs {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }

        row = writeCounterBlock(ws: ws, row: row,
                                title: "Profiles by Category", colHeader: "Category",
                                counts: categoryCounts, maxRows: 15)
        row += 2

        let headers = ["Profile Name", "Profile ID", "Category", "Site", "Description"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = profileRows.sorted {
            let ca = $0["Category"] as? String ?? ""
            let cb = $1["Category"] as? String ?? ""
            if ca != cb { return ca < cb }
            return ($0["Profile Name"] as? String ?? "") < ($1["Profile Name"] as? String ?? "")
        }
        for item in sorted {
            for (col, header) in headers.enumerated() {
                ws.write(item[header] as? String ?? "", row: row, col: col, format: .cell)
            }
            row += 1
        }
    }

    // MARK: - Active Devices
    // Source: device-compliance rows; counts non-stale devices.

    func writeActiveDevices() throws {
        let raw = try loadLatestJSON(names: ["device-compliance", "device_compliance"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["device-compliance"])
        }

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let total = items.count
        let active = items.filter { asBool($0["stale"]) != true }.count
        let stale = total - active
        let managed = items.filter { asBool($0["managed"]) == true }.count

        let ws = workbook.addSheet("Active Devices")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Active Devices"),
                                      subtitle: "Stale threshold: \(staleThreshold) days | Generated: \(ts)",
                                      ncols: 2)
        ws.setColumnWidth(0, 0, 32)
        ws.setColumnWidth(1, 1, 14)

        let pairs: [(String, Int)] = [
            ("Total Devices", total),
            ("Active (non-stale)", active),
            ("Stale Devices", stale),
            ("Managed", managed),
            ("Unmanaged", total - managed),
        ]
        for (label, value) in pairs {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    // MARK: - Smart Groups
    // Source: `jamf-cli pro groups list --output json`
    // Shape: [{groupPlatformId, groupJamfProId, groupName, groupType, membershipCount, smart}]

    func writeSmartGroups() throws {
        let raw = try loadLatestJSON(names: ["groups"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["groups"])
        }

        let ws = workbook.addSheet("Smart Groups")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Smart Groups"),
                                      subtitle: "Generated: \(ts)", ncols: 7)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 16)
        ws.setColumnWidth(3, 3, 16)
        ws.setColumnWidth(4, 4, 16)
        ws.setColumnWidth(5, 5, 16)
        ws.setColumnWidth(6, 6, 16)

        let headers = ["Group Name", "Type", "Smart Group", "Member Count", "Delta", "Prior Count", "Note"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = items.sorted {
            ($0["groupName"] as? String ?? "").lowercased() <
            ($1["groupName"] as? String ?? "").lowercased()
        }
        for item in sorted {
            let count = asInt(item["membershipCount"]) ?? 0
            let isSmart = asBool(item["smart"]) ?? false
            let isScopeFail = isSmart && count == 0
            let note = isScopeFail ? "Zero members" : ""
            let fmt: CellFormat = isScopeFail ? .red : .cell
            let groupType = (item["groupType"] as? String ?? "").capitalized
            ws.write(item["groupName"] as? String ?? "", row: row, col: 0, format: fmt)
            ws.write(groupType, row: row, col: 1, format: fmt)
            ws.write(isSmart ? "Yes" : "No", row: row, col: 2, format: fmt)
            ws.write(count, row: row, col: 3, format: fmt)
            ws.write("", row: row, col: 4, format: fmt)
            ws.write("", row: row, col: 5, format: fmt)
            ws.write(note, row: row, col: 6, format: fmt)
            row += 1
        }
    }

    // MARK: - Package Lifecycle
    // Source: `jamf-cli pro packages list --output json`
    // Shape: [{id, packageName, fileName, notes, size?, ...}]

    func writePackageLifecycle() throws {
        let raw = try loadLatestJSON(names: ["packages"])
        let items = ((raw as? [[String: Any]]) ?? []).filter { !($0.isEmpty) }
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["packages"])
        }

        let ws = workbook.addSheet("Package Lifecycle")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Package Lifecycle"),
                                      subtitle: "Generated: \(ts)", ncols: 7)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 40)
        ws.setColumnWidth(2, 2, 16)
        ws.setColumnWidth(3, 3, 16)
        ws.setColumnWidth(4, 4, 16)
        ws.setColumnWidth(5, 5, 16)
        ws.setColumnWidth(6, 6, 32)

        let sorted = items.sorted {
            let a = firstStringValue($0, keys: ["packageName", "name"]).lowercased()
            let b = firstStringValue($1, keys: ["packageName", "name"]).lowercased()
            return a < b
        }

        let summaryPairs: [(String, Any)] = [
            ("Total Packages", sorted.count),
            ("Known Sizes", sorted.filter { $0["size"] != nil }.count),
        ]
        for (idx, (label, value)) in summaryPairs.enumerated() {
            ws.write(label, row: row, col: idx * 2, format: .header)
            if let i = value as? Int {
                ws.write(i, row: row, col: idx * 2 + 1, format: .cell)
            }
        }
        row += 2

        let headers = ["Package Name", "Filename", "Upload Date", "Age (days)", "Size (MB)", "Age Bucket", "Note"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for pkg in sorted {
            let name = firstStringValue(pkg, keys: ["packageName", "name"])
            let filename = firstStringValue(pkg, keys: ["fileName", "filename"])
            let uploadDate = firstStringValue(pkg, keys: ["upload_date", "uploadDate", "dateUploaded", "created", "updated"])
            let note = pkg["notes"] as? String ?? ""
            let sizeMB = packageSizeMB(pkg["size"])
            let ageDays = daysSinceDate(uploadDate)

            let (bucket, fmt): (String, CellFormat)
            if let days = ageDays {
                if days <= 30 { (bucket, fmt) = ("0-30 days", .green) }
                else if days <= 90 { (bucket, fmt) = ("31-90 days", .yellow) }
                else { (bucket, fmt) = ("91+ days", .red) }
            } else {
                (bucket, fmt) = ("Unknown", .cell)
            }

            ws.write(name, row: row, col: 0, format: fmt)
            ws.write(filename.isEmpty ? name : filename, row: row, col: 1, format: fmt)
            ws.write(uploadDate, row: row, col: 2, format: fmt)
            if let days = ageDays {
                ws.write(days, row: row, col: 3, format: fmt)
            } else {
                ws.write("", row: row, col: 3, format: fmt)
            }
            if let mb = sizeMB {
                ws.write(mb, row: row, col: 4, format: fmt)
            } else {
                ws.write("", row: row, col: 4, format: fmt)
            }
            ws.write(bucket, row: row, col: 5, format: fmt)
            ws.write(note, row: row, col: 6, format: fmt)
            row += 1
        }
    }

    // MARK: - Mobile inventory helpers

    /// Normalize mobile device records from inventory-details (preferred) or devices-list.
    private func normalizeMobileInventory() -> [[String: Any]] {
        let names = ["mobile-device-inventory-details", "mobile_device_inventory_details",
                     "mobile-devices-list", "mobile_devices_list"]
        guard let raw = try? loadLatestJSON(names: names),
              let items = raw as? [[String: Any]] else { return [] }

        return items.compactMap { item -> [String: Any]? in
            // inventory-details has a `general` sub-dict; devices-list is flat.
            let general = item["general"] as? [String: Any] ?? item
            let model = general["model"] as? String ?? item["model"] as? String ?? ""
            let name = general["displayName"] as? String ?? item["name"] as? String ?? ""
            let managed = general["managed"] as? Bool ?? item["managed"] as? Bool
            let supervised = general["supervised"] as? Bool ?? item["supervised"] as? Bool
            let osVersion = general["osVersion"] as? String ?? item["type"] as? String ?? ""
            let serial = item["serialNumber"] as? String
                ?? general["serialNumber"] as? String ?? ""
            let jamfId = item["mobileDeviceId"] as? String ?? item["id"] as? String ?? ""
            let lastInventory = general["lastInventoryUpdateDate"] as? String ?? ""
            let ownership = general["deviceOwnershipType"] as? String ?? ""

            let userLocation = item["userAndLocation"] as? [String: Any] ?? [:]
            let username = userLocation["username"] as? String ?? item["username"] as? String ?? ""
            let email = userLocation["emailAddress"] as? String ?? item["email"] as? String ?? ""
            let dept = userLocation["department"] as? String ?? item["department"] as? String ?? ""
            let building = userLocation["building"] as? String ?? item["building"] as? String ?? ""

            let activationLock = general["activationLockEnabled"] as? Bool
            let passcodeCompliant = general["passcodeCompliant"] as? Bool
            let sharedIPad = general["enrolledViaAutomatedDeviceEnrollment"] as? Bool ?? false
            let dataProtection = general["dataProtectionEnabled"] as? Bool
            let jailbreak = general["jailbreakDetected"] as? String ?? ""

            let family = mobileDeviceFamily(model: model, name: name)
            let daysSince = daysSinceDate(lastInventory)

            return [
                "Jamf Pro ID": jamfId,
                "Device Name": name,
                "Serial Number": serial,
                "Device Family": family,
                "Managed": yesNoUnknown(managed),
                "Supervised": yesNoUnknown(supervised),
                "Shared iPad": yesNoUnknown(sharedIPad as Bool?),
                "Model": model,
                "OS Version": osVersion,
                "Username": username,
                "Email": email,
                "Department": dept,
                "Building": building,
                "Last Inventory Update": lastInventory,
                "Days Since Inventory": daysSince as Any,
                "Activation Lock": yesNoUnknown(activationLock),
                "Passcode Compliant": yesNoUnknown(passcodeCompliant),
                "Data Protection": yesNoUnknown(dataProtection),
                "Jailbreak Status": jailbreak,
                "Ownership": ownership,
            ]
        }
    }

    private func normalizeMobileProfiles() -> [[String: Any]] {
        let names = ["classic-ios-profiles", "classic_ios_profiles",
                     "classic-mobile-config-profiles", "mobile-config-profiles"]
        guard let raw = try? loadLatestJSON(names: names),
              let items = raw as? [[String: Any]] else { return [] }
        return items.map { item in
            [
                "Profile ID": "\(item["id"] ?? "")",
                "Profile Name": item["name"] as? String ?? "",
                "Category": item["category"] as? String ?? "",
                "Site": item["site"] as? String ?? "",
                "Description": item["description"] as? String ?? "",
            ]
        }
    }

    private struct MobileInventorySummary {
        var total, managed, unmanaged, supervised, sharedIPad: Int
        var assigned, activationLock, passcodeCompliant, stale: Int
        var families, osVersions, models: [String: Int]
    }

    private func summarizeMobileInventory(_ rows: [[String: Any]], staleDays: Int) -> MobileInventorySummary {
        var s = MobileInventorySummary(
            total: rows.count, managed: 0, unmanaged: 0, supervised: 0, sharedIPad: 0,
            assigned: 0, activationLock: 0, passcodeCompliant: 0, stale: 0,
            families: [:], osVersions: [:], models: [:]
        )
        for row in rows {
            if (row["Managed"] as? String) == "Yes" { s.managed += 1 } else { s.unmanaged += 1 }
            if (row["Supervised"] as? String) == "Yes" { s.supervised += 1 }
            if (row["Shared iPad"] as? String) == "Yes" { s.sharedIPad += 1 }
            if let u = row["Username"] as? String, !u.isEmpty { s.assigned += 1 }
            if (row["Activation Lock"] as? String) == "Yes" { s.activationLock += 1 }
            if (row["Passcode Compliant"] as? String) == "Yes" { s.passcodeCompliant += 1 }
            if let days = row["Days Since Inventory"] as? Int, days > staleDays { s.stale += 1 }
            let family = row["Device Family"] as? String ?? "Mobile"
            s.families[family, default: 0] += 1
            let os = row["OS Version"] as? String ?? ""
            if !os.isEmpty { s.osVersions[os, default: 0] += 1 }
            let model = row["Model"] as? String ?? ""
            if !model.isEmpty { s.models[model, default: 0] += 1 }
        }
        return s
    }

    private func mobileDeviceFamily(model: String, name: String) -> String {
        let text = "\(model) \(name)".lowercased()
        if text.contains("ipad") { return "iPad" }
        if text.contains("iphone") { return "iPhone" }
        if text.contains("ipod") { return "iPod" }
        if text.contains("appletv") || text.contains("apple tv") { return "Apple TV" }
        if text.contains("vision") { return "Vision" }
        return "Mobile"
    }

    private func yesNoUnknown(_ value: Bool?) -> String {
        guard let value else { return "" }
        return value ? "Yes" : "No"
    }

    // MARK: - Counter block helper

    /// Write a titled counter block (label + count rows) and return the next available row.
    @discardableResult
    private func writeCounterBlock(
        ws: Worksheet,
        row startRow: Int,
        title: String,
        colHeader: String,
        counts: [String: Int],
        maxRows: Int = Int.max
    ) -> Int {
        guard !counts.isEmpty else { return startRow }
        var row = startRow + 1
        ws.write(title, row: startRow, col: 0, format: .header)
        ws.write(colHeader, row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1
        let sorted = counts.sorted { $0.value > $1.value }
        for (key, count) in sorted.prefix(maxRows) {
            ws.write(key, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .cell)
            row += 1
        }
        return row + 1
    }

    // MARK: - Package helpers

    private func firstStringValue(_ dict: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    private func packageSizeMB(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        let bytes: Double?
        if let d = raw as? Double { bytes = d }
        else if let i = raw as? Int { bytes = Double(i) }
        else if let s = raw as? String { bytes = Double(s) }
        else { bytes = nil }
        guard let b = bytes, b > 0 else { return nil }
        return (b / 1_048_576 * 10).rounded() / 10
    }

    private func daysSinceDate(_ raw: String) -> Int? {
        guard !raw.isEmpty else { return nil }
        let fmts = [
            ISO8601DateFormatter(),
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        var parsed: Date?
        for fmt in fmts {
            if let d = fmt.date(from: raw) { parsed = d; break }
        }
        if parsed == nil {
            for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
                df.dateFormat = pattern
                if let d = df.date(from: raw) { parsed = d; break }
            }
        }
        guard let date = parsed else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    // MARK: - Compliance Devices
    // Source: `jamf-cli pro report compliance-devices --output json` (Platform feature).
    // Silently produces no sheet if the tenant has no Platform entitlement.

    func writeComplianceDevices() throws {
        let raw = try loadLatestJSON(names: ["compliance-devices"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Compliance Devices")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Compliance Devices"),
                                      subtitle: "Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 14)
        ws.setColumnWidth(2, 3, 14)
        ws.setColumnWidth(4, 4, 14)
        let hdrs = ["Device", "Device ID", "Rules Passed", "Rules Failed", "Compliance %"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let compliance = item["compliance"] as? String ?? ""
            let fmt: CellFormat = compliance.isEmpty ? .yellow : .cell
            ws.write(item["device"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["rulesPassed"]) ?? 0, row: row, col: 2, format: .cell)
            ws.write(asInt(item["rulesFailed"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(compliance, row: row, col: 4, format: fmt)
            row += 1
        }
    }

    // MARK: - Compliance Rules
    // Source: `jamf-cli pro report compliance-rules --output json` (Platform feature).

    func writeComplianceRules() throws {
        let raw = try loadLatestJSON(names: ["compliance-rules"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Compliance Rules")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Compliance Rules"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 4, 12)
        ws.setColumnWidth(5, 5, 12)
        let hdrs = ["Rule", "Passed", "Failed", "Unknown", "Devices", "Pass Rate"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let pctStr = item["passRate"] as? String ?? ""
            ws.write(item["rule"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(asInt(item["passed"]) ?? 0, row: row, col: 1, format: .cell)
            ws.write(asInt(item["failed"]) ?? 0, row: row, col: 2, format: .cell)
            ws.write(asInt(item["unknown"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(asInt(item["devices"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(pctStr, row: row, col: 5, format: colorForPctString(pctStr))
            row += 1
        }
    }

    // MARK: - DDM Status
    // Source: `jamf-cli pro report ddm-status --output json` (Platform/DDM feature).

    func writeDDMStatus() throws {
        let raw = try loadLatestJSON(names: ["ddm-status"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("DDM Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("DDM Status"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 2, 14)
        ws.setColumnWidth(3, 5, 14)
        let hdrs = ["Source", "Type", "Devices", "Declarations", "Successful", "Unsuccessful"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let unsuccessful = asInt(item["unsuccessful"]) ?? 0
            let fmt: CellFormat = unsuccessful > 0 ? .yellow : .cell
            ws.write(item["source"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["type"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["devices"]) ?? 0, row: row, col: 2, format: .cell)
            ws.write(asInt(item["declarations"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(asInt(item["successful"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(unsuccessful, row: row, col: 5, format: fmt)
            row += 1
        }
    }

    // MARK: - Blueprint Status
    // Source: `jamf-cli pro report blueprint-status --output json` (Platform/DDM feature).

    func writeBlueprintStatus() throws {
        let raw = try loadLatestJSON(names: ["blueprint-status"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Blueprint Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Blueprint Status"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 2, 16)
        ws.setColumnWidth(3, 5, 14)
        let hdrs = ["Name", "State", "Scope", "Failed", "Pending", "Succeeded"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let failed = asInt(item["failed"]) ?? 0
            let fmt: CellFormat = failed > 0 ? .yellow : .cell
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["state"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["scope"]) ?? 0, row: row, col: 2, format: .cell)
            ws.write(failed, row: row, col: 3, format: fmt)
            ws.write(asInt(item["pending"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(asInt(item["succeeded"]) ?? 0, row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Overview
    // Source: `jamf-cli protect overview --output json` (gated on protect.enabled).

    func writeProtectOverview() throws {
        let raw = try loadLatestJSON(names: ["protect-overview"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Protect Overview")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Overview"),
                                      subtitle: "Generated: \(ts)", ncols: 2)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 24)
        ws.write("Resource", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        row += 1
        for item in items {
            for (key, value) in item.sorted(by: { $0.key < $1.key }) {
                ws.write(key, row: row, col: 0, format: .cell)
                ws.write("\(value)", row: row, col: 1, format: .cell)
                row += 1
            }
        }
    }

    // MARK: - Protect Alerts
    // Source: `jamf-cli protect alerts list --output json` (gated on protect.enabled).

    func writeProtectAlerts() throws {
        let raw = try loadLatestJSON(names: ["protect-alerts"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Protect Alerts")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Alerts"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 20)
        ws.setColumnWidth(2, 3, 16)
        ws.setColumnWidth(4, 5, 22)
        let hdrs = ["Host", "Serial", "Severity", "Status", "Event Type", "Created"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let severity = (item["severity"] as? String ?? "").lowercased()
            let fmt: CellFormat = severity == "high" || severity == "critical" ? .red
                : severity == "medium" ? .yellow : .cell
            // computer may be nested as {hostName, serial}
            let computer = item["computer"] as? [String: Any]
            let host = computer?["hostName"] as? String ?? item["hostName"] as? String ?? ""
            let serial = computer?["serial"] as? String ?? item["serial"] as? String ?? ""
            ws.write(host, row: row, col: 0, format: .cell)
            ws.write(serial, row: row, col: 1, format: .cell)
            ws.write(item["severity"] as? String ?? "", row: row, col: 2, format: fmt)
            ws.write(item["status"] as? String ?? "", row: row, col: 3, format: .cell)
            ws.write(item["eventType"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(item["created"] as? String ?? "", row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Computers
    // Source: `jamf-cli protect computers list --output json` (gated on protect.enabled).

    func writeProtectComputers() throws {
        let raw = try loadLatestJSON(names: ["protect-computers"])
        let items: [[String: Any]]
        // Protect computers may come as an array or an envelope {nodes: [...]}
        if let arr = raw as? [[String: Any]] {
            items = arr
        } else if let dict = raw as? [String: Any],
                  let nodes = dict["nodes"] as? [[String: Any]] {
            items = nodes
        } else {
            return
        }
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Protect Computers")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Computers"),
                                      subtitle: "Generated: \(ts)", ncols: 8)
        ws.setColumnWidth(0, 0, 26)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 2, 24)
        ws.setColumnWidth(3, 3, 14)
        ws.setColumnWidth(4, 5, 18)
        ws.setColumnWidth(6, 7, 14)
        let hdrs = ["Host", "Serial", "Plan", "OS", "Status", "Last Connection",
                    "Web Protection", "Full Disk Access"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let plan = (item["plan"] as? [String: Any])?["name"] as? String ?? ""
            let osMajor = asInt(item["osMajor"])
            let osMinor = asInt(item["osMinor"])
            let osPatch = asInt(item["osPatch"])
            let osStr: String
            if let maj = osMajor, let min = osMinor, let pat = osPatch {
                osStr = "\(maj).\(min).\(pat)"
            } else {
                osStr = item["osString"] as? String ?? ""
            }
            ws.write(item["hostName"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["serial"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(plan, row: row, col: 2, format: .cell)
            ws.write(osStr, row: row, col: 3, format: .cell)
            ws.write(item["connectionStatus"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(item["lastConnection"] as? String ?? "", row: row, col: 5, format: .cell)
            let webFmt: CellFormat = (item["webProtectionActive"] as? Bool == false) ? .yellow : .cell
            let diskFmt: CellFormat = (item["fullDiskAccess"] as? Bool == false) ? .yellow : .cell
            ws.write(asBool(item["webProtectionActive"]).map { $0 ? "Yes" : "No" } ?? "",
                     row: row, col: 6, format: webFmt)
            ws.write(asBool(item["fullDiskAccess"]).map { $0 ? "Yes" : "No" } ?? "",
                     row: row, col: 7, format: diskFmt)
            row += 1
        }
    }

    // MARK: - Protect Insights
    // Source: `jamf-cli protect insights list --output json` (gated on protect.enabled).

    func writeProtectInsights() throws {
        let raw = try loadLatestJSON(names: ["protect-insights"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Protect Insights")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Insights"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 2, 20)
        ws.setColumnWidth(3, 5, 14)
        let hdrs = ["Label", "Section", "Description", "Pass", "Fail", "Enabled"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let fail = asInt(item["totalFail"]) ?? 0
            let fmt: CellFormat = fail > 0 ? .yellow : .cell
            ws.write(item["label"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["section"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["description"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(asInt(item["totalPass"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(fail, row: row, col: 4, format: fmt)
            ws.write(asBool(item["enabled"]).map { $0 ? "Yes" : "No" } ?? "",
                     row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Plans
    // Source: `jamf-cli protect plans list --output json` (gated on protect data present).

    func writeProtectPlans() throws {
        let raw = try loadLatestJSON(names: ["protect-plans"])
        let items: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            items = arr
        } else if let dict = raw as? [String: Any],
                  let nodes = dict["nodes"] as? [[String: Any]] {
            items = nodes
        } else {
            throw CoreDashboardError.noCachedData(names: ["protect-plans"])
        }
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["protect-plans"])
        }

        let ws = workbook.addSheet("Protect Plans")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Plans"),
                                      subtitle: "Generated: \(ts)", ncols: 14)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 36)
        ws.setColumnWidth(2, 2, 40)
        ws.setColumnWidth(3, 4, 20)
        ws.setColumnWidth(5, 5, 12)
        ws.setColumnWidth(6, 6, 12)
        ws.setColumnWidth(7, 7, 22)
        ws.setColumnWidth(8, 8, 14)
        ws.setColumnWidth(9, 9, 60)
        ws.setColumnWidth(10, 10, 32)
        ws.setColumnWidth(11, 11, 32)
        ws.setColumnWidth(12, 13, 14)

        let hdrs = ["Plan Name", "UUID", "Description", "Created", "Updated",
                    "Log Level", "Auto Update", "Threat Prevention Strategy",
                    "Profile Version", "Custom Engine Config", "Exception Sets",
                    "Analytic Sets", "Telemetry", "Telemetry V2"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = items.sorted {
            let a = ($0["name"] as? String ?? "").lowercased()
            let b = ($1["name"] as? String ?? "").lowercased()
            return a < b
        }
        for item in sorted {
            let cec = item["customEngineConfig"] as? [String: Any]
            let cecSummary: String
            if let cec, !cec.isEmpty {
                cecSummary = cec.keys.sorted().joined(separator: ", ")
            } else {
                cecSummary = ""
            }
            let exceptionSets = formatNamedList(item["exceptionSets"])
            let analyticSets = formatAnalyticSets(item["analyticSets"])
            let autoUpdate = boolToYesNo(item["autoUpdate"])
            let telemetry = boolToYesNo(item["telemetry"])
            let telemetryV2 = boolToYesNo(item["telemetryV2"])
            let profileVersion = item["profileVersion"].flatMap { asInt($0) }
                .map { "\($0)" } ?? ""
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["uuid"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["description"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(item["created"] as? String ?? "", row: row, col: 3, format: .cell)
            ws.write(item["updated"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(item["logLevel"] as? String ?? "", row: row, col: 5, format: .cell)
            ws.write(autoUpdate, row: row, col: 6, format: .cell)
            ws.write(item["threatPreventionStrategy"] as? String ?? "", row: row, col: 7, format: .cell)
            ws.write(profileVersion, row: row, col: 8, format: .cell)
            ws.write(cecSummary, row: row, col: 9, format: .cell)
            ws.write(exceptionSets, row: row, col: 10, format: .cell)
            ws.write(analyticSets, row: row, col: 11, format: .cell)
            ws.write(telemetry, row: row, col: 12, format: .cell)
            ws.write(telemetryV2, row: row, col: 13, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Threat Overview
    // Source: `jamf-cli protect alerts list --output json` (gated on protect data present).
    // Severity-sorted triage view of protect alerts.

    func writeProtectThreatOverview() throws {
        let raw = try loadLatestJSON(names: ["protect-alerts"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["protect-alerts"])
        }

        let severityRank: [String: Int] = [
            "critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4,
        ]
        let rows = items.map { item -> [String: String] in
            let computer = item["computer"] as? [String: Any]
            let host = computer?["hostName"] as? String
                ?? item["hostName"] as? String ?? ""
            let actions = extractActionsString(item["actions"])
            return [
                "Device": host,
                "Type": item["eventType"] as? String ?? "",
                "Severity": item["severity"] as? String ?? "",
                "Date": item["created"] as? String ?? "",
                "Status": item["status"] as? String ?? "",
                "Action Taken": actions,
            ]
        }.sorted { a, b in
            let ra = severityRank[(a["Severity"] ?? "").lowercased()] ?? 99
            let rb = severityRank[(b["Severity"] ?? "").lowercased()] ?? 99
            if ra != rb { return ra < rb }
            return (a["Date"] ?? "") < (b["Date"] ?? "")
        }

        let ws = workbook.addSheet("Protect Threat Overview")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Threat Overview"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 26)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 22)
        ws.setColumnWidth(4, 4, 14)
        ws.setColumnWidth(5, 5, 28)

        let hdrs = ["Device", "Type", "Severity", "Date", "Status", "Action Taken"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for r in rows {
            let severity = (r["Severity"] ?? "").lowercased()
            let fmt: CellFormat = (severity == "critical" || severity == "high") ? .red
                : severity == "medium" ? .yellow : .cell
            ws.write(r["Device"] ?? "", row: row, col: 0, format: .cell)
            ws.write(r["Type"] ?? "", row: row, col: 1, format: .cell)
            ws.write(r["Severity"] ?? "", row: row, col: 2, format: fmt)
            ws.write(r["Date"] ?? "", row: row, col: 3, format: .cell)
            ws.write(r["Status"] ?? "", row: row, col: 4, format: .cell)
            ws.write(r["Action Taken"] ?? "", row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Patch Summary Dashboard
    // Source: patch-status + device-compliance snapshots.

    func writePatchSummaryDashboard() throws {
        guard let patchItems = loadLatestTyped(
            names: ["patch-status", "patch_status"],
            as: [PatchStatusRow].self
        ), !patchItems.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["patch-status"])
        }

        let rawDC = try loadLatestJSON(names: ["device-compliance", "device_compliance"])
        let dcList = (rawDC as? [[String: Any]]) ?? []
        guard !dcList.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["device-compliance"])
        }

        let staleDays = config.thresholds?.resolvedStaleDays ?? 30
        let totalEnrolled = dcList.count
        let activeCount = dcList.filter { !(asBool($0["stale"]) ?? false) }.count
        let inactiveCount = totalEnrolled - activeCount
        let activeRatio = totalEnrolled > 0 ? Double(activeCount) / Double(totalEnrolled) : 0.0

        struct PatchRow {
            let title: String
            let latest: String
            let adjTotal: Int
            let adjSecondary: Int
            let adjPct: Double
        }

        let patchRows: [PatchRow] = patchItems.compactMap { item in
            let total = item.total
            let primary = item.onLatest
            let adjTotal = total > 0 ? Int((Double(total) * activeRatio).rounded()) : 0
            let adjPrimary = min(
                primary > 0 ? Int((Double(primary) * activeRatio).rounded()) : 0,
                adjTotal
            )
            let adjPct = adjTotal > 0 ? Double(adjPrimary) / Double(adjTotal) : 0.0
            return PatchRow(
                title: item.title,
                latest: item.latest,
                adjTotal: adjTotal,
                adjSecondary: max(adjTotal - adjPrimary, 0),
                adjPct: adjPct
            )
        }

        let totalTitles = patchRows.count
        let avgPct = totalTitles > 0
            ? patchRows.reduce(0.0) { $0 + $1.adjPct } / Double(totalTitles)
            : 0.0
        let excellent = patchRows.filter { $0.adjPct >= 0.95 }.count
        let good = patchRows.filter { $0.adjPct >= 0.80 && $0.adjPct < 0.95 }.count
        let warning = patchRows.filter { $0.adjPct >= 0.50 && $0.adjPct < 0.80 }.count
        let critical = patchRows.filter { $0.adjPct < 0.50 }.count
        let top10 = patchRows.sorted { $0.adjPct < $1.adjPct }.prefix(10)

        let ws = workbook.addSheet("Patch Summary Dashboard")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Patch Summary Dashboard"),
            subtitle: "Source: patch-status + device-compliance | Active window: \(staleDays) days | Generated: \(ts)",
            ncols: 9
        )
        ws.setColumnWidth(0, 0, 32)
        ws.setColumnWidth(1, 1, 20)

        // Fleet Overview section
        ws.write("FLEET OVERVIEW", row: row, col: 0, format: .header)
        row += 1
        for (label, value) in [("Total Devices", totalEnrolled), ("Active Devices", activeCount),
                                ("Inactive Devices", inactiveCount)] {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }
        let activeRatioPct = String(format: "%.1f%%", activeRatio * 100)
        ws.write("Active Device Ratio", row: row, col: 0, format: .cell)
        ws.write(activeRatioPct, row: row, col: 1, format: .cell)
        row += 2

        // Patch Statistics section
        ws.write("PATCH STATISTICS", row: row, col: 0, format: .header)
        row += 1
        ws.write("Total Patch Titles", row: row, col: 0, format: .cell)
        ws.write(totalTitles, row: row, col: 1, format: .cell)
        row += 1
        let avgPctStr = String(format: "%.1f%%", avgPct * 100)
        ws.write("Average Completion (Adjusted)", row: row, col: 0, format: .cell)
        ws.write(avgPctStr, row: row, col: 1, format: .cell)
        row += 1
        ws.write("Fully Compliant (\u{2265}95%)", row: row, col: 0, format: .cell)
        ws.write(excellent, row: row, col: 1, format: .cell)
        row += 1
        ws.write("High Risk (<50%)", row: row, col: 0, format: .cell)
        ws.write(critical, row: row, col: 1, format: .cell)
        row += 2

        // Compliance Distribution section
        ws.write("COMPLIANCE DISTRIBUTION", row: row, col: 0, format: .header)
        row += 1
        for h in ["Status", "Completion Range", "Titles"] {
            let col = ["Status", "Completion Range", "Titles"].firstIndex(of: h)!
            ws.write(h, row: row, col: col, format: .header)
        }
        row += 1
        let tiers: [(String, String, Int)] = [
            ("Excellent (\u{2265}95%)", "\u{2265}95%", excellent),
            ("Good (80\u{2013}95%)", "80\u{2013}95%", good),
            ("Warning (50\u{2013}80%)", "50\u{2013}80%", warning),
            ("Critical (<50%)", "<50%", critical),
        ]
        for (label, rng, count) in tiers {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(rng, row: row, col: 1, format: .cell)
            ws.write(count, row: row, col: 2, format: .cell)
            row += 1
        }
        row += 1

        // Top 10 Critical Patches section
        ws.setColumnWidth(0, 0, 44)
        ws.setColumnWidth(1, 3, 22)
        ws.write("TOP 10 CRITICAL PATCHES (Lowest Adjusted Completion)", row: row, col: 0,
                 format: .header)
        row += 1
        let top10Hdrs = ["Title", "Latest Version", "Adjusted Completion %", "Out of Date (Adj)"]
        for (col, h) in top10Hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for pr in top10 {
            let adjPctStr = String(format: "%.1f%%", pr.adjPct * 100)
            ws.write(pr.title, row: row, col: 0, format: .cell)
            ws.write(pr.latest, row: row, col: 1, format: .cell)
            ws.write(adjPctStr, row: row, col: 2, format: colorForPctString(adjPctStr))
            ws.write(pr.adjSecondary, row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - Device Security State
    // Source: computers snapshot (SECURITY + diskEncryption sections).

    func writeDeviceSecurityState() throws {
        let raw = try loadLatestJSON(names: ["computers", "computers-list", "computers_list"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["computers"])
        }

        struct DeviceSecurityRow {
            let name: String
            let serial: String
            let fileVault: String
            let sip: String
            let firewall: String
            let gatekeeper: String
            let bootstrapToken: String
        }

        let rows: [DeviceSecurityRow] = items.compactMap { item in
            guard let general = item["general"] as? [String: Any] else { return nil }
            let name = general["name"] as? String ?? ""
            let serial = (item["hardware"] as? [String: Any])?["serialNumber"] as? String ?? ""

            let diskEncryption = item["diskEncryption"] as? [String: Any]
            let fileVaultEnabled = diskEncryption?["fileVault2Enabled"] as? Bool
            let bootDetails = diskEncryption?["bootPartitionEncryptionDetails"] as? [String: Any]
            let fvState = bootDetails?["partitionFileVault2State"] as? String
            let fileVaultStr: String
            if let state = fvState, !state.isEmpty {
                fileVaultStr = state
            } else if let enabled = fileVaultEnabled {
                fileVaultStr = enabled ? "ENCRYPTED" : "UNENCRYPTED"
            } else {
                fileVaultStr = ""
            }

            let security = item["security"] as? [String: Any]
            let sipStr = security?["sipStatus"] as? String ?? ""
            let firewallRaw = security?["firewallEnabled"]
            let firewallStr: String
            if let b = asBool(firewallRaw) { firewallStr = b ? "ENABLED" : "DISABLED" }
            else { firewallStr = "" }
            let gatekeeperStr = security?["gatekeeperStatus"] as? String ?? ""
            let btRaw = security?["bootstrapTokenEscrowed"]
            let bootstrapStr: String
            if let b = asBool(btRaw) { bootstrapStr = b ? "ESCROWED" : "NOT ESCROWED" }
            else { bootstrapStr = "" }

            let hasAny = !fileVaultStr.isEmpty || !sipStr.isEmpty || !firewallStr.isEmpty
                || !gatekeeperStr.isEmpty || !bootstrapStr.isEmpty
            guard hasAny else { return nil }
            return DeviceSecurityRow(name: name, serial: serial, fileVault: fileVaultStr,
                                     sip: sipStr, firewall: firewallStr, gatekeeper: gatekeeperStr,
                                     bootstrapToken: bootstrapStr)
        }

        guard !rows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["computers"])
        }

        let ws = workbook.addSheet("Device Security State")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Device Security State"),
            subtitle: "Source: computers (security sections) | Generated: \(ts)",
            ncols: 7
        )
        ws.setColumnWidth(0, 0, 32)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 6, 16)

        let hdrs = ["Device Name", "Serial", "FileVault", "SIP", "Firewall",
                    "Gatekeeper", "Bootstrap Token"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = rows.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for r in sorted {
            ws.write(r.name, row: row, col: 0, format: .cell)
            ws.write(r.serial, row: row, col: 1, format: .cell)
            ws.write(r.fileVault, row: row, col: 2, format: securityControlFormat("filevault", r.fileVault))
            ws.write(r.sip, row: row, col: 3, format: securityControlFormat("sip", r.sip))
            ws.write(r.firewall, row: row, col: 4, format: securityControlFormat("firewall", r.firewall))
            ws.write(r.gatekeeper, row: row, col: 5,
                     format: securityControlFormat("gatekeeper", r.gatekeeper))
            ws.write(r.bootstrapToken, row: row, col: 6,
                     format: securityControlFormat("bootstrap_token", r.bootstrapToken))
            row += 1
        }
    }

    /// Returns green/red/neutral based on whether a security control value is compliant.
    /// Mirrors Python `_security_control_is_compliant` logic.
    private func securityControlFormat(_ control: String, _ value: String) -> CellFormat {
        guard !value.isEmpty else { return .cell }
        let v = value.uppercased()
        let compliant: Bool
        switch control {
        case "filevault":
            compliant = v == "ENCRYPTED" || v.contains("ENCRYPT")
        case "sip":
            compliant = v == "ENABLED" || v.contains("ENABLE") || v == "ACTIVE"
        case "firewall":
            compliant = v == "ENABLED" || v == "TRUE" || v == "YES"
        case "gatekeeper":
            // APP_STORE or APP_STORE_AND_IDENTIFIED_DEVELOPERS are compliant
            compliant = v.contains("APP_STORE") || v == "ENABLED" || v == "ACTIVE"
        case "bootstrap_token":
            compliant = v == "ESCROWED"
        default:
            return .cell
        }
        return compliant ? .green : .red
    }

    // MARK: - Mobile Supervision Status
    // Source: mobile-device-inventory-details (or mobile-devices-list) snapshot.
    // Per-family aggregate of supervised/unsupervised counts.

    func writeMobileSupervisionStatus() throws {
        let mobileRows = normalizeMobileInventory()
        guard !mobileRows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["mobile-device-inventory-details"])
        }

        var perFamily: [String: (total: Int, supervised: Int, unsupervised: Int)] = [:]
        for r in mobileRows {
            let family = (r["Device Family"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let key = family.isEmpty ? "Unknown" : family
            var bucket = perFamily[key] ?? (total: 0, supervised: 0, unsupervised: 0)
            bucket.total += 1
            if (r["Supervised"] as? String) == "Yes" { bucket.supervised += 1 }
            else if (r["Supervised"] as? String) == "No" { bucket.unsupervised += 1 }
            perFamily[key] = bucket
        }

        let ws = workbook.addSheet("Mobile Supervision Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Mobile Supervision Status"),
                                      subtitle: "Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 22)
        ws.setColumnWidth(1, 4, 16)

        let hdrs = ["Device Family", "Total", "Supervised", "Unsupervised", "% Supervised"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for (family, counts) in perFamily.sorted(by: { $0.key < $1.key }) {
            let pct = counts.total > 0
                ? String(format: "%.1f%%", Double(counts.supervised) / Double(counts.total) * 100)
                : "0.0%"
            ws.write(family, row: row, col: 0, format: .cell)
            ws.write(counts.total, row: row, col: 1, format: .cell)
            ws.write(counts.supervised, row: row, col: 2, format: .cell)
            ws.write(counts.unsupervised, row: row, col: 3, format: .cell)
            ws.write(pct, row: row, col: 4, format: .cell)
            row += 1
        }
    }

    // MARK: - OS Currency
    // Source: SOFA cache at `<workspace>/jamf-cli-data/sofa/<platform>_data_feed.json`.
    // Mirrors Python CoreDashboard._write_os_currency.

    func writeOSCurrency() throws {
        let noDataNote = "SOFA feed unavailable — enable network access or check sofa.enabled"

        // Load SOFA feeds from this workspace's dataDir directly.
        // dataDir is already the jamf-cli-data directory for this profile.
        let sofaSnapshot = SOFAFeedService.load(dataDir: dataDir)

        let ws = workbook.addSheet("OS Currency")
        let ts = ISO8601DateFormatter().string(from: Date())
        let headers = [
            "Platform", "OS Family", "Latest Version", "Build", "Released",
            "Days Since Release", "Actively Exploited CVEs",
            "Fleet On Latest", "Fleet Behind", "% On Latest",
        ]
        var row = ws.writeSheetHeader(
            title: t("OS Currency"),
            subtitle: "Source: SOFA (sofa.macadmins.io) | Generated: \(ts)",
            ncols: headers.count
        )
        ws.setColumnWidth(0, 1, 18)
        ws.setColumnWidth(2, 9, 16)

        guard !sofaSnapshot.rows.isEmpty else {
            ws.write(noDataNote, row: row, col: 0, format: .cell)
            return
        }

        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        // Build macOS and mobile os_version → count lookups from cached snapshots.
        let macosCounts = macosOSCounts()
        let mobileCounts = mobileOSCounts()

        // Collect family majors per platform to detect EOL devices.
        var familyMajors: [String: Set<Int>] = [:]
        for entry in sofaSnapshot.rows {
            let majorTuple = SOFAFeedService.versionTuple(entry.productVersion)
            if !majorTuple.isEmpty {
                familyMajors[entry.platform, default: []].insert(majorTuple[0])
            }
        }

        for entry in sofaSnapshot.rows {
            let counts: [String: Int]?
            switch entry.platform {
            case "macOS":        counts = macosCounts
            case "iOS / iPadOS": counts = mobileCounts
            default:             counts = nil
            }

            ws.write(entry.platform, row: row, col: 0, format: .cell)
            ws.write(entry.osFamily, row: row, col: 1, format: .cell)
            ws.write(entry.productVersion, row: row, col: 2, format: .cell)
            ws.write(entry.build, row: row, col: 3, format: .cell)
            ws.write(entry.releaseDate.isEmpty ? "\u{2014}" : entry.releaseDate,
                     row: row, col: 4, format: .cell)
            if let days = entry.daysSinceRelease {
                ws.write(days, row: row, col: 5, format: .cell)
            } else {
                ws.write("\u{2014}", row: row, col: 5, format: .cell)
            }
            let cveFmt: CellFormat = entry.activelyExploitedCVEs > 0 ? .red : .cell
            ws.write(entry.activelyExploitedCVEs, row: row, col: 6, format: cveFmt)

            if let counts {
                let (onLatest, behind) = SOFAFeedService.fleetCurrency(
                    latestVersion: entry.productVersion, osCounts: counts)
                let total = onLatest + behind
                ws.write(onLatest, row: row, col: 7, format: .cell)
                ws.write(behind, row: row, col: 8, format: .cell)
                if total > 0 {
                    let pct = String(format: "%.1f%%", Double(onLatest) / Double(total) * 100)
                    ws.write(pct, row: row, col: 9, format: .cell)
                } else {
                    ws.write("\u{2014}", row: row, col: 9, format: .cell)
                }
            } else {
                for col in 7...9 { ws.write("\u{2014}", row: row, col: col, format: .cell) }
            }
            row += 1
        }

        // EOL row: devices on majors older than every SOFA-tracked major.
        let eolSources = [("macOS", macosCounts), ("iOS / iPadOS", mobileCounts)]
        for (platform, counts) in eolSources {
            let majors = familyMajors[platform] ?? []
            let (eolDevices, eolVersions) = SOFAFeedService.fleetEOLCount(
                familyMajors: majors, osCounts: counts)
            guard eolDevices > 0 else { continue }
            ws.write(platform, row: row, col: 0, format: .cell)
            ws.write("Out of support (EOL)", row: row, col: 1, format: .red)
            let eolLabel = "\(eolVersions) version\(eolVersions == 1 ? "" : "s") older than all supported releases"
            ws.write(eolLabel, row: row, col: 2, format: .red)
            for col in 3...6 { ws.write("\u{2014}", row: row, col: col, format: .cell) }
            ws.write(0, row: row, col: 7, format: .cell)
            ws.write(eolDevices, row: row, col: 8, format: .red)
            ws.write("0.0%", row: row, col: 9, format: .cell)
            row += 1
        }
    }

    /// Returns {osVersion: count} for macOS from the cached security report.
    private func macosOSCounts() -> [String: Int] {
        guard let items = loadLatestTyped(names: ["security"], as: [SecurityReportItem].self)
        else { return [:] }
        var counts: [String: Int] = [:]
        for item in items {
            if case .osVersion(let v) = item {
                let ver = v.osVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ver.isEmpty else { continue }
                counts[ver, default: 0] += v.count
            }
        }
        return counts
    }

    /// Returns {osVersion: count} for iOS/iPadOS from the cached mobile inventory.
    private func mobileOSCounts() -> [String: Int] {
        let inventoryDir = dataDir.appendingPathComponent(
            "mobile-device-inventory-details", isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: inventoryDir),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([MobileDeviceInventoryItem].self, from: data)
        else { return [:] }
        var counts: [String: Int] = [:]
        for item in items {
            let ver = (item.general?.osVersion ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ver.isEmpty else { continue }
            counts[ver, default: 0] += 1
        }
        return counts
    }

    // MARK: - Protect Plans / Threat Overview helpers

    /// Format a list of named objects or bare strings into a comma-joined string.
    /// Handles both `[{name: "foo"}]` and `["foo"]` element shapes.
    private func formatNamedList(_ value: Any?) -> String {
        guard let arr = value as? [Any] else { return "" }
        let names = arr.compactMap { elem -> String? in
            if let dict = elem as? [String: Any], let name = dict["name"] as? String {
                return name
            }
            if let s = elem as? String { return s }
            return nil
        }
        return names.joined(separator: ", ")
    }

    /// Format analytic sets (shape: `[{analyticSet: {name: "foo"}}]` or `[{name: "foo"}]`).
    private func formatAnalyticSets(_ value: Any?) -> String {
        guard let arr = value as? [Any] else { return "" }
        let names = arr.compactMap { elem -> String? in
            if let dict = elem as? [String: Any] {
                if let nested = dict["analyticSet"] as? [String: Any],
                   let name = nested["name"] as? String { return name }
                if let name = dict["name"] as? String { return name }
            }
            if let s = elem as? String { return s }
            return nil
        }
        return names.joined(separator: ", ")
    }

    /// Convert a Bool/Int/String value to "Yes" / "No" / "".
    private func boolToYesNo(_ value: Any?) -> String {
        guard let b = asBool(value) else { return "" }
        return b ? "Yes" : "No"
    }

    /// Extract actions into a comma-joined string.
    /// Handles both `[{name: "Quarantine"}]` and `["Notify"]` element shapes.
    private func extractActionsString(_ value: Any?) -> String {
        guard let arr = value as? [Any] else { return "" }
        let names = arr.compactMap { elem -> String? in
            if let dict = elem as? [String: Any], let name = dict["name"] as? String {
                return name
            }
            if let s = elem as? String { return s }
            return nil
        }
        return names.joined(separator: ", ")
    }

    // MARK: - Executive Summary sheet

    /// Aggregated fleet KPIs collected from cached snapshots. Every field is optional;
    /// nil means the source snapshot was absent — rendered as "—" in the sheet.
    struct ExecutiveSummaryMetrics: Sendable {
        var totalDevices: Int?
        var managedCount: Int?
        var securityScore: Double?
        var securityGrade: SecurityScore.Grade?
        var patchFleetCompliancePct: Double?
        var fileVaultPct: Double?
        var sipPct: Double?
        var firewallPct: Double?
        var recentCount: Int?
        var offlineCount: Int?
        var inactiveCount: Int?
        var dormantCount: Int?
        var actionItemsP0: Int?
        var actionItemsP1: Int?
    }

    /// Assemble `ExecutiveSummaryMetrics` from the cached jamf-cli snapshots in `dataDir`.
    /// Delegates to three focused helpers, each targeting one snapshot source.
    private func buildExecutiveMetrics() -> ExecutiveSummaryMetrics {
        var m = ExecutiveSummaryMetrics()
        applySecurityMetrics(to: &m)
        applyPatchMetric(to: &m)
        applyStaleAndManaged(to: &m)
        return m
    }

    /// Populate security-derived fields from the cached `security` snapshot.
    private func applySecurityMetrics(to m: inout ExecutiveSummaryMetrics) {
        guard let items = loadLatestTyped(names: ["security"],
                                          as: [SecurityReportItem].self) else { return }
        for item in items {
            guard case .summary(let s) = item else { continue }
            let total = s.data.totalDevices ?? 0
            m.totalDevices = total
            applySecurityControlPcts(to: &m, data: s.data, total: total)
            applySecurityScoreAndActions(to: &m, data: s.data, total: total)
            break
        }
    }

    /// Populate per-control coverage percentages from a security summary.
    private func applySecurityControlPcts(
        to m: inout ExecutiveSummaryMetrics,
        data: SecuritySummaryData,
        total: Int
    ) {
        guard total > 0 else { return }
        m.fileVaultPct = data.fileVaultEncrypted.map { Double($0) / Double(total) * 100 }
        m.sipPct = data.sipEnabled.map { Double($0) / Double(total) * 100 }
        m.firewallPct = data.firewallEnabled.map { Double($0) / Double(total) * 100 }
    }

    /// Compute the weighted security score, grade, and P0/P1 action item counts.
    private func applySecurityScoreAndActions(
        to m: inout ExecutiveSummaryMetrics,
        data: SecuritySummaryData,
        total: Int
    ) {
        var counts: [SecurityScore.Metric: Int] = [:]
        if let n = data.fileVaultEncrypted { counts[.fileVault] = n }
        if let n = data.sipEnabled { counts[.sip] = n }
        if let n = data.firewallEnabled { counts[.firewall] = n }
        if !counts.isEmpty && total > 0 {
            let score = SecurityScoreCalculator.score(
                input: .init(totalDevices: total, compliantCounts: counts)
            )
            if !score.available.isEmpty {
                m.securityScore = score.value
                m.securityGrade = score.grade
            }
        }
        if let n = data.fileVaultEncrypted { m.actionItemsP0 = total - n }
        if let n = data.gatekeeperEnabled { m.actionItemsP1 = total - n }
    }

    /// Populate patch compliance % from the cached `patch-status` snapshot.
    private func applyPatchMetric(to m: inout ExecutiveSummaryMetrics) {
        guard let rows = loadLatestTyped(names: ["patch-status", "patch_status"],
                                          as: [PatchStatusRow].self),
              !rows.isEmpty else { return }
        let snap = PatchStatusService.Snapshot(
            titles: rows, failures: [], sourceFile: nil, snapshotDate: nil
        )
        m.patchFleetCompliancePct = snap.fleetCompliancePct
    }

    /// Populate managed count + stale tier buckets from the cached `device-compliance` snapshot.
    /// Uses `days_since_contact` (or legacy `days_since_checkin`) directly — avoids constructing
    /// `DeviceInventoryRecord` objects, which have a different shape than the JSON source.
    private func applyStaleAndManaged(to m: inout ExecutiveSummaryMetrics) {
        guard let raw = try? loadLatestJSON(names: ["device-compliance", "device_compliance"]),
              let items = raw as? [[String: Any]], !items.isEmpty else { return }
        m.managedCount = items.filter { asBool($0["managed"]) == true }.count
        var tierCounts: [StaleDeviceService.Tier: Int] = [:]
        for tier in StaleDeviceService.Tier.allCases { tierCounts[tier] = 0 }
        for item in items {
            let days = asInt(item["days_since_contact"]) ?? asInt(item["days_since_checkin"])
            tierCounts[StaleDeviceService.Tier.tier(for: days), default: 0] += 1
        }
        m.recentCount = tierCounts[.recent]
        m.offlineCount = tierCounts[.offline]
        m.inactiveCount = tierCounts[.inactive]
        m.dormantCount = tierCounts[.dormant]
    }

    /// Pure render helper: write metric rows from `metrics` into `ws`.
    /// Emits "—" for any nil field. Extracted for testability — test exercises
    /// this directly without touching the snapshot loader.
    ///
    /// - Parameter subtitle: Sheet subtitle, typically built by `writeExecutiveSummary`
    ///   using `snapshotSubtitle` so the data-age label reflects the actual snapshot date.
    func renderExecutiveSummaryRows(
        into ws: Worksheet,
        metrics m: ExecutiveSummaryMetrics,
        subtitle: String = "Fleet KPIs · KPI source: security + patch-status + device-compliance"
    ) {
        var row = ws.writeSheetHeader(
            title: t("Executive Summary"),
            subtitle: subtitle,
            ncols: 2
        )
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 24)

        let dash = "—"
        let scoreLabel: String = {
            guard let v = m.securityScore, let g = m.securityGrade else { return dash }
            return String(format: "%.1f", v) + " / 100 (\(g.rawValue))"
        }()

        func fmtPct(_ d: Double?) -> String {
            guard let d else { return dash }
            return String(format: "%.1f%%", d)
        }
        func fmtInt(_ n: Int?) -> String {
            guard let n else { return dash }
            return "\(n)"
        }

        let metricRows: [(String, String)] = [
            ("Security Score", scoreLabel),
            ("Total Devices", fmtInt(m.totalDevices)),
            ("Managed Devices", fmtInt(m.managedCount)),
            ("Patch Fleet Compliance", fmtPct(m.patchFleetCompliancePct)),
            ("FileVault Coverage", fmtPct(m.fileVaultPct)),
            ("SIP Coverage", fmtPct(m.sipPct)),
            ("Firewall Coverage", fmtPct(m.firewallPct)),
            // "Recent" (0–30d) is healthy — only Offline/Inactive/Dormant are stale.
            ("Recent (0–30d)", fmtInt(m.recentCount)),
            ("Stale — Offline (31–90d)", fmtInt(m.offlineCount)),
            ("Stale — Inactive (91–180d)", fmtInt(m.inactiveCount)),
            ("Stale — Dormant (180d+)", fmtInt(m.dormantCount)),
            ("P0 Action Items (FV/SIP/FW gaps)", fmtInt(m.actionItemsP0)),
            ("P1 Action Items (Gatekeeper gaps)", fmtInt(m.actionItemsP1)),
        ]

        ws.write("Metric", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        row += 1

        for (label, value) in metricRows {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    /// Sheet 1: fleet KPIs aggregated from cached snapshots. Gracefully omits
    /// any metric whose source snapshot is absent. Throws `SheetSkippable` only
    /// when no source data is available at all.
    func writeExecutiveSummary() throws {
        let metrics = buildExecutiveMetrics()
        let hasAnyData = metrics.totalDevices != nil
            || metrics.patchFleetCompliancePct != nil
            || metrics.recentCount != nil
        guard hasAnyData else {
            throw CoreDashboardError.noCachedData(names: ["security", "patch-status",
                                                           "device-compliance"])
        }

        // Build the subtitle with a "Data as of" clause when any headline KPI snapshot
        // predates today (skip-expensive preset). Only the three headline-KPI kinds are
        // checked — "inventory-summary" is always-run (today) and would suppress the
        // clause permanently if included.
        let ts = ISO8601DateFormatter().string(from: Date())
        let subtitle = snapshotSubtitle(
            names: ["security", "patch-status", "patch_status", "device-compliance"],
            generated: ts,
            prefix: "KPI source: security + patch-status + device-compliance"
        )

        let ws = workbook.addSheet("Executive Summary")
        renderExecutiveSummaryRows(into: ws, metrics: metrics, subtitle: subtitle)
    }

    // MARK: - Cover sheet

    /// Sheet 2: workbook manifest and generation metadata.
    /// Self-documents every sheet so a first-time reader knows what to click.
    func writeCoverSheet() throws {
        let ws = workbook.addSheet("Cover")
        let ts = ISO8601DateFormatter().string(from: Date())
        ws.setColumnWidth(0, 0, 42)
        ws.setColumnWidth(1, 1, 60)

        // Title row (merged across 2 cols via mergeRange)
        ws.mergeRange(firstRow: 0, firstCol: 0, lastRow: 0, lastCol: 1,
                      value: "Jamf Reports \u{00B7} Fleet Posture Report", format: .title)
        ws.freezePane(row: 1, col: 0)

        var row = 2

        // Generation metadata block
        let profile = config.jamfCli?.resolvedProfile
        let cliVersion = provenance?.jamfCLIVersion ?? "unknown"
        let metadataRows: [(String, String)] = [
            ("Generated", ts),
            ("Profile", (profile?.isEmpty ?? true) ? "default" : (profile ?? "default")),
            ("jamf-cli version", cliVersion),
            ("Run ID", provenance?.runID ?? "—"),
            ("Tenant URL", provenance?.jamfTenantURL ?? "—"),
            ("Operator", provenance?.operatorUserHost ?? "—"),
            ("Enrolled Devices", "see Fleet Overview sheet"),
        ]
        ws.write("Field", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        row += 1
        for (label, value) in metadataRows {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }
        row += 1

        // How-to-read section
        ws.write("How to read this workbook", row: row, col: 0, format: .header)
        row += 1
        let guidance: [String] = [
            "Sheet 1 (Executive Summary) — Fleet-level KPIs at a glance: security score, "
                + "patch compliance, stale device tiers, and key control coverage.",
            "Sheet 2 (Cover) — This sheet — workbook guide and sheet manifest.",
            "Sheet 3 (Compliance Posture) — Single-page executive summary: compliance %, "
                + "security controls, patch coverage, and RAG status.",
            "Sheet 4 (Fleet Overview) — Total enrolled devices, mobile counts, OS breakdown.",
            "Sheet 5 (Security Posture) — FileVault, SIP, Gatekeeper, Firewall percentages.",
            "Sheet 6 (Patch Compliance) — Per-title patch coverage, latest version vs. installed.",
            "Sheet 7 (Device Compliance) — Per-device compliance and days since check-in.",
            "Sheet 8 (Audit Summary) — jamf-cli health findings (critical, warning, info).",
            "Sheets 9–12 — Inventory and hardware detail (computers and mobile).",
            "Sheets 13–21 — Configuration health: policies, profiles, apps, software, EAs.",
            "Sheets 22–28 — Device health, patch failures, update failures, smart groups.",
            "Sheets 29–36 — Platform compliance, DDM, and Jamf Protect (optional; "
                + "shown only when data is available).",
        ]
        for line in guidance {
            ws.write(line, row: row, col: 0, format: .cell)
            row += 1
        }
        row += 1

        // Sheet manifest table
        ws.write("Sheet Manifest", row: row, col: 0, format: .header)
        ws.write("Description", row: row, col: 1, format: .header)
        row += 1
        let descriptions = sheetManifestDescriptions()
        for (i, (name, desc)) in sheetPlan.enumerated() {
            ws.write("\(i + 1). \(name)", row: row, col: 0, format: .cell)
            ws.write(descriptions[name] ?? desc, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    /// One-line description for every sheet name in the plan.
    private func sheetManifestDescriptions() -> [String: String] {
        [
            "Executive Summary": "Fleet KPIs at a glance: security score + band, fleet size, "
                + "patch compliance %, key control coverage, and stale device tiers.",
            "Cover": "This sheet — workbook guide and sheet manifest.",
            "Compliance Posture": "Executive summary: compliance %, security controls, "
                + "patch coverage, RAG-coded.",
            "Fleet Overview": "Total enrolled devices, categories, and OS distribution "
                + "from jamf-cli overview.",
            "Security Posture": "FileVault, SIP, Gatekeeper, Firewall — count and % for "
                + "every enrolled computer.",
            "Patch Compliance": "Per-title patch coverage: on-latest vs. on-other vs. "
                + "total, compliance %.",
            "Device Compliance": "Per-device managed/stale status and days since last "
                + "check-in.",
            "Audit Summary": "jamf-cli health audit findings categorised by severity.",
            "Inventory Summary": "Model + OS version combinations ranked by device count.",
            "Hardware Models": "Top 20 computer hardware models by device count.",
            "Mobile Fleet Summary": "Mobile device totals: managed, supervised, stale, "
                + "family and OS breakdown.",
            "Mobile Inventory": "Full mobile device roster with user assignment, "
                + "compliance, and staleness.",
            "Policy Health": "Policy counts and config findings from jamf-cli "
                + "policy-status.",
            "Profile Status": "Configuration profiles with management status and "
                + "error counts.",
            "Mobile Config Profiles": "Mobile configuration profiles with category "
                + "breakdown.",
            "App Status": "Managed apps: installed vs. total, errors.",
            "Software Installs": "Top software titles and install counts.",
            "Package Lifecycle": "Packages with upload age and size; highlights "
                + "stale packages.",
            "EA Coverage": "Raw EA result values per device (all EAs, all computers).",
            "EA Definitions": "Extension attribute definitions: name, data type, "
                + "description.",
            "Environment Stats": "Count of policies, profiles, scripts, packages, "
                + "smart groups, EAs.",
            "Check-in Health": "Devices checked in vs. overdue relative to configured "
                + "threshold.",
            "Active Devices": "Active vs. stale vs. unmanaged device counts.",
            "Group Hygiene": "Smart/static groups with zero members — candidates for "
                + "cleanup.",
            "Patch Failures": "Per-device patch policy failures with last action and "
                + "attempt count.",
            "Update Status": "MDM software update plan states and device totals.",
            "Update Failures": "Devices and plans with update errors.",
            "Smart Groups": "All smart groups with member counts; zero-member groups "
                + "highlighted.",
            "Compliance Devices": "Platform compliance: per-device rules passed/failed "
                + "(requires Platform entitlement).",
            "Compliance Rules": "Platform compliance: per-rule pass rate across the "
                + "fleet.",
            "DDM Status": "Declarative Device Management source status and "
                + "declaration results.",
            "Blueprint Status": "Blueprint deployment state — failed, pending, "
                + "succeeded counts.",
            "Protect Overview": "Jamf Protect instance summary (requires Protect "
                + "entitlement).",
            "Protect Alerts": "Open Protect alerts with severity and event type.",
            "Protect Computers": "Protect-enrolled computers with plan, status, and "
                + "access grants.",
            "Protect Insights": "Protect insight pass/fail counts by section.",
            "mSCP Compliance": "Per-baseline band distribution: No Data / Pass / Low / "
                + "Med-Low / Medium / High with count and percent.",
            "Compliance Trend": "Historical band counts per snapshot date for the "
                + "primary configured baseline.",
        ]
    }

    // MARK: - Compliance Posture sheet

    /// Sheet 2: single-page exec summary — seven key metrics, RAG-coded, plus
    /// a top-20 non-compliant device table sorted by failure count descending.
    func writeCompliancePosture() throws {
        let ws = workbook.addSheet("Compliance Posture")
        let ts = ISO8601DateFormatter().string(from: Date())
        let framework = config.compliance?.resolvedFramework ?? "Compliance Benchmark"
        var row = ws.writeSheetHeader(title: t("Compliance Posture"),
                                      subtitle: "Generated: \(ts)", ncols: 3)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 12)
        ws.setColumnWidth(2, 2, 10)

        // Security snapshot
        let securityData = (try? loadLatestJSON(names: ["security"])) as? [[String: Any]]
        let secSummary: [String: Any] = securityData?
            .first(where: { ($0["section"] as? String) == "summary" })?["data"]
            as? [String: Any] ?? [:]
        let totalDevices = asInt(secSummary["total_devices"]) ?? 0

        // Device compliance snapshot
        let deviceCompItems = ((try? loadLatestJSON(
            names: ["device-compliance", "device_compliance"]
        )) as? [[String: Any]]) ?? []
        let staleCount = deviceCompItems.filter { asBool($0["stale"]) == true }.count
        let managedCount = deviceCompItems.filter { asBool($0["managed"]) == true }.count
        let deviceTotal = deviceCompItems.count
        let compliancePct: Double = deviceTotal > 0
            ? Double(managedCount) / Double(deviceTotal) * 100 : 0

        // Patch compliance snapshot
        let patchItems = ((try? loadLatestJSON(
            names: ["patch-status", "patch_status"]
        )) as? [[String: Any]]) ?? []
        let patchPct = averagePatchCompliancePct(patchItems)

        // Metric rows: (label, rawValue, pctValue for RAG)
        let metrics: [(label: String, value: String, pct: Double?)] = [
            ("Device Compliance (managed %)",
             deviceTotal > 0 ? String(format: "%.0f%%", compliancePct) : "\u{2014}",
             deviceTotal > 0 ? compliancePct : nil),
            ("FileVault Encrypted",
             percentLabel(asInt(secSummary["filevault_encrypted"]), total: totalDevices),
             pctFromSummary(secSummary["filevault_encrypted"], total: totalDevices)),
            ("SIP Enabled",
             percentLabel(asInt(secSummary["sip_enabled"]), total: totalDevices),
             pctFromSummary(secSummary["sip_enabled"], total: totalDevices)),
            ("Firewall Enabled",
             percentLabel(asInt(secSummary["firewall_enabled"]), total: totalDevices),
             pctFromSummary(secSummary["firewall_enabled"], total: totalDevices)),
            ("Gatekeeper Enabled",
             percentLabel(asInt(secSummary["gatekeeper_enabled"]), total: totalDevices),
             pctFromSummary(secSummary["gatekeeper_enabled"], total: totalDevices)),
            ("Patch Compliance (avg across titles)",
             patchItems.isEmpty ? "\u{2014}" : String(format: "%.0f%%", patchPct),
             patchItems.isEmpty ? nil : patchPct),
            ("Stale Devices (>\(config.thresholds?.resolvedStaleDays ?? 30) days)",
             "\(staleCount)",
             nil),
        ]

        ws.write("Metric", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        for metric in metrics {
            let (statusLabel, statusFmt) = ragStatus(pct: metric.pct)
            ws.write(metric.label, row: row, col: 0, format: .cell)
            ws.write(metric.value, row: row, col: 1, format: .cell)
            ws.write(statusLabel, row: row, col: 2, format: statusFmt)
            row += 1
        }
        row += 1

        // Compliance band legend
        ws.write("Compliance bands: GREEN \u{2265}95% \u{00B7} AMBER \u{2265}80% \u{00B7} RED <80%",
                 row: row, col: 0, format: .subtitle)
        row += 1
        ws.write("Framework: \(framework)", row: row, col: 0, format: .subtitle)
        row += 2
        writePostureDeviceTable(ws: ws, row: row, items: deviceCompItems)
    }

    /// Write the top-20 non-compliant / stale device table for Compliance Posture.
    private func writePostureDeviceTable(
        ws: Worksheet,
        row startRow: Int,
        items: [[String: Any]]
    ) {
        let worst = items
            .filter { asBool($0["stale"]) == true || asBool($0["managed"]) == false }
            .sorted {
                let dA = asInt($0["days_since_checkin"]) ?? 0
                let dB = asInt($1["days_since_checkin"]) ?? 0
                return dA > dB
            }
            .prefix(20)

        guard !worst.isEmpty else { return }

        var row = startRow
        ws.write("Non-Compliant / Stale Devices (top 20)", row: row, col: 0, format: .header)
        row += 1
        let hdrs = ["Device Name", "Serial", "Days Since Check-in", "Stale", "Managed"]
        ws.setColumnWidth(3, 3, 10)
        ws.setColumnWidth(4, 4, 10)
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in worst {
            let isStale = asBool(item["stale"]) ?? false
            let fmt: CellFormat = isStale ? .yellow : .cell
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: fmt)
            ws.write(item["serial"] as? String ?? "", row: row, col: 1, format: fmt)
            if let days = asInt(item["days_since_checkin"]) {
                ws.write(days, row: row, col: 2, format: fmt)
            } else {
                ws.write("\u{2014}", row: row, col: 2, format: fmt)
            }
            ws.write(isStale ? "Yes" : "No", row: row, col: 3, format: fmt)
            ws.write(asBool(item["managed"]).map { $0 ? "Yes" : "No" } ?? "",
                     row: row, col: 4, format: fmt)
            row += 1
        }
    }

    /// Average patch compliance % across all titles; returns 0.0 if no data.
    private func averagePatchCompliancePct(_ items: [[String: Any]]) -> Double {
        guard !items.isEmpty else { return 0 }
        let pcts = items.compactMap { item -> Double? in
            let s = item["compliance_pct"] as? String ?? ""
            return Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }
        guard !pcts.isEmpty else { return 0 }
        return pcts.reduce(0, +) / Double(pcts.count)
    }

    /// Convert a count/total pair into a percentage Double for RAG banding.
    private func pctFromSummary(_ value: Any?, total: Int) -> Double? {
        guard let n = asInt(value), total > 0 else { return nil }
        return Double(n) / Double(total) * 100
    }

    /// Return RAG (RED/AMBER/GREEN) label and cell format for a percentage.
    /// `nil` pct means the metric is a raw count — returns "—" with no colour.
    private func ragStatus(pct: Double?) -> (String, CellFormat) {
        guard let pct else { return ("\u{2014}", .cell) }
        if pct >= 95 { return ("GREEN", .green) }
        if pct >= 80 { return ("AMBER", .yellow) }
        return ("RED", .red)
    }

    // MARK: - JSON loading helpers

    /// Load the newest cached JSON file matching any of the candidate names under `dataDir`.
    // MARK: - Typed JSON loading
    //
    // Migration recipe for moving a sheet writer from [String: Any] to typed decoders:
    //
    //   1. Call `loadLatestTyped(names:as:)` in place of `loadLatestJSON(names:)`.
    //   2. Remove `as? [[String: Any]]` / `firstDict` casts — use struct fields directly.
    //   3. If a struct field is missing or has the wrong key, extend the type in
    //      JamfCLIDecoder.swift (add the field + CodingKey) rather than falling back.
    //   4. If the decode throws (malformed JSON), the method logs the error and returns nil;
    //      the caller should `guard let` and skip the sheet body — do NOT re-throw.
    //   5. Update or add a test in CoreDashboardSecurityTests.swift following the pattern
    //      established there.

    /// Locate the newest JSON snapshot for any of the given data-kind names and decode
    /// it as `T`. Returns nil and logs a warning when the file is absent or malformed.
    ///
    /// This is the typed successor to `loadLatestJSON(names:)`. Prefer this for all new
    /// sheet writers. Existing writers will be migrated incrementally via the recipe above.
    private func loadLatestTyped<T: Decodable>(names: [String], as type: T.Type) -> T? {
        let rawData: Data
        do {
            rawData = try loadLatestJSONData(names: names)
        } catch {
            // No cached snapshot — normal on first run or missing collect step; skip silently.
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: rawData)
        } catch {
            AppLogger.report.warning(
                "CoreDashboard: failed to decode \(names.first ?? "?") as \(String(describing: type)): \(error)"
            )
            return nil
        }
    }

    /// Returns the raw `Data` of the newest JSON snapshot matching any of the given names.
    /// Throws `CoreDashboardError.noCachedData` when no matching file exists.
    /// When a sibling `manifest.json` lists this filename, verifies the file's
    /// SHA-256 matches the manifest entry. On mismatch, the verifier logs an
    /// `AppLogger` warning and this method returns the (possibly tampered)
    /// bytes — matches the Python "warn, don't abort" stance because per-sheet
    /// aborts here would bubble into `SheetSkippable` handling and just skip
    /// the sheet, not abort the run.
    ///
    /// **Strict-mode enforcement** (`jamf_cli.require_manifest: true`,
    /// PR-10 / threat-model T-11) happens upstream in
    /// `ReportEngine.preflightStrictManifestCheck` via
    /// `SnapshotManifest.scanWorkspace(dataDir:)`. If any snapshot is
    /// `.mismatch` or `.corrupt` at run start, the engine throws
    /// `ReportEngineError.snapshotIntegrityViolation` before any sheet
    /// writes begin. Closes the gap where the GUI's "Require snapshot
    /// manifest" toggle was a false promise (the original PR-10 only
    /// enforced strict mode through the Python CLI's `--strict-manifest`
    /// flag).
    private func loadLatestJSONData(names: [String]) throws -> Data {
        var candidates: [URL] = []
        let fm = FileManager.default
        for name in names {
            let subdir = dataDir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: subdir.path),
               let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
               ) {
                candidates.append(contentsOf: files.filter {
                    $0.pathExtension == "json"
                    && $0.lastPathComponent != SnapshotManifest.fileName
                })
            }
            if fm.fileExists(atPath: dataDir.path),
               let files = try? fm.contentsOfDirectory(
                at: dataDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
               ) {
                let matching = files.filter {
                    $0.pathExtension == "json"
                    && $0.lastPathComponent.hasPrefix(name + "_")
                }
                candidates.append(contentsOf: matching)
            }
        }
        guard !candidates.isEmpty else {
            throw CoreDashboardError.noCachedData(names: names)
        }
        let newest = candidates.max(by: { lhs, rhs in
            let lMod = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rMod = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lMod < rMod
        })!
        let data = try Data(contentsOf: newest)
        SnapshotManifest.verify(snapshot: newest, data: data)
        return data
    }

    private func loadLatestJSON(names: [String]) throws -> Any {
        let data = try loadLatestJSONData(names: names)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Return the modification date of the newest snapshot file for `names`, or nil
    /// when no file exists. Used by `snapshotSubtitle` to surface the data age.
    func latestSnapshotDate(names: [String]) -> Date? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for name in names {
            let subdir = dataDir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: subdir.path),
               let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
               ) {
                candidates.append(contentsOf: files.filter {
                    $0.pathExtension == "json"
                    && $0.lastPathComponent != SnapshotManifest.fileName
                })
            }
        }
        return candidates.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }.max()
    }

    /// Build a sheet subtitle that includes a "Data as of" clause when the
    /// snapshot was not collected on today's run (snapshot date != today).
    ///
    /// - Parameters:
    ///   - names: Snapshot kind names, passed directly to `latestSnapshotDate`.
    ///   - generated: The current run timestamp, typically from `ISO8601DateFormatter`.
    ///   - prefix: Optional label prefix to prepend (e.g. "Threshold: 30 days | ").
    /// - Returns: A subtitle string with an embedded data-age notice when the
    ///            snapshot predates the current run by at least one calendar day.
    func snapshotSubtitle(names: [String], generated: String, prefix: String = "") -> String {
        let base = "\(prefix.isEmpty ? "" : "\(prefix) | ")Generated: \(generated)"
        guard let snapDate = latestSnapshotDate(names: names) else { return base }
        let cal = Calendar.current
        guard !cal.isDateInToday(snapDate) else { return base }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return "\(base) | Data as of: \(df.string(from: snapDate))"
    }

    // MARK: - Value coercions

    private func asInt(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    private func asBool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as Int: return n != 0
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    private func firstDict(_ raw: Any) -> [String: Any] {
        if let arr = raw as? [[String: Any]], let first = arr.first { return first }
        if let dict = raw as? [String: Any] { return dict }
        return [:]
    }

    private func percentLabel(_ value: Int?, total: Int) -> String {
        guard let value, total > 0 else { return "0" }
        let pct = Double(value) / Double(total) * 100
        return String(format: "%d (%.1f%%)", value, pct)
    }

    private func colorForPctString(_ pct: String) -> CellFormat {
        let num = Double(pct.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
        if num >= 95 { return .green }
        if num >= 80 { return .yellow }
        return .red
    }

    // MARK: - mSCP Compliance sheet
    // Source: `ea-results` snapshots + `compliance.baselines` config.

    /// Per-baseline band-distribution table.
    ///
    /// One block per configured baseline. Each block shows a header row (total
    /// systems / devices-evaluated / compliance % / rule count if configured)
    /// followed by six band rows (No Data → High) with Count and Percent columns.
    /// Skips when no baseline is configured or no ea-results snapshot is available.
    func writeMSCPCompliance() throws {
        let baselines = config.compliance?.resolvedBaselines ?? []
        guard !baselines.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["ea-results (no baselines configured)"])
        }

        guard let eaData = try? loadLatestJSONData(names: ["ea-results"]),
              let eaRows = try? JSONDecoder().decode([EAResultRow].self, from: eaData),
              !eaRows.isEmpty
        else {
            throw CoreDashboardError.noCachedData(names: ["ea-results"])
        }

        let results = MSCPComplianceService.evaluate(rows: eaRows, baselines: baselines)
        let hasAnyData = results.contains { $0.devicesWithData > 0 }
        guard hasAnyData else {
            throw CoreDashboardError.noCachedData(names: ["ea-results"])
        }

        let ws = workbook.addSheet("mSCP Compliance")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("mSCP Compliance"),
            subtitle: "Generated: \(ts)", ncols: 3
        )
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 10)
        ws.setColumnWidth(2, 2, 10)

        for result in results {
            writeMSCPBaselineBlock(ws: ws, row: &row, result: result)
            row += 1
        }
    }

    /// Write one baseline block (header + 6 band rows) into `ws` at `row`.
    private func writeMSCPBaselineBlock(
        ws: Worksheet,
        row: inout Int,
        result: MSCPComplianceService.BaselineResult
    ) {
        // Baseline header — name from config (not from user data in the snapshot).
        ws.write(result.name, row: row, col: 0, format: .header)
        row += 1

        // Summary row: total / evaluated / compliance % / rule count
        let compliancePctStr: String
        if let pct = result.compliancePct {
            compliancePctStr = String(format: "%.1f%%", pct)
        } else {
            compliancePctStr = "\u{2014}"
        }
        let summaryPairs: [(String, String)] = [
            ("Total Systems", "\(result.totalDevices)"),
            ("Devices Evaluated", "\(result.devicesWithData)"),
            ("Compliance %", compliancePctStr),
        ]
        for (label, value) in summaryPairs {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }

        // Band distribution header
        ws.write("Band", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Percent", row: row, col: 2, format: .header)
        row += 1

        // No Data row first (spec: No Data → Pass → Low → Med-Low → Medium → High).
        let total = result.totalDevices
        let noDataPct = total > 0 ? Double(result.noDataCount) / Double(total) * 100 : 0
        ws.write("No Data", row: row, col: 0, format: .cell)
        ws.write(result.noDataCount, row: row, col: 1, format: .cell)
        ws.write(String(format: "%.1f%%", noDataPct), row: row, col: 2, format: .cell)
        row += 1

        // bands is in Band.allCases order: pass, low, medLow, medium, high, noData
        // (noData is the last element but we rendered it first, so skip index 5).
        let bandLabels = ["Pass (0)", "Low (1\u{2013}10)", "Med-Low (11\u{2013}30)",
                          "Medium (31\u{2013}50)", "High (>50)"]
        let bandFormats: [CellFormat] = [.green, .cell, .yellow, .yellow, .red]
        let nonNoDataBands = result.bands.filter { $0.label != "No Data" }
        for (idx, band) in nonNoDataBands.enumerated() {
            let label = idx < bandLabels.count ? bandLabels[idx] : band.label
            let fmt = idx < bandFormats.count ? bandFormats[idx] : .cell
            ws.write(label, row: row, col: 0, format: fmt)
            ws.write(band.count, row: row, col: 1, format: fmt)
            ws.write(String(format: "%.1f%%", band.pct), row: row, col: 2, format: fmt)
            row += 1
        }
    }

    // MARK: - Compliance Trend sheet
    // Source: dated `ea-results` snapshots under dataDir.

    /// Historical band counts per snapshot date for the primary configured baseline.
    ///
    /// Uses `MSCPChartDataBuilder.buildSeries` against the `ea-results/` subdir of
    /// `dataDir`. Summaries are not loaded here (CoreDashboard has no profile/path
    /// to the summaries dir); the builder's ea-results source provides full fidelity.
    /// Skips when no baseline is configured or fewer than one dated snapshot exists.
    func writeComplianceTrend() throws {
        let baselines = config.compliance?.resolvedBaselines ?? []
        guard !baselines.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["ea-results (no baselines configured)"])
        }

        guard let primary = baselines.first else {
            throw CoreDashboardError.noCachedData(names: ["ea-results"])
        }

        // buildSeries reads ea-results/ under dataDir; pass summaries:[] since
        // CoreDashboard has no access to the profile's summaries directory.
        let points = MSCPChartDataBuilder.buildSeries(
            baseline: primary,
            dataDir: dataDir,
            summaries: []
        )
        guard !points.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["ea-results"])
        }

        let ws = workbook.addSheet("Compliance Trend")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Compliance Trend — \(primary.name)"),
            subtitle: "Generated: \(ts)", ncols: 7
        )
        ws.setColumnWidth(0, 0, 14)
        ws.setColumnWidth(1, 6, 12)

        let headers = ["Date", "Pass (0)", "Low (1\u{2013}10)", "Med-Low (11\u{2013}30)",
                       "Medium (31\u{2013}50)", "High (>50)", "Total"]
        for (col, header) in headers.enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        for point in points {
            let counts = point.counts
            let total = counts.pass + counts.low + counts.medLow
                + counts.medium + counts.high + counts.noData
            ws.write(df.string(from: point.date), row: row, col: 0, format: .cell)
            ws.write(counts.pass,   row: row, col: 1, format: .cell)
            ws.write(counts.low,    row: row, col: 2, format: .cell)
            ws.write(counts.medLow, row: row, col: 3, format: .cell)
            ws.write(counts.medium, row: row, col: 4, format: .cell)
            ws.write(counts.high,   row: row, col: 5, format: .cell)
            ws.write(total,         row: row, col: 6, format: .cell)
            row += 1
        }
    }
}

// MARK: - CoreDashboard errors

enum CoreDashboardError: Error, LocalizedError, SheetSkippable {
    case noCachedData(names: [String])

    var errorDescription: String? {
        switch self {
        case .noCachedData(let names):
            return "No cached jamf-cli snapshot found for: \(names.joined(separator: ", "))"
        }
    }
}
