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
    /// GUI-generate-only AI executive narrative (F3). nil (the default) writes
    /// no AI block on the Executive Summary sheet — headless callers never set it.
    let aiNarrative: String?
    /// Shared by the copies of this struct that `sheetPlan`'s closures hold.
    private let hardwareIndex = OnceCache<[String: Bool]>()
    /// The `computers` snapshot's dates, read once for every sheet that grades by the stale rule.
    private let computerDateIndex = OnceCache<ComputerDateIndex?>()

    init(
        config: ReportConfig,
        dataDir: URL,
        workbook: Workbook,
        provenance: Provenance? = nil,
        aiNarrative: String? = nil
    ) {
        self.config = config
        self.dataDir = dataDir
        self.workbook = workbook
        self.provenance = provenance
        self.aiNarrative = aiNarrative
    }

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
    /// `sheets.only` / `skip` / `order` are applied by `SheetRegistry.writeSelected` and
    /// `Workbook.arrange(by:)`.
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
            // --- Inventory & hardware (sheets 9–12) ---
            ("Inventory Summary", writeInventorySummary),
            ("Hardware Models", writeHardwareModels),
            ("Mobile Fleet Summary", writeMobileFleetSummary),
            ("Mobile Inventory", writeMobileInventory),
            // --- Configuration health (sheets 13–21) ---
            ("Policy Health", writePolicyHealth),
            ("Profile Status", writeProfileStatus),
            ("Mobile Config Profiles", writeMobileConfigProfiles),
            ("App Status", writeAppStatus),
            ("Software Installs", writeSoftwareInstalls),
            ("Package Lifecycle", writePackageLifecycle),
            ("EA Coverage", writeEACoverage),
            ("EA Definitions", writeEADefinitions),
            ("Environment Stats", writeEnvironmentStats),
            // --- Device health (sheets 22–24) ---
            ("Check-in Health", writeCheckinHealth),
            ("Active Devices", writeActiveDevices),
            ("Group Hygiene", writeGroupHygiene),
            // --- Update & patch details (sheets 25–28) ---
            ("Patch Failures", writePatchFailures),
            ("Update Status", writeUpdateStatus),
            ("Update Failures", writeUpdateFailures),
            ("Smart Groups", writeSmartGroups),
            // --- Platform / DDM (sheets 29–34, optional) ---
            ("Compliance Devices", writeComplianceDevices),
            ("Compliance Rules", writeComplianceRules),
            ("DDM Status", writeDDMStatus),
            ("Blueprint Status", writeBlueprintStatus),
            ("DDM Device Status", writeDDMDeviceStatus),
            ("MDM Command Health", writeMDMCommandHealth),
            // --- Protect (sheets 35–40, optional) ---
            ("Protect Overview", writeProtectOverview),
            ("Protect Alerts", writeProtectAlerts),
            ("Protect Computers", writeProtectComputers),
            ("Protect Insights", writeProtectInsights),
            ("Protect Plans", writeProtectPlans),
            ("Protect Threat Overview", writeProtectThreatOverview),
            // --- Parity / detail sheets (sheets 41–44) ---
            ("Patch Summary Dashboard", writePatchSummaryDashboard),
            ("Patch Velocity", writePatchVelocity),
            ("Device Security State", writeDeviceSecurityState),
            ("Mobile Supervision Status", writeMobileSupervisionStatus),
            // --- OS currency (sheet 45) ---
            ("OS Currency", writeOSCurrency),
            // --- mSCP / STIG compliance (sheets 46–47) ---
            ("mSCP Compliance", writeMSCPCompliance),
            ("Compliance Trend", writeComplianceTrend),
        ]
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
            var fields: [(String, String)] = [
                ("Total Devices", "\(total)"),
                ("FileVault Encrypted", percentLabel(s.fileVaultEncrypted, total: total)),
                ("Gatekeeper Enabled", percentLabel(s.gatekeeperEnabled, total: total)),
                ("SIP Enabled", percentLabel(s.sipEnabled, total: total)),
                ("Firewall Enabled", percentLabel(s.firewallEnabled, total: total)),
            ]
            let fleet = securityFleet(items: items)
            if let n = fleet?.fileVaultOffHardwareEncrypted, n > 0 {
                fields.insert((SecurityFleetCounts.hardwareEncryptedRowLabel, "\(n)"), at: 2)
            }
            fields += notReportedFields(fleet)
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
            let combined = OSVersionName.merged(osVersionRows.map {
                .init(version: $0.osVersion, count: $0.count, pct: OSVersionName.percent($0.pct))
            })
            for v in combined {
                ws.write(v.version, row: row, col: 0, format: .cell)
                ws.write(v.count, row: row, col: 1, format: .cell)
                ws.write(String(format: "%.1f%%", v.pct), row: row, col: 2, format: .cell)
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

    // MARK: - Patch Velocity
    // Source: dated `patch-status` snapshots + merged `patch-release-dates`.

    /// Patch adoption velocity — how fast each title reaches 50% / 90% adoption
    /// measured from its release date, built from dated `patch-status` history.
    ///
    /// Always writes (never `SheetSkippable`): when no dated history exists yet the
    /// sheet carries a single "No dated patch history yet" note row so the tab is
    /// present but honest. nils render "—" (never fabricated zeros). The top-titles
    /// trend chart embeds below the table when charts are enabled.
    func writePatchVelocity() throws {
        let releaseRows = PatchReleaseDateService.load(dataDir: dataDir)
        let velocities = PatchVelocityBuilder.compute(dataDir: dataDir, releaseRows: releaseRows)

        let ws = workbook.addSheet("Patch Velocity")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Patch Velocity"),
            subtitle: "Adoption speed vs. release date — Generated: \(ts)",
            ncols: 7
        )
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 18)
        ws.setColumnWidth(4, 4, 12)
        ws.setColumnWidth(5, 5, 12)
        ws.setColumnWidth(6, 6, 12)

        guard !velocities.isEmpty else {
            ws.write("No dated patch history yet", row: row, col: 0, format: .cell)
            return
        }

        let headers = ["Title", "Released", "Days Behind", "Current Adoption %",
                       "Days to 50%", "Days to 90%", "Data Points"]
        for (col, header) in headers.enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1

        // Every row nil release date is indistinguishable from "everyone's on
        // time" — call it out so it isn't read as a clean bill of health.
        if velocities.allSatisfy({ $0.releaseDate == nil }) {
            ws.write(
                "Release dates unavailable — collect patch-release-dates to compute "
                    + "days-behind and adoption speed.",
                row: row, col: 0, format: .cell
            )
            row += 1
        }

        let dash = "\u{2014}"
        for v in velocities {
            ws.write(v.title, row: row, col: 0, format: .cell)
            ws.write(v.releaseDate.map { patchVelocityDateFormatter.string(from: $0) } ?? dash,
                     row: row, col: 1, format: .cell)
            ws.write(v.daysBehind.map { "\($0)" } ?? dash, row: row, col: 2, format: .cell)
            ws.write(v.adoptionPct.map { String(format: "%.1f%%", $0) } ?? dash,
                     row: row, col: 3, format: .cell)
            ws.write(v.daysTo50.map { "\($0)" } ?? dash, row: row, col: 4, format: .cell)
            ws.write(v.daysTo90.map { "\($0)" } ?? dash, row: row, col: 5, format: .cell)
            ws.write("\(v.series.count)", row: row, col: 6, format: .cell)
            row += 1
        }

        embedPatchVelocityChart(ws: ws, row: &row, velocities: velocities)
    }

    /// Embed a line chart of the five lowest-adoption titles' series below the table.
    /// Skipped when charts are disabled or embedding is off, or when no chart renders.
    private func embedPatchVelocityChart(
        ws: Worksheet, row: inout Int, velocities: [TitleVelocity]
    ) {
        let charts = config.charts
        guard charts?.enabled != false, charts?.embedInXlsx != false else { return }

        // Lowest current adoption first; only titles with a measured adoption + points.
        let ranked = velocities
            .filter { $0.adoptionPct != nil && !$0.series.isEmpty }
            .sorted { ($0.adoptionPct ?? 0) < ($1.adoptionPct ?? 0) }
            .prefix(5)
        guard ranked.count >= 1 else { return }

        let series: [ChartSeries] = ranked.enumerated().map { (idx, v) in
            let points = v.series.map { (date: $0.date, value: $0.adoptionPct) }
            return ChartSeries(label: v.title, color: ChartPalette.color(for: idx), points: points)
        }
        guard let png = ChartRenderer.lineChart(
            series: series,
            title: "Lowest-Adoption Titles — Adoption %",
            yLabel: "Adoption %"
        ) else { return }

        row += 1
        ws.insertImage(row: row, col: 0, data: png, filename: "patch_velocity.png")
        row += 20
    }

    /// Release-date display formatter for the Patch Velocity sheet (date-only, UTC).
    private var patchVelocityDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
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
        let items = try loadDeviceComplianceRows()
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

        guard !items.isEmpty else { return }

        let headers = ["Name", "Serial", "Managed", "Stale", "Days Since Check-in"]
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for item in items {
            let isStale = isStaleDevice(item)
            let fmt: CellFormat = isStale ? .yellow : .cell
            ws.write(item.name ?? "", row: row, col: 0, format: fmt)
            ws.write(item.serial ?? "", row: row, col: 1, format: fmt)
            ws.write(item.managed.map { $0 ? "Yes" : "No" } ?? "", row: row, col: 2, format: fmt)
            ws.write(isStale ? "Yes" : "No", row: row, col: 3, format: fmt)
            if let d = item.resolvedDaysSinceContact {
                ws.write(d, row: row, col: 4, format: fmt)
            } else {
                ws.write("", row: row, col: 4, format: fmt)
            }
            row += 1
        }
    }

    /// Typed device-compliance rows from the newest snapshot. Throws `noCachedData` when there
    /// is none and the decode error when the file is corrupt, so a corrupt cache fails the
    /// sheet ([fail]) instead of skipping it.
    private func loadDeviceComplianceRows() throws -> [DeviceComplianceRow] {
        let data = try loadLatestJSONData(names: ["device-compliance", "device_compliance"])
        return try JSONDecoder().decode([DeviceComplianceRow].self, from: data)
    }

    /// Whether a Mac is stale under the stale rule (`thresholds.stale_device_days` and
    /// `stale_basis`), the meaning of every "stale" label in the workbook. jamf-cli's own
    /// `stale` flag is a 14-day cut that the row only falls back to when it knows no date.
    private func isStaleDevice(_ row: DeviceComplianceRow) -> Bool {
        isStale(row, rule: config.staleRule)
    }

    private func isStale(_ row: DeviceComplianceRow, rule: StaleRule) -> Bool {
        row.isStale(rule, computers: computerDates(for: rule))
    }

    /// The dates of each Mac in `computers`, only when `rule` counts a date the
    /// device-compliance rows lack.
    private func computerDates(for rule: StaleRule) -> ComputerDateIndex? {
        guard rule.needsComputers else { return nil }
        return computerDateIndex.value {
            (try? loadLatestJSONData(names: ["computers", "computers-list", "computers_list"]))
                .flatMap(ComputerDateIndex.init)
        }
    }

    /// What a sheet's subtitle says about the rule: the window, and the dates when they are
    /// not just the check-in.
    private func ruleSubtitle(_ rule: StaleRule, window: String = "Stale threshold") -> String {
        rule.usesDefaultBasis
            ? "\(window): \(rule.days) days"
            : "\(window): \(rule.days) days since \(rule.basisPhrase)"
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
    // Source: `jamf-cli pro report profile-status --output json`, one envelope
    // `[{summary, failures, device_failures, device_pending}]`. `failures` lists each profile
    // that errored in the report window; `classic-macos-profiles` only has {id, name}.

    func writeProfileStatus() throws {
        let names = ["profile-status", "profile_status"]
        guard let report = try loadFailureReport(names: names, uniqueKey: "unique_profiles") else {
            throw CoreDashboardError.noCachedData(names: ["profile-status"])
        }
        let ws = workbook.addSheet("Profile Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        writeFailureReport(
            ws, report, title: "Profile Status", subject: "Profiles",
            subtitle: snapshotSubtitle(names: names, generated: ts),
            warnAtErrors: config.thresholds?.resolvedProfileErrorWarning ?? 10)
    }

    // MARK: - App Status
    // Source: `jamf-cli pro report app-status --output json`, the same envelope as
    // profile-status with `unique_apps` in the summary.

    func writeAppStatus() throws {
        let names = ["app-status", "app_status"]
        guard let report = try loadFailureReport(names: names, uniqueKey: "unique_apps") else {
            throw CoreDashboardError.noCachedData(names: ["app-status"])
        }
        let ws = workbook.addSheet("App Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        writeFailureReport(
            ws, report, title: "App Status", subject: "Apps",
            subtitle: snapshotSubtitle(names: names, generated: ts), warnAtErrors: 1)
    }

    /// What `profile-status` and `app-status` carry: the window, the totals and one row per
    /// profile or app that errored.
    private struct FailureReport {
        let days: Int?
        let totalErrors: Int
        let uniqueItems: Int
        let uniqueDevices: Int
        let failures: [[String: Any]]
    }

    /// Reads the newest snapshot of `names` as a `FailureReport`. Throws `noCachedData` when
    /// there is none and the parse error when the file is corrupt; nil when it is valid JSON
    /// that is not the `{summary, failures}` envelope.
    private func loadFailureReport(names: [String], uniqueKey: String) throws -> FailureReport? {
        let raw = try loadLatestJSON(names: names)
        guard let envelope = (raw as? [[String: Any]])?.first,
              envelope["summary"] != nil || envelope["failures"] != nil else { return nil }
        let summary = envelope["summary"] as? [String: Any] ?? [:]
        let failures = (envelope["failures"] as? [[String: Any]]) ?? []
        return FailureReport(
            days: asInt(summary["days"]),
            totalErrors: asInt(summary["total_errors"]) ?? 0,
            uniqueItems: asInt(summary[uniqueKey]) ?? failures.count,
            uniqueDevices: asInt(summary["unique_devices"]) ?? 0,
            failures: failures)
    }

    /// Summary rows, then one table row per failing profile or app, most errors first. An
    /// errors cell turns yellow at `warnAtErrors` or more.
    private func writeFailureReport(
        _ ws: Worksheet, _ report: FailureReport,
        title: String, subject: String, subtitle: String, warnAtErrors: Int
    ) {
        var row = ws.writeSheetHeader(title: t(title), subtitle: subtitle, ncols: 7)
        for (col, width) in [8.0, 36, 14, 10, 10, 14, 60].enumerated() {
            ws.setColumnWidth(col, col, width)
        }
        let window = report.days.map { "last \($0) days" } ?? "report window"
        let summary: [(String, Int)] = [
            ("\(subject) with errors", report.uniqueItems),
            ("Devices affected", report.uniqueDevices),
            ("Total errors", report.totalErrors),
        ]
        ws.write("Install errors, \(window)", row: row, col: 0, format: .header)
        ws.write("", row: row, col: 1, format: .header)
        row += 1
        for (label, value) in summary {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }
        row += 1
        guard !report.failures.isEmpty else {
            ws.write("No \(subject.lowercased()) reported install errors.",
                     row: row, col: 0, format: .cell)
            return
        }

        let hdrs = ["ID", "Name", "Device Type", "Errors", "Devices", "Last Error", "Top Error"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        let ordered = report.failures.sorted {
            (asInt($0["errors"]) ?? 0) > (asInt($1["errors"]) ?? 0)
        }
        for item in ordered {
            let errors = asInt(item["errors"]) ?? 0
            let id = item["id"] as? String ?? asInt(item["id"]).map(String.init) ?? ""
            ws.write(id, row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["device_type"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(errors, row: row, col: 3, format: errors >= warnAtErrors ? .yellow : .cell)
            ws.write(asInt(item["devices"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(item["last_error"] as? String ?? "", row: row, col: 5, format: .cell)
            ws.write(item["top_error"] as? String ?? "", row: row, col: 6, format: .cell)
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
            // jamf-cli writes `dataType`; `data_type` is the legacy `ea-definitions` spelling.
            let dataType = item["dataType"] as? String ?? item["data_type"] as? String
            ws.write(ExtensionAttribute.dataTypeLabel(dataType), row: row, col: 2, format: .cell)
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
    // Sources: overview + mobile-devices-list (or a legacy mobile-device-inventory-details)
    // + classic-ios-profiles

    func writeMobileFleetSummary() throws {
        let mobileRows = normalizeMobileInventory()
        let profileRows = normalizeMobileProfiles()
        guard !mobileRows.isEmpty || !profileRows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["mobile-devices-list"])
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
                ("Managed Rows", countCell(summary.managed)),
                ("Unmanaged Rows", countCell(summary.unmanaged)),
                ("Supervised Devices", countCell(summary.supervised)),
                ("Shared iPad Devices", countCell(summary.sharedIPad)),
                ("Assigned Users", summary.assigned),
                ("Activation Lock Enabled", countCell(summary.activationLock)),
                ("Passcode Compliant", countCell(summary.passcodeCompliant)),
                ("Inventory Older Than \(staleThreshold) Days", countCell(summary.stale)),
            ]
            if summary.managed != nil, summary.managementUnknown > 0 {
                summaryPairs.insert(("Management State Unknown", summary.managementUnknown), at: 3)
            }
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
    // Source: mobile-devices-list (or a newer legacy mobile-device-inventory-details)

    func writeMobileInventory() throws {
        let rows = normalizeMobileInventory()
        guard !rows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["mobile-devices-list"])
        }

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let summary = summarizeMobileInventory(rows, staleDays: staleThreshold)

        let ws = workbook.addSheet("Mobile Inventory")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Mobile Inventory"),
                                      subtitle: "Generated: \(ts)", ncols: 20)

        var summaryPairs: [(String, Any)] = [
            ("Total Mobile Devices", summary.total),
            ("Managed", countCell(summary.managed)),
            ("Unmanaged", countCell(summary.unmanaged)),
            ("Supervised", countCell(summary.supervised)),
            ("Shared iPad", countCell(summary.sharedIPad)),
            ("Assigned Users", summary.assigned),
            ("Inventory Older Than Threshold", countCell(summary.stale)),
        ]
        if summary.managed != nil, summary.managementUnknown > 0 {
            summaryPairs.insert(("Management State Unknown", summary.managementUnknown), at: 3)
        }
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
        guard let items = loadLatestTyped(names: ["device-compliance", "device_compliance"],
                                          as: [DeviceComplianceRow].self), !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["device-compliance"])
        }

        let threshold = config.thresholds?.resolvedCheckinOverdueDays ?? 7
        // The overdue window is its own threshold, counted over the dates `stale_basis` lists.
        let overdueRule = config.staleRule.with(days: threshold)
        let ws = workbook.addSheet("Check-in Health")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Check-in Health"),
            subtitle: "\(ruleSubtitle(overdueRule, window: "Threshold")) | Generated: \(ts)",
            ncols: 6)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 2, 18)
        ws.setColumnWidth(3, 3, 18)
        ws.setColumnWidth(4, 4, 18)
        ws.setColumnWidth(5, 5, 26)

        let total = items.count
        // "Overdue (>N days)": a Mac at exactly N days is still current. A row with no date
        // falls back to jamf-cli's own `stale` flag, as this sheet did for every row
        // before `checkin_overdue_days` was read.
        let overdue = items.filter { isStale($0, rule: overdueRule) }.count
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
        row += 2
        writeContactDetail(ws: ws, row: row, overdueRule: overdueRule)
    }

    /// The Macs that are overdue or that MDM reaches while their check-in or inventory lags
    /// (`ContactGap`), each with its three dates, read from the `computers` snapshot. Nothing
    /// is written without one, or when no Mac qualifies.
    private func writeContactDetail(ws: Worksheet, row startRow: Int, overdueRule: StaleRule) {
        guard let raw = try? loadLatestJSON(
                names: ["computers", "computers-list", "computers_list"]),
              let computers = raw as? [[String: Any]] else { return }
        let gapDays = config.contactGapDays
        let now = Date()
        struct Entry {
            let name: String
            let serial: String
            let dates: ComputerDates
            let gap: ContactGap?
            let age: StaleAge?
        }
        let entries: [Entry] = computers.compactMap { item in
            let dates = ComputerDates(item: item)
            let inputs = StaleInputs(
                checkIn: dates.checkIn, inventory: dates.inventory, contact: dates.contact,
                carriesDates: true)
            let age = overdueRule.age(of: inputs, now: now)
            let gap = ContactGap.of(
                checkIn: dates.checkIn, inventory: dates.inventory, contact: dates.contact,
                staleDays: config.staleRule.days, gapDays: gapDays, now: now)
            let overdue = age.map { $0 > .days(overdueRule.days) } ?? false
            guard gap != nil || overdue else { return nil }
            let general = item["general"] as? [String: Any]
            let hardware = item["hardware"] as? [String: Any]
            return Entry(name: general?["name"] as? String ?? item["name"] as? String ?? "",
                         serial: hardware?["serialNumber"] as? String ?? "",
                         dates: dates, gap: gap, age: age)
        }.sorted { lhs, rhs in
            if (lhs.gap != nil) != (rhs.gap != nil) { return lhs.gap != nil }
            return (lhs.age ?? .days(0)) > (rhs.age ?? .days(0))
        }
        guard !entries.isEmpty else { return }
        var row = startRow
        let headers = ["Name", "Serial", "Last Contact", "Last Check-in", "Last Inventory",
                       "Contact gap"]
        for (col, header) in headers.enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for entry in entries {
            let fmt: CellFormat = entry.gap != nil ? .yellow : .cell
            let cells = [entry.name, entry.serial, Self.dayText(entry.dates.contact),
                         Self.dayText(entry.dates.checkIn), Self.dayText(entry.dates.inventory),
                         entry.gap?.label ?? ""]
            for (col, cell) in cells.enumerated() {
                ws.write(cell, row: row, col: col, format: fmt)
            }
            row += 1
        }
    }

    /// A date as `yyyy-MM-dd`, empty when the Mac has none.
    private static func dayText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
        let items = try loadDeviceComplianceRows()
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["device-compliance"])
        }

        let total = items.count
        let stale = items.filter(isStaleDevice).count
        let active = total - stale
        let managed = items.filter { $0.managed == true }.count

        let ws = workbook.addSheet("Active Devices")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Active Devices"),
            subtitle: "\(ruleSubtitle(config.staleRule)) | Generated: \(ts)", ncols: 2)
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
    // Shape: [{id, packageName, fileName, notes, size?, ...}]. The Jamf Pro packages payload
    // has no upload date and reports `size` as "" for every package, so the date, age, size
    // and bucket columns appear only when some package carries the value.

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
        let uploadKeys = ["upload_date", "uploadDate", "dateUploaded", "created", "updated"]
        let ages = sorted.map { daysSinceDate(firstStringValue($0, keys: uploadKeys)) }
        let sizes = sorted.map { packageSizeMB($0["size"]) }
        let showAge = ages.contains { $0 != nil }
        let showSize = sizes.contains { $0 != nil }

        let summaryPairs: [(String, Int)] = [
            ("Total Packages", sorted.count),
            ("Known Sizes", sizes.filter { $0 != nil }.count),
        ]
        for (idx, (label, value)) in summaryPairs.enumerated() {
            ws.write(label, row: row, col: idx * 2, format: .header)
            ws.write(value, row: row, col: idx * 2 + 1, format: .cell)
        }
        row += 1
        if !showAge || !showSize {
            let missing = [showAge ? nil : "upload date", showSize ? nil : "size"]
                .compactMap { $0 }.joined(separator: " or ")
            ws.write("Jamf reports no \(missing) for these packages, so those columns are "
                     + "left out.", row: row, col: 0, format: .subtitle)
            row += 1
        }
        row += 1

        var headers = ["Package Name", "Filename"]
        if showAge { headers += ["Upload Date", "Age (days)", "Age Bucket"] }
        if showSize { headers.append("Size (MB)") }
        headers.append("Note")
        for (col, h) in headers.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        for (index, pkg) in sorted.enumerated() {
            let name = firstStringValue(pkg, keys: ["packageName", "name"])
            let filename = firstStringValue(pkg, keys: ["fileName", "filename"])
            let note = pkg["notes"] as? String ?? ""
            let (bucket, fmt) = packageAgeBucket(ages[index])

            var col = 0
            func put(_ value: String) { ws.write(value, row: row, col: col, format: fmt); col += 1 }
            func put(_ value: Int?) {
                if let value { ws.write(value, row: row, col: col, format: fmt) }
                else { ws.write("", row: row, col: col, format: fmt) }
                col += 1
            }
            put(name)
            put(filename.isEmpty ? name : filename)
            if showAge {
                put(firstStringValue(pkg, keys: uploadKeys))
                put(ages[index])
                put(bucket)
            }
            if showSize {
                if let mb = sizes[index] { ws.write(mb, row: row, col: col, format: fmt) }
                else { ws.write("", row: row, col: col, format: fmt) }
                col += 1
            }
            put(note)
            row += 1
        }
    }

    /// The Age Bucket label and colour for a package's age in days.
    private func packageAgeBucket(_ days: Int?) -> (String, CellFormat) {
        guard let days else { return ("Unknown", .cell) }
        if days <= 30 { return ("0-30 days", .green) }
        if days <= 90 { return ("31-90 days", .yellow) }
        return ("91+ days", .red)
    }

    // MARK: - Mobile inventory helpers

    /// The inventory rows the mobile sheets read: the newest `mobile-devices-list`, or a
    /// newer legacy `mobile-device-inventory-details` snapshot, whose rows carry sections.
    /// Same choice the Mobile Fleet screen makes (`MobileFleetService.inventorySource`).
    private func loadMobileInventoryRows() -> [MobileDeviceInventoryItem] {
        let newestPerKind = [
            ["mobile-devices-list", "mobile_devices_list"],
            ["mobile-device-inventory-details", "mobile_device_inventory_details"],
        ].compactMap { FileManager.newestSnapshot(among: snapshotCandidates(names: $0)) }
        guard let source = MobileFleetService.inventorySource(among: newestPerKind) else {
            return []
        }
        if let data = try? Data(contentsOf: source.url) {
            SnapshotManifest.verify(snapshot: source.url, data: data)
        }
        return source.devices
    }

    /// Normalize mobile device records from the inventory rows, joined to the devices-list
    /// row with the same id, or from the devices-list alone. Fields are read through
    /// `MobileFleetService`, so the workbook and the Mobile Fleet screen agree. A blank
    /// string means the snapshot does not report the field.
    private func normalizeMobileInventory() -> [[String: Any]] {
        let rich = loadMobileInventoryRows()
        let light = loadLatestTyped(
            names: ["mobile-devices-list", "mobile_devices_list"],
            as: [MobileDeviceListRow].self) ?? []
        guard !rich.isEmpty else {
            return light.map { row in
                let stub = MobileDeviceInventoryItem(
                    mobileDeviceId: row.id, deviceType: row.deviceType ?? row.type)
                return mobileInventoryRow(stub, listRow: row)
            }
        }
        let listByID = MobileFleetService.Snapshot(
            isDetected: true, lightDevices: light, richDevices: rich,
            profiles: [], sourceFile: nil, snapshotDate: nil
        ).lightDevicesByID
        return rich.map { device in
            mobileInventoryRow(device, listRow: device.mobileDeviceId.flatMap { listByID[$0] })
        }
    }

    private func mobileInventoryRow(
        _ device: MobileDeviceInventoryItem, listRow: MobileDeviceListRow?
    ) -> [String: Any] {
        let general = device.general
        let user = device.userAndLocation
        let lastInventory = general?.lastInventoryUpdateDate ?? ""
        let factor = MobileFleetService.formFactor(of: device, listRow: listRow)
        return [
            "Jamf Pro ID": MobileFleetService.firstNonBlank(device.mobileDeviceId, listRow?.id)
                ?? "",
            "Device Name": MobileFleetService.firstNonBlank(general?.displayName, listRow?.name)
                ?? "",
            "Serial Number": MobileFleetService.serialNumber(of: device, listRow: listRow) ?? "",
            "Device Family": MobileFleetService.typeLabel(
                for: factor, deviceType: device.deviceType),
            "Managed": yesNoUnknown(general?.managed),
            "Supervised": yesNoUnknown(general?.supervised),
            "Shared iPad": yesNoUnknown(general?.sharedIpad),
            "Model": MobileFleetService.model(of: device, listRow: listRow) ?? "",
            "OS Version": general?.osVersion ?? "",
            "Username": MobileFleetService.firstNonBlank(user?.username, listRow?.username) ?? "",
            "Email": user?.emailAddress ?? "",
            "Department": user?.department ?? "",
            "Building": user?.building ?? "",
            "Last Inventory Update": lastInventory,
            "Days Since Inventory": daysSinceDate(lastInventory) as Any,
            "Activation Lock": yesNoUnknown(MobileFleetService.activationLockEnabled(of: device)),
            "Passcode Compliant": yesNoUnknown(MobileFleetService.passcodeCompliant(of: device)),
            "Data Protection": yesNoUnknown(MobileFleetService.dataProtected(of: device)),
            "Jailbreak Status": MobileFleetService.jailbreakStatus(of: device) ?? "",
            "Ownership": general?.deviceOwnershipType ?? "",
        ]
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

    /// The counts are nil when no row answers the question: unmeasured, not zero.
    private struct MobileInventorySummary {
        var total = 0, managementUnknown = 0, assigned = 0
        var managed, unmanaged, supervised, sharedIPad, activationLock, passcodeCompliant: Int?
        var stale: Int?
        var families: [String: Int] = [:], osVersions: [String: Int] = [:]
        var models: [String: Int] = [:]
    }

    /// A count cell: the number, or "Unknown" when nothing in the snapshot measured it.
    private func countCell(_ count: Int?) -> Any {
        if let count { return count }
        return "Unknown"
    }

    private func summarizeMobileInventory(_ rows: [[String: Any]], staleDays: Int) -> MobileInventorySummary {
        var s = MobileInventorySummary(total: rows.count)
        func cell(_ row: [String: Any], _ column: String) -> String {
            row[column] as? String ?? ""
        }
        func count(_ column: String, _ value: String) -> Int? {
            let answered = rows.filter { !cell($0, column).isEmpty }
            guard !answered.isEmpty else { return nil }
            return answered.filter { cell($0, column) == value }.count
        }
        s.managed = count("Managed", "Yes")
        s.unmanaged = count("Managed", "No")
        s.managementUnknown = rows.filter { cell($0, "Managed").isEmpty }.count
        s.supervised = count("Supervised", "Yes")
        s.sharedIPad = count("Shared iPad", "Yes")
        s.activationLock = count("Activation Lock", "Yes")
        s.passcodeCompliant = count("Passcode Compliant", "Yes")
        let ages = rows.compactMap { $0["Days Since Inventory"] as? Int }
        if !ages.isEmpty { s.stale = ages.filter { $0 > staleDays }.count }
        for row in rows {
            if !cell(row, "Username").isEmpty { s.assigned += 1 }
            s.families[cell(row, "Device Family"), default: 0] += 1
            let os = cell(row, "OS Version")
            if !os.isEmpty { s.osVersions[os, default: 0] += 1 }
            let model = cell(row, "Model")
            if !model.isEmpty { s.models[model, default: 0] += 1 }
        }
        return s
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
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 28)
        ws.setColumnWidth(2, 5, 14)
        let hdrs = ["Benchmark", "Device", "Device ID", "Rules Passed", "Rules Failed",
                    "Compliance %"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let compliance = item["compliance"] as? String ?? ""
            let fmt: CellFormat = compliance.isEmpty ? .yellow : .cell
            ws.write(item["benchmark"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["device"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(asInt(item["rulesPassed"]), row: row, col: 3, format: .cell)
            ws.write(asInt(item["rulesFailed"]), row: row, col: 4, format: .cell)
            ws.write(compliance, row: row, col: 5, format: fmt)
            row += 1
        }
    }

    // MARK: - Compliance Rules
    // Source: `jamf-cli pro report compliance-rules <title> --output json`, one run per benchmark.

    func writeComplianceRules() throws {
        let raw = try loadLatestJSON(names: ["compliance-rules"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Compliance Rules")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Compliance Rules"),
                                      subtitle: "Generated: \(ts)", ncols: 7)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 40)
        ws.setColumnWidth(2, 6, 12)
        let hdrs = ["Benchmark", "Rule", "Passed", "Failed", "Unknown", "Devices", "Pass Rate"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let pctStr = item["passRate"] as? String ?? ""
            ws.write(item["benchmark"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["rule"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["passed"]), row: row, col: 2, format: .cell)
            ws.write(asInt(item["failed"]), row: row, col: 3, format: .cell)
            ws.write(asInt(item["unknown"]), row: row, col: 4, format: .cell)
            ws.write(asInt(item["devices"]), row: row, col: 5, format: .cell)
            ws.write(pctStr, row: row, col: 6, format: colorForPctString(pctStr))
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

    // MARK: - DDM Device Status
    // Source: `ddm-device-status` snapshot (ReportEngine+DeviceScan, jamf-cli
    // `pro ddm-status status-items` per DDM-enabled Mac). One row per device.

    func writeDDMDeviceStatus() throws {
        let raw = try loadLatestJSON(names: ["ddm-device-status"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("DDM Device Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("DDM Device Status"),
                                      subtitle: "Generated: \(ts)", ncols: 10)
        ws.setColumnWidth(0, 0, 10)
        ws.setColumnWidth(1, 1, 30)
        ws.setColumnWidth(2, 5, 14)
        ws.setColumnWidth(6, 9, 26)
        let hdrs = ["Device ID", "Name", "OS", "Reported", "Declarations", "Failing",
                    "Pending Version", "Install State", "Failure Reason", "Report Date"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let decls = (item["declarations"] as? [[String: Any]]) ?? []
            let failing = decls.filter {
                ($0["active"] as? Bool) == false || ($0["valid"] as? Bool) == false
            }.count
            let reported = (item["ddmReported"] as? Bool) ?? false
            let su = (item["softwareUpdate"] as? [String: Any]) ?? [:]
            let failure = su["failureReason"] as? String ?? ""
            let fmt: CellFormat = (failing > 0 || !failure.isEmpty) ? .yellow : .cell
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["osVersion"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(reported ? "Yes" : "Not reported", row: row, col: 3,
                    format: reported ? .cell : .yellow)
            ws.write(decls.count, row: row, col: 4, format: .cell)
            ws.write(failing, row: row, col: 5, format: fmt)
            ws.write(su["pendingOSVersion"] as? String ?? "", row: row, col: 6, format: .cell)
            ws.write(su["installState"] as? String ?? "", row: row, col: 7, format: .cell)
            ws.write(failure, row: row, col: 8, format: fmt)
            ws.write(item["reportDate"] as? String ?? "", row: row, col: 9, format: .cell)
            row += 1
        }
    }

    // MARK: - MDM Command Health
    // Source: `mdm-command-health` snapshot (ReportEngine+DeviceScan, jamf-cli
    // `pro classic-computer-history get <id> --subset commands` per Mac).

    func writeMDMCommandHealth() throws {
        let raw = try loadLatestJSON(names: ["mdm-command-health"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("MDM Command Health")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("MDM Command Health"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 10)
        ws.setColumnWidth(1, 1, 30)
        ws.setColumnWidth(2, 4, 14)
        ws.setColumnWidth(5, 5, 60)
        let hdrs = ["Device ID", "Name", "Failed", "Pending",
                    "Oldest Pending (days)", "Failed Commands"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        // Worst first: most failures, then oldest pending.
        let sorted = items.sorted {
            let a = (asInt($0["failedCount"]) ?? 0, asInt($0["oldestPendingDays"]) ?? 0)
            let b = (asInt($1["failedCount"]) ?? 0, asInt($1["oldestPendingDays"]) ?? 0)
            return a > b
        }
        for item in sorted {
            let failed = asInt(item["failedCount"]) ?? 0
            let oldest = asInt(item["oldestPendingDays"])
            let stale = (oldest ?? 0) >= DeviceScanBuilders.pendingAgeThresholdDays
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(failed, row: row, col: 2, format: failed > 0 ? .yellow : .cell)
            ws.write(asInt(item["pendingCount"]) ?? 0, row: row, col: 3, format: .cell)
            if let oldest { ws.write(oldest, row: row, col: 4, format: stale ? .yellow : .cell) }
            else { ws.write("", row: row, col: 4, format: .cell) }
            let names = (item["failedCommands"] as? [String]) ?? []
            ws.write(names.joined(separator: "; "), row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Overview
    // Source: `jamf-cli protect overview --output json` (gated on protect.enabled).
    // Rows carry section, resource and value, plus `status` when jamf-cli highlights a line.

    func writeProtectOverview() throws {
        let raw = try loadLatestJSON(names: ["protect-overview"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Protect Overview")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Overview"),
                                      subtitle: "Generated: \(ts)", ncols: 3)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 32)
        ws.setColumnWidth(2, 2, 24)
        for (col, h) in ["Section", "Resource", "Value"].enumerated() {
            ws.write(h, row: row, col: col, format: .header)
        }
        row += 1
        for item in items {
            let status = (item["status"] as? String ?? "").lowercased()
            let fmt: CellFormat = status == "red" ? .red : status == "yellow" ? .yellow : .cell
            ws.write(item["section"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["resource"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["value"] as? String ?? "", row: row, col: 2, format: fmt)
            row += 1
        }
    }

    // MARK: - Protect Alerts
    // Source: `jamf-cli protect alerts list --output json` (gated on protect.enabled).
    // `computer` is the host name and `analytics` the fired analytics' names, comma-joined.

    func writeProtectAlerts() throws {
        let raw = try loadLatestJSON(names: ["protect-alerts"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Protect Alerts")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Alerts"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 36)
        ws.setColumnWidth(2, 3, 16)
        ws.setColumnWidth(4, 5, 22)
        let hdrs = ["Host", "Analytics", "Severity", "Status", "Event Type", "Created"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let severity = (item["severity"] as? String ?? "").lowercased()
            let fmt: CellFormat = severity == "high" || severity == "critical" ? .red
                : severity == "medium" ? .yellow : .cell
            ws.write(item["computer"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["analytics"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["severity"] as? String ?? "", row: row, col: 2, format: fmt)
            ws.write(item["status"] as? String ?? "", row: row, col: 3, format: .cell)
            ws.write(item["eventType"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(item["created"] as? String ?? "", row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Computers
    // Source: `jamf-cli protect computers list --output json` (gated on protect.enabled).
    // `hostname` is lower case, `plan` is the plan's name, `fullDiskAccess` is Protect's status.

    func writeProtectComputers() throws {
        let raw = try loadLatestJSON(names: ["protect-computers"])
        let items = (raw as? [[String: Any]]) ?? []
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
            let osMajor = asInt(item["osMajor"])
            let osMinor = asInt(item["osMinor"])
            let osPatch = asInt(item["osPatch"])
            let osStr: String
            if let maj = osMajor, let min = osMinor, let pat = osPatch {
                osStr = "\(maj).\(min).\(pat)"
            } else {
                osStr = item["osString"] as? String ?? ""
            }
            ws.write(item["hostname"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["serial"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["plan"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(osStr, row: row, col: 3, format: .cell)
            ws.write(item["connectionStatus"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(item["lastConnection"] as? String ?? "", row: row, col: 5, format: .cell)
            let webFmt: CellFormat =
                (item["webProtectionActive"] as? Bool == false) ? .yellow : .cell
            let access = item["fullDiskAccess"] as? String
            let diskFmt: CellFormat =
                ProtectComputerRow.fullDiskAccessGranted(access) == false ? .yellow : .cell
            ws.write(asBool(item["webProtectionActive"]).map { $0 ? "Yes" : "No" } ?? "",
                     row: row, col: 6, format: webFmt)
            ws.write(access ?? "", row: row, col: 7, format: diskFmt)
            row += 1
        }
    }

    // MARK: - Protect Insights
    // Source: `jamf-cli protect insights list --output json` (gated on protect.enabled).
    // Rows carry no description; `cisIDs` holds the CIS benchmark IDs, comma-joined.

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
        let hdrs = ["Label", "Section", "CIS IDs", "Pass", "Fail", "Enabled"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let fail = asInt(item["totalFail"]) ?? 0
            let fmt: CellFormat = fail > 0 ? .yellow : .cell
            ws.write(item["label"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["section"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["cisIDs"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(asInt(item["totalPass"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(fail, row: row, col: 4, format: fmt)
            ws.write(asBool(item["enabled"]).map { $0 ? "Yes" : "No" } ?? "",
                     row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Protect Plans
    // Source: `jamf-cli protect plans list --output json` (gated on protect data present).
    // Reference columns are names; jamf-cli omits a reference that is not assigned.

    func writeProtectPlans() throws {
        let raw = try loadLatestJSON(names: ["protect-plans"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["protect-plans"])
        }

        let ws = workbook.addSheet("Protect Plans")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Protect Plans"),
                                      subtitle: "Generated: \(ts)", ncols: 7)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 2, 12)
        ws.setColumnWidth(3, 5, 28)
        ws.setColumnWidth(6, 6, 48)

        let hdrs = ["Plan Name", "Log Level", "Auto Update", "Action Configuration",
                    "Telemetry", "USB Control Set", "Unified Logging Filter Sets"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1

        let sorted = items.sorted {
            let a = ($0["name"] as? String ?? "").lowercased()
            let b = ($1["name"] as? String ?? "").lowercased()
            return a < b
        }
        for item in sorted {
            let logFilterSets = item["unifiedLoggingFilterSets"] as? String ?? ""
            ws.write(item["name"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["logLevel"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(boolToYesNo(item["autoUpdate"]), row: row, col: 2, format: .cell)
            ws.write(item["actionConfig"] as? String ?? "", row: row, col: 3, format: .cell)
            ws.write(item["telemetry"] as? String ?? "", row: row, col: 4, format: .cell)
            ws.write(item["usbControlSet"] as? String ?? "", row: row, col: 5, format: .cell)
            ws.write(logFilterSets, row: row, col: 6, format: .cell)
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
            return [
                "Device": item["computer"] as? String ?? "",
                "Type": item["eventType"] as? String ?? "",
                "Severity": item["severity"] as? String ?? "",
                "Date": item["created"] as? String ?? "",
                "Status": item["status"] as? String ?? "",
                "Analytics": item["analytics"] as? String ?? "",
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

        let hdrs = ["Device", "Type", "Severity", "Date", "Status", "Analytics"]
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
            ws.write(r["Analytics"] ?? "", row: row, col: 5, format: .cell)
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

        let dcList = try loadDeviceComplianceRows()
        guard !dcList.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["device-compliance"])
        }

        let totalEnrolled = dcList.count
        let activeCount = dcList.filter { !isStaleDevice($0) }.count
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
            // Totals are rescaled through Double below, which traps on a value near Int.max.
            guard PatchStatusService.hasUsableCounts(item) else { return nil }
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
        let fleetPct = PatchStatusService.fleetCompliancePct(patchItems)
        let excellent = patchRows.filter { $0.adjPct >= 0.95 }.count
        let good = patchRows.filter { $0.adjPct >= 0.80 && $0.adjPct < 0.95 }.count
        let warning = patchRows.filter { $0.adjPct >= 0.50 && $0.adjPct < 0.80 }.count
        let critical = patchRows.filter { $0.adjPct < 0.50 }.count
        let top10 = patchRows.sorted { $0.adjPct < $1.adjPct }.prefix(10)

        let ws = workbook.addSheet("Patch Summary Dashboard")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t("Patch Summary Dashboard"),
            subtitle: "Source: patch-status + device-compliance | "
                + "\(ruleSubtitle(config.staleRule, window: "Active window")) | Generated: \(ts)",
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
        ws.write("Fleet Compliance (devices on latest)", row: row, col: 0, format: .cell)
        ws.write(fleetPct.map { String(format: "%.1f%%", $0) } ?? "\u{2014}",
                 row: row, col: 1, format: .cell)
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
            let hardwareEncrypted: Bool?
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
            let bootstrapStr = bootstrapEscrowText(security)

            let hasAny = !fileVaultStr.isEmpty || !sipStr.isEmpty || !firewallStr.isEmpty
                || !gatekeeperStr.isEmpty || !bootstrapStr.isEmpty
            guard hasAny else { return nil }
            return DeviceSecurityRow(name: name, serial: serial, fileVault: fileVaultStr,
                                     sip: sipStr, firewall: firewallStr, gatekeeper: gatekeeperStr,
                                     bootstrapToken: bootstrapStr,
                                     hardwareEncrypted: HardwareEncryption.isHardwareEncrypted(
                                        computer: item))
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

        let policy = config.resolvedSecurityPolicy
        let sorted = rows.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for r in sorted {
            ws.write(r.name, row: row, col: 0, format: .cell)
            ws.write(r.serial, row: row, col: 1, format: .cell)
            ws.write(policy.fileVaultLabel(r.fileVault, hardwareEncrypted: r.hardwareEncrypted),
                     row: row, col: 2, format: securityVerdictFormat(
                        .fileVault, r.fileVault, hardwareEncrypted: r.hardwareEncrypted))
            ws.write(r.sip, row: row, col: 3,
                     format: securityVerdictFormat(.sip, r.sip, hardwareEncrypted: nil))
            ws.write(r.firewall, row: row, col: 4,
                     format: securityVerdictFormat(.firewall, r.firewall, hardwareEncrypted: nil))
            ws.write(r.gatekeeper, row: row, col: 5,
                     format: securityVerdictFormat(
                        .gatekeeper, r.gatekeeper, hardwareEncrypted: nil))
            let escrowed = SecurityControlPolicy.reading(r.bootstrapToken)
            ws.write(r.bootstrapToken, row: row, col: 6,
                     format: escrowed.map { $0 ? CellFormat.green : .red } ?? .cell)
            row += 1
        }
    }

    /// Bootstrap token escrow as the sheet shows it. Jamf Pro reports it as
    /// `bootstrapTokenEscrowedStatus` (ESCROWED, NOT_ESCROWED, NOT_SUPPORTED); a snapshot with
    /// the older Bool key still reads. `bootstrapTokenAllowed` says whether escrow is
    /// permitted, not whether the token is escrowed, so it never stands in.
    private func bootstrapEscrowText(_ security: [String: Any]?) -> String {
        let status = (security?["bootstrapTokenEscrowedStatus"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !status.isEmpty { return status }
        guard let escrowed = asBool(security?["bootstrapTokenEscrowed"]) else { return "" }
        return escrowed ? "ESCROWED" : "NOT ESCROWED"
    }

    /// Green when the control passes under the workspace's policy, red when it fails, amber
    /// for a warning; neutral when the value says nothing or the policy does not count it.
    private func securityVerdictFormat(
        _ control: SecurityControl, _ value: String, hardwareEncrypted: Bool?
    ) -> CellFormat {
        let verdict = config.resolvedSecurityPolicy.verdict(
            for: control, value: value, hardwareEncrypted: hardwareEncrypted)
        switch verdict {
        case .pass: return .green
        case .fail: return .red
        case .warning: return .yellow
        case .ignored, .unknown: return .cell
        }
    }

    // MARK: - Mobile Supervision Status
    // Source: mobile-devices-list (or a newer legacy mobile-device-inventory-details) snapshot.
    // Per-family aggregate of supervised/unsupervised counts.

    func writeMobileSupervisionStatus() throws {
        let mobileRows = normalizeMobileInventory()
        guard !mobileRows.isEmpty else {
            throw CoreDashboardError.noCachedData(names: ["mobile-devices-list"])
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
                counts[OSVersionName.normalized(ver), default: 0] += v.count
            }
        }
        return counts
    }

    /// Returns {osVersion: count} for iOS/iPadOS from the cached mobile inventory.
    private func mobileOSCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in loadMobileInventoryRows() {
            let ver = (item.general?.osVersion ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ver.isEmpty else { continue }
            counts[ver, default: 0] += 1
        }
        return counts
    }

    // MARK: - Protect Plans helper

    /// Convert a Bool/Int/String value to "Yes" / "No" / "".
    private func boolToYesNo(_ value: Any?) -> String {
        guard let b = asBool(value) else { return "" }
        return b ? "Yes" : "No"
    }

    // MARK: - Executive Summary sheet

    /// Aggregated fleet KPIs collected from cached snapshots. Every field is optional;
    /// nil means the source snapshot was absent — rendered as "—" in the sheet.
    struct ExecutiveSummaryMetrics: Sendable {
        var totalDevices: Int?
        var managedCount: Int?
        var securityScore: Double?
        var securityGrade: SecurityScore.Grade?
        /// The scored factors, listed under the score.
        var securityScoreParts: [SecurityScore.Part] = []
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
        /// FileVault-off Macs the hardware rule counts apart (warning or not counted).
        var fileVaultOffHardwareEncrypted: Int?
        /// Values P0 and P1 leave out because Jamf did not report them.
        var p0NotReported: Int?
        var p1NotReported: Int?
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

    /// Workbook-free access to the SAME aggregates the Executive Summary sheet
    /// renders. Used by `ReportNarrative` (F3) so the AI narrative is grounded
    /// in exactly the sheet's numbers — never a second aggregation path.
    static func executiveMetrics(config: ReportConfig, dataDir: URL) -> ExecutiveSummaryMetrics {
        CoreDashboard(config: config, dataDir: dataDir, workbook: Workbook())
            .buildExecutiveMetrics()
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
            if let fleet = securityFleet(items: items) {
                applySecurityScoreAndActions(to: &m, fleet: fleet)
            }
            break
        }
    }

    /// The security snapshot's counts under the workspace's policy: what summary.json and the
    /// Security Posture screen take P0, P1 and the score from. Nil without a summary section.
    private func securityFleet(items: [SecurityReportItem]) -> SecurityFleetCounts? {
        let policy = config.resolvedSecurityPolicy
        let hardware = hardwareIndex.value {
            HardwareEncryption.index(dataDir: dataDir, for: policy)
        }
        return SecurityFleetCounts.build(items: items, hardware: hardware, policy: policy)
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

    /// One row per scored factor under the Security Score: its share of Macs and its points.
    func scoreFactorRows(_ m: ExecutiveSummaryMetrics) -> [(String, String)] {
        let score = SecurityScore(
            value: m.securityScore ?? 0, grade: m.securityGrade ?? .f,
            parts: m.securityScoreParts, missing: [])
        let rule = config.staleRule
        return m.securityScoreParts.map { part in
            ("Score — \(part.factor.label(staleDays: rule.days, staleBasis: rule.basis))",
             String(format: "%.1f%% · %.1f pts", part.share, score.points(of: part)))
        }
    }

    /// Compute the weighted security score, grade, and P0/P1 action item counts.
    private func applySecurityScoreAndActions(
        to m: inout ExecutiveSummaryMetrics,
        fleet: SecurityFleetCounts
    ) {
        // The same factors and inputs as summary.json's securityScore and the Security
        // Posture screen.
        let factors = config.resolvedScoreFactors
        let score = SecurityScoreCalculator.score(
            factors: factors,
            measures: SecurityScoreInputs.measures(
                for: factors, fleet: fleet,
                sources: SecurityScoreInputs.load(
                    dataDir: dataDir, factors: factors, staleRule: config.staleRule),
                config: config))
        m.securityScoreParts = score.parts
        if !score.parts.isEmpty {
            m.securityScore = score.value
            m.securityGrade = score.grade
        }
        m.actionItemsP0 = fleet.p0
        m.actionItemsP1 = fleet.p1
        m.p0NotReported = fleet.p0NotReported
        m.p1NotReported = fleet.p1NotReported
        m.fileVaultOffHardwareEncrypted = fleet.fileVaultOffHardwareEncrypted
    }

    /// One "<control> not reported" row per control with Macs that did not report it, for the
    /// summary block of the Security Posture sheet.
    private func notReportedFields(_ fleet: SecurityFleetCounts?) -> [(String, String)] {
        SecurityControl.allCases.compactMap { control in
            guard let n = fleet?.controls[control]?.notReported, n > 0 else { return nil }
            return ("\(CompliancePostureService.label(control)) Not Reported", "\(n)")
        }
    }

    /// Populate patch compliance % from the cached `patch-status` snapshot.
    private func applyPatchMetric(to m: inout ExecutiveSummaryMetrics) {
        guard let rows = loadLatestTyped(names: ["patch-status", "patch_status"],
                                          as: [PatchStatusRow].self) else { return }
        m.patchFleetCompliancePct = PatchStatusService.fleetCompliancePct(rows)
    }

    /// Populate managed count + stale tier buckets from the cached `device-compliance` snapshot.
    /// A Mac's tier follows its stale age under the stale rule: the oldest of the dates
    /// `stale_basis` lists, which is the row's check-in day count (`days_since_contact`, or
    /// legacy `days_since_checkin`) unless the basis counts more.
    private func applyStaleAndManaged(to m: inout ExecutiveSummaryMetrics) {
        guard let items = loadLatestTyped(
            names: ["device-compliance", "device_compliance"], as: [DeviceComplianceRow].self),
              !items.isEmpty else { return }
        m.managedCount = items.filter { $0.managed == true }.count
        let rule = config.staleRule
        let computers = computerDates(for: rule)
        var tierCounts: [StaleDeviceService.Tier: Int] = [:]
        for tier in StaleDeviceService.Tier.allCases { tierCounts[tier] = 0 }
        for item in items {
            let tier = StaleDeviceService.Tier.tier(
                forAge: item.staleAge(rule, computers: computers), staleDays: rule.days)
            tierCounts[tier, default: 0] += 1
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
        subtitle: String = "Fleet KPIs · KPI source: security + patch-status + device-compliance",
        aiNarrative: String? = nil
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

        var metricRows: [(String, String)] = [
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
        metricRows.insert(contentsOf: scoreFactorRows(m), at: 1)
        if let n = m.fileVaultOffHardwareEncrypted, n > 0,
           let at = metricRows.firstIndex(where: { $0.0 == "FileVault Coverage" }) {
            metricRows.insert((SecurityFleetCounts.hardwareEncryptedRowLabel, "\(n)"), at: at + 1)
        }
        // A Mac whose value Jamf did not report is in neither P0 nor P1; say how many.
        for (after, label, count) in [
            ("P1 Action Items (Gatekeeper gaps)", "P1 Not Reported (Gatekeeper values)",
             m.p1NotReported),
            ("P0 Action Items (FV/SIP/FW gaps)", "P0 Not Reported (FV/SIP/FW values)",
             m.p0NotReported),
        ] {
            if let n = count, n > 0, let at = metricRows.firstIndex(where: { $0.0 == after }) {
                metricRows.insert((label, "\(n)"), at: at + 1)
            }
        }

        ws.write("Metric", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        row += 1

        for (label, value) in metricRows {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(value, row: row, col: 1, format: .cell)
            row += 1
        }

        // F3: AI narrative block — present only on GUI-generated reports.
        // Formula-injection neutralization is automatic on every write.
        if let narrative = aiNarrative, !narrative.isEmpty {
            row += 1
            ws.write("AI-Generated Summary", row: row, col: 0, format: .header)
            row += 1
            ws.mergeRange(firstRow: row, firstCol: 0, lastRow: row, lastCol: 1,
                          value: narrative, format: .cell)
            row += 1
            ws.write("AI-generated summary — verify against the metrics above.",
                     row: row, col: 0, format: .cell)
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
        renderExecutiveSummaryRows(into: ws, metrics: metrics, subtitle: subtitle,
                                   aiNarrative: aiNarrative)
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
            "Profile Status": "Configuration profiles that reported install errors, with "
                + "error and device counts.",
            "Mobile Config Profiles": "Mobile configuration profiles with category "
                + "breakdown.",
            "App Status": "Managed apps that reported install errors, with error and "
                + "device counts.",
            "Software Installs": "Top software titles and install counts.",
            "Package Lifecycle": "Packages with upload age and size when Jamf reports "
                + "them; highlights stale packages.",
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
            "DDM Device Status": "Per-device DDM declaration and software-update status "
                + "(works on-prem; from the per-device scan).",
            "MDM Command Health": "Per-device failed and pending MDM commands from the "
                + "Classic command history.",
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
        let fleet = loadLatestTyped(names: ["security"], as: [SecurityReportItem].self)
            .flatMap { securityFleet(items: $0) }

        // Device compliance snapshot
        let deviceCompItems = (try? loadDeviceComplianceRows()) ?? []
        let staleCount = deviceCompItems.filter(isStaleDevice).count
        let managedCount = deviceCompItems.filter { $0.managed == true }.count
        let deviceTotal = deviceCompItems.count
        let compliancePct: Double = deviceTotal > 0
            ? Double(managedCount) / Double(deviceTotal) * 100 : 0

        // Patch compliance snapshot
        let patchPct = loadLatestTyped(
            names: ["patch-status", "patch_status"], as: [PatchStatusRow].self
        ).flatMap(PatchStatusService.fleetCompliancePct)

        // Metric rows: (label, rawValue, pctValue for RAG, security control the policy grades)
        let metrics: [(label: String, value: String, pct: Double?, control: SecurityControl?)] = [
            ("Device Compliance (managed %)",
             deviceTotal > 0 ? String(format: "%.0f%%", compliancePct) : "\u{2014}",
             deviceTotal > 0 ? compliancePct : nil, nil),
            ("FileVault Encrypted",
             percentLabel(asInt(secSummary["filevault_encrypted"]), total: totalDevices),
             nil, .fileVault),
            ("SIP Enabled",
             percentLabel(asInt(secSummary["sip_enabled"]), total: totalDevices),
             nil, .sip),
            ("Firewall Enabled",
             percentLabel(asInt(secSummary["firewall_enabled"]), total: totalDevices),
             nil, .firewall),
            ("Gatekeeper Enabled",
             percentLabel(asInt(secSummary["gatekeeper_enabled"]), total: totalDevices),
             nil, .gatekeeper),
            ("Patch Compliance (devices on latest)",
             patchPct.map { String(format: "%.0f%%", $0) } ?? "\u{2014}",
             patchPct, nil),
            ("Stale Devices (>\(config.thresholds?.resolvedStaleDays ?? 30) days)",
             "\(staleCount)",
             nil, nil),
        ]

        ws.write("Metric", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        for metric in metrics {
            let (statusLabel, statusFmt) = metric.control.map {
                securityRagStatus($0, fleet: fleet)
            } ?? ragStatus(pct: metric.pct)
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
        // Under a policy the security rows are graded differently from the bands above.
        if !config.resolvedSecurityPolicy.gradesLikeTheDefault {
            ws.write("Security rows follow this workspace's security policy: they are graded on "
                     + "the Macs not failing, AMBER also covers warnings, and Not counted means "
                     + "the control is set to ignore or no Mac is left to grade.",
                     row: row, col: 0, format: .subtitle)
            row += 1
        }
        if let note = notReportedNote(fleet) {
            ws.write(note, row: row, col: 0, format: .subtitle)
            row += 1
        }
        ws.write("Framework: \(framework)", row: row, col: 0, format: .subtitle)
        row += 2
        writePostureDeviceTable(ws: ws, row: row, items: deviceCompItems)
    }

    /// Write the top-20 non-compliant / stale device table for Compliance Posture.
    private func writePostureDeviceTable(
        ws: Worksheet,
        row startRow: Int,
        items: [DeviceComplianceRow]
    ) {
        // Longest silence first; a Mac with no day count sorts last, then by name so the
        // order does not change from run to run.
        let worst = items
            .filter { isStaleDevice($0) || $0.managed == false }
            .sorted {
                let dA = $0.resolvedDaysSinceContact ?? -1
                let dB = $1.resolvedDaysSinceContact ?? -1
                if dA != dB { return dA > dB }
                return ($0.name ?? "", $0.serial ?? "") < ($1.name ?? "", $1.serial ?? "")
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
            let isStale = isStaleDevice(item)
            let fmt: CellFormat = isStale ? .yellow : .cell
            ws.write(item.name ?? "", row: row, col: 0, format: fmt)
            ws.write(item.serial ?? "", row: row, col: 1, format: fmt)
            if let days = item.resolvedDaysSinceContact {
                ws.write(days, row: row, col: 2, format: fmt)
            } else {
                ws.write("\u{2014}", row: row, col: 2, format: fmt)
            }
            ws.write(isStale ? "Yes" : "No", row: row, col: 3, format: fmt)
            ws.write(item.managed.map { $0 ? "Yes" : "No" } ?? "", row: row, col: 4, format: fmt)
            row += 1
        }
    }

    /// "Not reported: SIP 100, Gatekeeper 3" for the controls some Macs did not report, with
    /// what that means for the rows above; nil when every Mac reported every control.
    private func notReportedNote(_ fleet: SecurityFleetCounts?) -> String? {
        let parts = SecurityControl.allCases.compactMap { control -> String? in
            guard let n = fleet?.controls[control]?.notReported, n > 0 else { return nil }
            return "\(CompliancePostureService.label(control)) \(n)"
        }
        guard !parts.isEmpty else { return nil }
        return "Not reported: " + parts.joined(separator: ", ")
            + ". Macs whose value Jamf did not report are not counted as failing and are left "
            + "out of the shares above."
    }

    /// A security row's status under the workspace's policy: not counted at `ignore` or with
    /// no Mac left to grade, else
    /// graded on the share of Macs not failing the control, amber instead of green when some
    /// Macs only warn.
    private func securityRagStatus(
        _ control: SecurityControl, fleet: SecurityFleetCounts?
    ) -> (String, CellFormat) {
        if config.resolvedSecurityPolicy.level(for: control) == .ignore {
            return ("Not counted", .cell)
        }
        // Every Mac the hardware rule took out of FileVault's count, or that did not report the
        // control: none is left to grade. With no Mac in the report there is nothing to say.
        if let fleet, fleet.totalDevices > 0, fleet.controls[control] != nil,
           fleet.nonFailingPct(control) == nil {
            return ("Not counted", .cell)
        }
        let status = ragStatus(pct: fleet?.nonFailingPct(control))
        guard status.0 == "GREEN", (fleet?.controls[control]?.warning ?? 0) > 0 else {
            return status
        }
        return ("AMBER", .yellow)
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
        // One ordering rule for every reader: filename stamp first, manifest and
        // sync-conflict copies excluded.
        guard let newest = FileManager.newestSnapshot(among: snapshotCandidates(names: names))
        else {
            throw CoreDashboardError.noCachedData(names: names)
        }
        let data = try Data(contentsOf: newest)
        SnapshotManifest.verify(snapshot: newest, data: data)
        return data
    }

    /// Every JSON file under `dataDir` that could be the snapshot of one of `names`: the
    /// kind's own directory, and flat `<name>_*.json` files beside it.
    private func snapshotCandidates(names: [String]) -> [URL] {
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
                candidates.append(contentsOf: files.filter { $0.pathExtension == "json" })
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
        return candidates
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
                candidates.append(contentsOf: files.filter { $0.pathExtension == "json" })
            }
        }
        // Same rule as the picker above: the filename stamp is when the snapshot
        // was collected; mtime is when the sync provider last touched the file.
        // A "Data as of" caption reading the re-stamp would contradict the sheet
        // rendered right beside it.
        return candidates
            .filter(FileManager.isSelectableSnapshot)
            .compactMap(FileManager.snapshotDate(of:))
            .max()
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
        case let d as Double: return Int(exactly: d.rounded())
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

        // decodeSnapshot, like every other ea-results reader: an envelope or a
        // truncated snapshot still yields its rows instead of an empty sheet.
        guard let eaData = try? loadLatestJSONData(names: ["ea-results"]),
              let eaRows = EAResultRow.decodeSnapshot(eaData).rows,
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

// MARK: - OnceCache

/// The hardware index and the computers' dates read and parse the `computers` snapshot, so a
/// dashboard builds each once however many sheets grade by it.
private final class OnceCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var isStored = false

    func value(_ make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if isStored, let stored { return stored }
        let made = make()
        stored = made
        isStored = true
        return made
    }
}
