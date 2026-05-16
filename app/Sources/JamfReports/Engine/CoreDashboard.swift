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
    /// `SheetOrderTests.swift`. Also add a matching sheet in the Python `CoreDashboard`
    /// in `jamf-reports-community.py` to keep both implementations in sync.
    var sheetPlan: [(name: String, write: () throws -> Void)] {
        [
            // --- Framing / exec-priority (sheets 1–7) ---
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
            // --- Protect (sheets 32–35, optional) ---
            ("Protect Overview", writeProtectOverview),
            ("Protect Alerts", writeProtectAlerts),
            ("Protect Computers", writeProtectComputers),
            ("Protect Insights", writeProtectInsights),
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
                                      subtitle: "Generated: \(ts)", ncols: 5)
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

        let ws = workbook.addSheet("Patch Compliance")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Patch Compliance"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 10)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 12)
        ws.setColumnWidth(4, 4, 14)
        ws.setColumnWidth(5, 5, 14)

        let headers = ["Title", "Latest", "On Latest", "On Other", "Total", "Compliance %"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            ws.write(item.title, row: row, col: 0, format: .cell)
            ws.write(item.latest, row: row, col: 1, format: .cell)
            ws.write(item.onLatest, row: row, col: 2, format: .cell)
            ws.write(item.onOther, row: row, col: 3, format: .cell)
            ws.write(item.total, row: row, col: 4, format: .cell)
            ws.write(item.compliancePct, row: row, col: 5, format: colorForPctString(item.compliancePct))
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
                                      subtitle: "Generated: \(ts)", ncols: 8)
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
                                      subtitle: "Generated: \(ts)", ncols: 4)
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
                                      subtitle: "Generated: \(ts)", ncols: 8)
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
                                      subtitle: "Generated: \(ts)", ncols: 5)
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
                                      subtitle: "Generated: \(ts)", ncols: 5)
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

    // MARK: - Cover sheet

    /// Sheet 1: workbook manifest and generation metadata.
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
            "Sheet 2 (Compliance Posture) — Single-page executive summary: compliance %, "
                + "security controls, patch coverage, and RAG status.",
            "Sheet 3 (Fleet Overview) — Total enrolled devices, mobile counts, OS breakdown.",
            "Sheet 4 (Security Posture) — FileVault, SIP, Gatekeeper, Firewall percentages.",
            "Sheet 5 (Patch Compliance) — Per-title patch coverage, latest version vs. installed.",
            "Sheet 6 (Device Compliance) — Per-device compliance and days since check-in.",
            "Sheet 7 (Audit Summary) — jamf-cli health findings (critical, warning, info).",
            "Sheets 8–11 — Inventory and hardware detail (computers and mobile).",
            "Sheets 12–20 — Configuration health: policies, profiles, apps, software, EAs.",
            "Sheets 21–27 — Device health, patch failures, update failures, smart groups.",
            "Sheets 28–35 — Platform compliance, DDM, and Jamf Protect (optional; "
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
        ]
    }

    // MARK: - Compliance Posture sheet

    /// Sheet 2: single-page exec summary — seven key metrics, RAG-coded, plus
    /// a top-20 non-compliant device table sorted by failure count descending.
    func writeCompliancePosture() throws {
        let ws = workbook.addSheet("Compliance Posture")
        let ts = ISO8601DateFormatter().string(from: Date())
        let framework = config.compliance?.resolvedFramework ?? "NIST 800-53 Moderate"
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
            AppLogger.engine.warning(
                "CoreDashboard: failed to decode \(names.first ?? "?") as \(String(describing: type)): \(error)"
            )
            return nil
        }
    }

    /// Returns the raw `Data` of the newest JSON snapshot matching any of the given names.
    /// Throws `CoreDashboardError.noCachedData` when no matching file exists.
    /// When a sibling `manifest.json` lists this filename, verifies the file's
    /// SHA-256 matches the manifest entry. On mismatch, logs a warning via
    /// `AppLogger` and continues (matches the Python "warn, don't abort" stance —
    /// tampering vs staleness from a partial collect is hard to distinguish).
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
