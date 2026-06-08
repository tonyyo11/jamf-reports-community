import Foundation
import OSLog

private let engineLog = Logger(subsystem: "com.github.tonyyo11.jamf-reports-community",
                               category: "engine")

// MARK: - CSV row type alias

typealias CSVRow = [String: String]

// MARK: - CSVParser

/// Minimal RFC-4180-compliant CSV parser that handles quoted fields, escaped quotes,
/// and UTF-8-sig BOM stripping. Replaces pandas for the sheet-generation path.
enum CSVParser {

    enum ParseError: Error { case empty, encodingFailed }

    /// Parse CSV data into an array of column-name-keyed dictionaries.
    static func parse(_ data: Data) throws -> ([String], [CSVRow]) {
        // Strip UTF-8 BOM if present
        var raw = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if raw.prefix(3).elementsEqual(bom) { raw = raw.dropFirst(3) }
        guard let text = String(data: raw, encoding: .utf8) else {
            throw ParseError.encodingFailed
        }
        let rows = parseText(text)
        guard let header = rows.first, !header.isEmpty else { throw ParseError.empty }
        let columns = header
        let records: [CSVRow] = rows.dropFirst().compactMap { row -> CSVRow? in
            guard !row.isEmpty else { return nil }
            var dict = CSVRow()
            for (idx, col) in columns.enumerated() {
                dict[col] = idx < row.count ? row[idx] : ""
            }
            return dict
        }
        return (columns, records)
    }

    static func parseText(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuote = false
        var idx = text.startIndex

        while idx < text.endIndex {
            let ch = text[idx]
            let next = text.index(after: idx)

            if inQuote {
                if ch == "\"" {
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        idx = text.index(after: next)
                        continue
                    }
                    inQuote = false
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuote = true
                case ",":
                    fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
                    field = ""
                case "\r":
                    if next < text.endIndex && text[next] == "\n" {
                        idx = text.index(after: idx)
                    }
                    fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
                    rows.append(fields)
                    fields = []
                    field = ""
                case "\n":
                    fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
                    rows.append(fields)
                    fields = []
                    field = ""
                default:
                    field.append(ch)
                }
            }
            idx = next
        }
        // Last field / row
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field.trimmingCharacters(in: .init(charactersIn: " \t")))
            if fields.contains(where: { !$0.isEmpty }) {
                rows.append(fields)
            }
        }
        return rows
    }
}

// MARK: - CSVDashboard

/// Swift port of the Python `CSVDashboard` class.
/// Generates sheets from a Jamf Pro CSV export.
struct CSVDashboard: Sendable {

    let config: ReportConfig
    let columns: [String]   // CSV header row
    let rows: [CSVRow]       // data rows (continuation rows already dropped)
    let workbook: Workbook
    /// Prior snapshot for Fleet Drift sheet. Loaded at init time so the sheet plan is stable.
    let priorSnapshot: PriorCSVLoader.Result?
    /// Detected device family of the CSV. Computed from headers at init time.
    let csvFamily: CSVFamily?

    private var orgName: String { config.branding?.resolvedOrgName ?? "" }

    /// Custom EA entries whose `column` value does not appear in the CSV header.
    /// Populated from config at any time — no need to call `writeAll` first.
    var missingEAColumns: [String] {
        (config.customEas ?? [])
            .filter { !columns.contains($0.column) }
            .map { $0.name }
    }

    /// Initialize from raw CSV data.
    /// - Parameters:
    ///   - config: Decoded report config.
    ///   - csvData: Raw bytes of the current CSV export.
    ///   - workbook: Target workbook.
    ///   - currentCSVURL: URL of the current CSV (used for Fleet Drift deduplication).
    init?(config: ReportConfig, csvData: Data, workbook: Workbook, currentCSVURL: URL? = nil) {
        guard let (cols, parsedRows) = try? CSVParser.parse(csvData) else { return nil }
        self.config = config
        self.columns = cols
        self.workbook = workbook

        // Detect CSV family from headers before dropping rows (family drives identity column).
        let family = CSVFamilyDetector.detect(headers: cols)
        self.csvFamily = family

        // Drop Jamf "export-only" continuation rows (blank identity cell).
        // These are emitted for multi-value fields (Applications, Certificates, Groups…).
        // Identity column: device_name for mobile, computer_name for computers/unknown.
        let identityColName: String?
        if family == .mobile {
            identityColName = config.mobileColumns?.deviceName
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? "Display Name"
        } else {
            identityColName = config.columns?.columnName(for: .computerName)
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? "Computer Name"
        }

        if let idCol = identityColName, cols.contains(idCol) {
            let filtered = parsedRows.filter { row in
                let val = row[idCol] ?? ""
                return !val.trimmingCharacters(in: .whitespaces).isEmpty
            }
            let dropped = parsedRows.count - filtered.count
            if dropped > 0 {
                engineLog.info(
                    "[info] Dropped \(dropped) continuation row(s) from multi-value export fields."
                )
            }
            self.rows = filtered
        } else {
            self.rows = parsedRows
        }

        // Load prior snapshot for Fleet Drift if historical_csv_dir is configured.
        if let historicalDirStr = config.charts?.historicalCsvDir,
           !historicalDirStr.trimmingCharacters(in: .whitespaces).isEmpty,
           let csvURL = currentCSVURL {
            let historicalDir = URL(fileURLWithPath: historicalDirStr, isDirectory: true)
            self.priorSnapshot = PriorCSVLoader.load(historicalDir: historicalDir, currentCSVURL: csvURL)
        } else {
            self.priorSnapshot = nil
        }
    }

    // MARK: - Sheet plan

    /// Ordered list of CSV-sourced sheet names and write closures.
    ///
    /// **Order matters** — this sequence sets the Excel tab order the user sees. Do not
    /// reorder existing sheets without updating `SheetOrderTests.swift` (which pins this
    /// contract) and verifying that the new order is intentional.
    ///
    /// **Family routing:**
    /// - `.mobile` CSV → only Mobile Device Inventory + Mobile Stale Devices + custom EAs.
    /// - `.computers` (or nil/ambiguous) CSV → computer sheets; mobile sheets only when
    ///   the family is nil (undetectable) AND `config.mobileColumns?.deviceName` is set
    ///   (preserves legacy behavior for undetectable CSVs).
    ///
    /// **Other config-gated sheets:**
    /// - "Security Agents" — included only when `securityAgents` is non-empty.
    /// - "Compliance" — included only when `config.compliance?.isEnabled == true`.
    /// - "Fleet Drift" — included only when a prior snapshot was successfully loaded.
    /// - Custom EA sheets — one per entry in `config.customEas`, appended after the above.
    /// - "EA Warnings" — included only when unmapped EA columns were detected.
    ///
    /// **Adding a new sheet:** append to the end of the fixed block, or just before the
    /// custom-EA loop if it is config-optional. Update `SheetOrderTests.swift` to assert
    /// the new expected order.
    var sheetPlan: [(name: String, write: () -> Void)] {
        var plan: [(String, () -> Void)] = []

        if csvFamily == .mobile {
            // Mobile CSV: only mobile sheets.
            plan.append(("Mobile Device Inventory", writeMobileInventoryCSV))
            plan.append(("Mobile Stale Devices", writeMobileStaleCSV))
        } else {
            // Computer CSV or ambiguous: computer sheets.
            plan += [
                ("Device Inventory", writeDeviceInventory),
                ("Stale Devices", writeStaleDevices),
                ("Security Controls", writeSecurityControls),
            ]
            if securityAgents.isEmpty == false {
                plan.append(("Security Agents", writeSecurityAgents))
            }
            if config.compliance?.isEnabled == true {
                plan.append(("Compliance", writeCompliance))
            }
            // For undetectable (nil family) CSVs with mobile_columns configured,
            // include mobile sheets as well (legacy behavior).
            if csvFamily == nil, config.mobileColumns?.deviceName != nil {
                plan.append(("Mobile Device Inventory", writeMobileInventoryCSV))
                plan.append(("Mobile Stale Devices", writeMobileStaleCSV))
            }
            // Fleet Drift is only available for computer-family CSVs.
            if let prior = priorSnapshot {
                plan.append(("Fleet Drift", { self.writeFleetDrift(prior: prior) }))
            }
        }

        for ea in config.customEas ?? [] {
            let name = ea.name
            plan.append((name, { self.writeCustomEA(ea) }))
        }
        if !missingEAColumns.isEmpty {
            plan.append(("EA Warnings", writeEAWarnings))
        }
        return plan
    }

    @discardableResult
    func writeAll(selectedNames: Set<String>? = nil) -> [String] {
        let effectivePlan = (config.sheets ?? SheetsConfig()).applyTo(sheetPlan)
        var written: [String] = []
        for (name, fn) in effectivePlan {
            if let sel = selectedNames, !sel.contains(name.lowercased()) { continue }
            fn()
            written.append(name)
        }
        if let logoData = CSVDashboard.loadLogoData(from: config) {
            for name in written {
                if let ws = workbook.sheet(named: name) {
                    ws.insertImage(row: 0, col: 0, data: logoData,
                                   filename: "logo.png", xScale: 1.0, yScale: 1.0)
                }
            }
        }
        return written
    }

    // MARK: - Sheet title helper

    private func t(_ base: String) -> String {
        orgName.isEmpty ? base : "\(orgName) \u{2014} \(base)"
    }

    // MARK: - Column resolution

    private func col(_ field: ColumnField) -> String? {
        config.columns?.columnName(for: field)
    }

    private func value(_ row: CSVRow, _ field: ColumnField) -> String {
        guard let colName = col(field) else { return "" }
        return row[colName] ?? ""
    }

    // MARK: - Security agents

    private var securityAgents: [SecurityAgentConfig] {
        config.securityAgents ?? []
    }

    // MARK: - Device Inventory sheet

    func writeDeviceInventory() {
        let ws = workbook.addSheet("Device Inventory")
        let ts = ISO8601DateFormatter().string(from: Date())
        let extraFields = mappedExtraInventoryFields()
        let totalCols = 7 + extraFields.count
        var row = ws.writeSheetHeader(title: t("Device Inventory"),
                                      subtitle: "Source: CSV | Generated: \(ts)", ncols: totalCols)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 18)
        ws.setColumnWidth(3, 3, 20)
        ws.setColumnWidth(4, 4, 18)
        ws.setColumnWidth(5, 5, 16)
        ws.setColumnWidth(6, 6, 16)
        for (offset, _) in extraFields.enumerated() {
            ws.setColumnWidth(7 + offset, 7 + offset, 20)
        }

        var headers = [
            col(.computerName) ?? "Computer Name",
            col(.serialNumber) ?? "Serial Number",
            col(.operatingSystem) ?? "OS Version",
            col(.lastCheckin) ?? "Last Check-in",
            col(.department) ?? "Department",
            col(.model) ?? "Model",
            col(.email) ?? "Email",
        ]
        headers += extraFields.map { $0.label }
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: row, col: colIdx, format: .header)
        }
        row += 1

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        for csvRow in rows {
            let stale = isStale(csvRow, days: staleThreshold)
            let fmt: CellFormat = stale ? .yellow : .cell
            ws.write(value(csvRow, .computerName), row: row, col: 0, format: fmt)
            ws.write(value(csvRow, .serialNumber), row: row, col: 1, format: fmt)
            ws.write(normalizeOSVersion(value(csvRow, .operatingSystem)), row: row, col: 2, format: fmt)
            ws.write(value(csvRow, .lastCheckin), row: row, col: 3, format: fmt)
            ws.write(value(csvRow, .department), row: row, col: 4, format: fmt)
            ws.write(value(csvRow, .model), row: row, col: 5, format: fmt)
            ws.write(value(csvRow, .email), row: row, col: 6, format: fmt)
            for (offset, extra) in extraFields.enumerated() {
                ws.write(value(csvRow, extra.field), row: row, col: 7 + offset, format: fmt)
            }
            row += 1
        }
    }

    /// Returns the subset of new optional fields that are actually mapped in config,
    /// as (label, field) pairs, in a fixed display order.
    private func mappedExtraInventoryFields() -> [(label: String, field: ColumnField)] {
        let candidates: [(label: String, field: ColumnField)] = [
            ("Full Name", .fullName),
            ("Asset Tag", .assetTag),
            ("Building", .building),
            ("Position", .position),
            ("Last Logged-In User", .lastLoggedInUser),
            ("Recovery Lock", .recoveryLock),
            ("Battery Health", .batteryHealth),
            ("Entra SSO Status", .entraSSOStatus),
        ]
        return candidates.filter { col($0.field) != nil }
    }

    // MARK: - Stale Devices sheet

    func writeStaleDevices() {
        let ws = workbook.addSheet("Stale Devices")
        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let ts = ISO8601DateFormatter().string(from: Date())
        let extraFields = mappedExtraInventoryFields()
        let totalCols = 6 + extraFields.count
        var row = ws.writeSheetHeader(
            title: t("Stale Devices"),
            subtitle: "Devices not checked in for \(staleThreshold)+ days | Generated: \(ts)",
            ncols: totalCols
        )
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 20)
        ws.setColumnWidth(3, 3, 18)
        ws.setColumnWidth(4, 4, 12)
        ws.setColumnWidth(5, 5, 24)
        for (offset, _) in extraFields.enumerated() {
            ws.setColumnWidth(6 + offset, 6 + offset, 20)
        }

        var headers = [
            col(.computerName) ?? "Computer Name",
            col(.serialNumber) ?? "Serial Number",
            col(.lastCheckin) ?? "Last Check-in",
            col(.department) ?? "Department",
            "Days Since Check-in",
            col(.manager) ?? "Manager",
        ]
        headers += extraFields.map { $0.label }
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: row, col: colIdx, format: .header)
        }
        row += 1

        let staleRows = rows.filter { isStale($0, days: staleThreshold) }
            .sorted { daysSince(value($0, .lastCheckin)) ?? 0 > daysSince(value($1, .lastCheckin)) ?? 0 }

        for csvRow in staleRows {
            let days = daysSince(value(csvRow, .lastCheckin))
            let rawManager = col(.manager).flatMap { csvRow[$0] }
            ws.write(value(csvRow, .computerName), row: row, col: 0, format: .yellow)
            ws.write(value(csvRow, .serialNumber), row: row, col: 1, format: .yellow)
            ws.write(value(csvRow, .lastCheckin), row: row, col: 2, format: .yellow)
            ws.write(value(csvRow, .department), row: row, col: 3, format: .yellow)
            ws.write(days.map { "\($0)" } ?? "", row: row, col: 4, format: .yellow)
            ws.write(ManagerParser.parse(rawManager), row: row, col: 5, format: .yellow)
            for (offset, extra) in extraFields.enumerated() {
                ws.write(value(csvRow, extra.field), row: row, col: 6 + offset, format: .yellow)
            }
            row += 1
        }

        if staleRows.isEmpty {
            ws.write("No stale devices found.", row: row, col: 0, format: .green)
        }
    }

    // MARK: - Security Controls sheet

    func writeSecurityControls() {
        let ws = workbook.addSheet("Security Controls")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Security Controls"),
                                      subtitle: "Active devices only | Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 12)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 10)

        ws.write("Control", row: row, col: 0, format: .header)
        ws.write("Compliant", row: row, col: 1, format: .header)
        ws.write("Non-Compliant", row: row, col: 2, format: .header)
        ws.write("Unknown", row: row, col: 3, format: .header)
        ws.write("% Compliant", row: row, col: 4, format: .header)
        row += 1

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let activeRows = rows.filter { !isStale($0, days: staleThreshold) }
        let total = activeRows.count

        let controls: [(String, ColumnField, String)] = [
            ("FileVault", .filevault, "filevault"),
            ("SIP", .sip, "sip"),
            ("Firewall", .firewall, "firewall"),
            ("Gatekeeper", .gatekeeper, "gatekeeper"),
            ("Secure Boot", .secureBoot, "secure_boot"),
            ("Bootstrap Token", .bootstrapToken, "bootstrap_token"),
        ]

        for (label, field, logical) in controls {
            guard let colName = col(field), columns.contains(colName) else { continue }
            var compliant = 0, nonCompliant = 0, unknown = 0
            for csvRow in activeRows {
                let val = csvRow[colName] ?? ""
                if val.isEmpty {
                    unknown += 1
                } else if isSecurityCompliant(logical: logical, value: val) {
                    compliant += 1
                } else {
                    nonCompliant += 1
                }
            }
            let pct = total > 0 ? Double(compliant) / Double(total) : 0
            let pctFmt: CellFormat = pct >= 0.95 ? .pctGreen : pct >= 0.80 ? .pctYellow : .pctRed
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(compliant, row: row, col: 1, format: .green)
            ws.write(nonCompliant, row: row, col: 2, format: nonCompliant > 0 ? .red : .cell)
            ws.write(unknown, row: row, col: 3, format: .cell)
            ws.write(pct, row: row, col: 4, format: pctFmt)
            row += 1
        }
    }

    // MARK: - Security Agents sheet

    func writeSecurityAgents() {
        let ws = workbook.addSheet("Security Agents")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Security Agents"),
                                      subtitle: "Active devices only | Generated: \(ts)", ncols: 5)
        ws.setColumnWidth(0, 0, 26)
        ws.setColumnWidth(1, 1, 12)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 10)

        ws.write("Agent", row: row, col: 0, format: .header)
        ws.write("Installed", row: row, col: 1, format: .header)
        ws.write("Not Installed", row: row, col: 2, format: .header)
        ws.write("% Installed", row: row, col: 3, format: .header)
        row += 1

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let activeRows = rows.filter { !isStale($0, days: staleThreshold) }
        let total = activeRows.count

        for agent in securityAgents {
            guard columns.contains(agent.column) else { continue }
            var installed = 0
            for csvRow in activeRows {
                let val = (csvRow[agent.column] ?? "").lowercased()
                if val.contains(agent.connectedValue.lowercased()) { installed += 1 }
            }
            let notInstalled = total - installed
            let pct = total > 0 ? Double(installed) / Double(total) : 0
            let pctFmt: CellFormat = pct >= 0.95 ? .pctGreen : pct >= 0.80 ? .pctYellow : .pctRed
            ws.write(agent.name, row: row, col: 0, format: .cell)
            ws.write(installed, row: row, col: 1, format: .green)
            ws.write(notInstalled, row: row, col: 2, format: notInstalled > 0 ? .red : .cell)
            ws.write(pct, row: row, col: 3, format: pctFmt)
            row += 1
        }
    }

    // MARK: - Compliance sheet

    func writeCompliance() {
        guard let compCfg = config.compliance, compCfg.isEnabled else { return }
        let countCol = compCfg.failuresCountColumn ?? ""
        guard !countCol.isEmpty, columns.contains(countCol) else { return }

        let ws = workbook.addSheet("Compliance")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: t(compCfg.resolvedLabel),
            subtitle: "Generated: \(ts)", ncols: 6
        )
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 14)
        ws.setColumnWidth(3, 3, 14)

        ws.write(col(.computerName) ?? "Computer Name", row: row, col: 0, format: .header)
        ws.write(col(.serialNumber) ?? "Serial Number", row: row, col: 1, format: .header)
        ws.write("Failed Rules", row: row, col: 2, format: .header)
        ws.write("Status", row: row, col: 3, format: .header)
        row += 1

        let listCol = compCfg.failuresListColumn ?? ""
        for csvRow in rows {
            let rawCount = csvRow[countCol] ?? ""
            guard let count = Int(rawCount.trimmingCharacters(in: .whitespaces)) else { continue }
            let fmt: CellFormat = count == 0 ? .green : count <= 10 ? .yellow : .red
            let status = count == 0 ? "Pass" : "Fail (\(count))"
            ws.write(value(csvRow, .computerName), row: row, col: 0, format: fmt)
            ws.write(value(csvRow, .serialNumber), row: row, col: 1, format: fmt)
            ws.write(count, row: row, col: 2, format: fmt)
            ws.write(status, row: row, col: 3, format: fmt)
            if !listCol.isEmpty, let list = csvRow[listCol], !list.isEmpty {
                ws.write(list, row: row, col: 4, format: fmt)
            }
            row += 1
        }
    }

    // MARK: - Custom EA dispatch
    // Mirrors the Python dispatch dict in CSVDashboard._write_custom_ea()

    func writeCustomEA(_ ea: CustomEAConfig) {
        guard columns.contains(ea.column) else {
            let msg = "[warn] Custom EA '\(ea.name)' column not found in CSV header " +
                      "— sheet not generated. Expected column: '\(ea.column)'"
            engineLog.warning("\(msg)")
            fputs(msg + "\n", stderr)
            return
        }
        switch ea.type {
        case .boolean:    writeEABoolean(ea)
        case .percentage: writeEAPercentage(ea)
        case .version:    writeEAVersion(ea)
        case .text:       writeEAText(ea)
        case .date:       writeEADate(ea)
        }
    }

    private func writeEABoolean(_ ea: CustomEAConfig) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: t(ea.name), subtitle: ea.column, ncols: 4)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 12)

        let trueValue = ea.trueValue?.lowercased() ?? "true"
        var trueCount = 0, falseCount = 0, unknownCount = 0
        for csvRow in rows {
            let val = (csvRow[ea.column] ?? "").trimmingCharacters(in: .whitespaces)
            if val.isEmpty { unknownCount += 1 }
            else if val.lowercased() == trueValue { trueCount += 1 }
            else { falseCount += 1 }
        }
        let total = trueCount + falseCount + unknownCount
        let pct = total > 0 ? Double(trueCount) / Double(total) : 0

        ws.write("Status", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Percent", row: row, col: 2, format: .header)
        row += 1
        ws.write(ea.trueValue ?? "True", row: row, col: 0, format: .cell)
        ws.write(trueCount, row: row, col: 1, format: .green)
        ws.write(pct, row: row, col: 2, format: pct >= 0.95 ? .pctGreen : pct >= 0.80 ? .pctYellow : .pctRed)
        row += 1
        ws.write("Other", row: row, col: 0, format: .cell)
        ws.write(falseCount, row: row, col: 1, format: falseCount > 0 ? .red : .cell)
        row += 1
        if unknownCount > 0 {
            ws.write("Unknown/Blank", row: row, col: 0, format: .cell)
            ws.write(unknownCount, row: row, col: 1, format: .cell)
        }
    }

    private func writeEAPercentage(_ ea: CustomEAConfig) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: t(ea.name), subtitle: ea.column, ncols: 4)
        ws.setColumnWidth(0, 0, 20)
        ws.setColumnWidth(1, 1, 12)

        let warn = ea.warningThreshold ?? config.thresholds?.resolvedWarningDisk ?? 80
        let crit = ea.criticalThreshold ?? config.thresholds?.resolvedCriticalDisk ?? 90

        var distribution: [String: Int] = [:]
        for csvRow in rows {
            let val = (csvRow[ea.column] ?? "").trimmingCharacters(in: .whitespaces)
            distribution[val, default: 0] += 1
        }

        ws.write("Value", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        for (val, count) in distribution.sorted(by: { ($0.key as NSString).doubleValue < ($1.key as NSString).doubleValue }) {
            let num = (val as NSString).doubleValue
            let fmt: CellFormat = num >= Double(crit) ? .red : num >= Double(warn) ? .yellow : .cell
            let status = num >= Double(crit) ? "Critical" : num >= Double(warn) ? "Warning" : "OK"
            ws.write(val, row: row, col: 0, format: fmt)
            ws.write(count, row: row, col: 1, format: fmt)
            ws.write(status, row: row, col: 2, format: fmt)
            row += 1
        }
    }

    private func writeEAVersion(_ ea: CustomEAConfig) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: t(ea.name), subtitle: ea.column, ncols: 4)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 12)
        ws.setColumnWidth(2, 2, 12)

        let currentVersions = ea.currentVersions?.map { $0.lowercased() } ?? []
        var distribution: [String: Int] = [:]
        for csvRow in rows {
            let val = (csvRow[ea.column] ?? "").trimmingCharacters(in: .whitespaces)
            distribution[val, default: 0] += 1
        }

        ws.write("Version", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        for (ver, count) in distribution.sorted(by: { lhs, rhs in
            compareVersions(lhs.key, rhs.key) > 0
        }) {
            let isCurrent = !currentVersions.isEmpty && currentVersions.contains(where: { ver.lowercased().hasPrefix($0) })
            let fmt: CellFormat = isCurrent ? .green : currentVersions.isEmpty ? .cell : .yellow
            let status = currentVersions.isEmpty ? "" : (isCurrent ? "Current" : "Outdated")
            ws.write(ver, row: row, col: 0, format: fmt)
            ws.write(count, row: row, col: 1, format: fmt)
            ws.write(status, row: row, col: 2, format: fmt)
            row += 1
        }
    }

    private func writeEAText(_ ea: CustomEAConfig) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: t(ea.name), subtitle: ea.column, ncols: 3)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 12)

        var frequency: [String: Int] = [:]
        for csvRow in rows {
            let val = (csvRow[ea.column] ?? "").trimmingCharacters(in: .whitespaces)
            frequency[val.isEmpty ? "(blank)" : val, default: 0] += 1
        }

        ws.write("Value", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1

        for (val, count) in frequency.sorted(by: { $0.value > $1.value }) {
            ws.write(val, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    private func writeEADate(_ ea: CustomEAConfig) {
        let ws = workbook.addSheet(ea.name)
        var row = ws.writeSheetHeader(title: t(ea.name), subtitle: ea.column, ncols: 5)
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 16)
        ws.setColumnWidth(2, 2, 20)
        ws.setColumnWidth(3, 3, 14)

        let warnDays = ea.warningDays ?? config.thresholds?.resolvedCertWarningDays ?? 90
        let now = Date()

        ws.write(col(.computerName) ?? "Computer Name", row: row, col: 0, format: .header)
        ws.write(col(.serialNumber) ?? "Serial Number", row: row, col: 1, format: .header)
        ws.write("Date Value", row: row, col: 2, format: .header)
        ws.write("Days Until", row: row, col: 3, format: .header)
        ws.write("Status", row: row, col: 4, format: .header)
        row += 1

        let dateParser = DateParser()
        for csvRow in rows {
            let rawDate = (csvRow[ea.column] ?? "").trimmingCharacters(in: .whitespaces)
            guard !rawDate.isEmpty else { continue }
            let parsedDate = dateParser.parse(rawDate)
            let daysUntil = parsedDate.map { Int($0.timeIntervalSince(now) / 86400) }

            let fmt: CellFormat
            let status: String
            if let days = daysUntil {
                if days < 0 { fmt = .red; status = "Expired" }
                else if days <= warnDays { fmt = .yellow; status = "Expiring (\(days)d)" }
                else { fmt = .cell; status = "OK" }
            } else {
                fmt = .cell; status = "Unknown"
            }
            ws.write(value(csvRow, .computerName), row: row, col: 0, format: fmt)
            ws.write(value(csvRow, .serialNumber), row: row, col: 1, format: fmt)
            ws.write(rawDate, row: row, col: 2, format: fmt)
            ws.write(daysUntil.map { "\($0)" } ?? "", row: row, col: 3, format: fmt)
            ws.write(status, row: row, col: 4, format: fmt)
            row += 1
        }
    }

    // MARK: - EA Warnings sheet

    /// Write a sheet listing custom EAs whose configured `column` was not found in the CSV header.
    /// Each row includes the EA name and the column that was expected so the user can diagnose
    /// whether the column name in config.yaml needs updating or the CSV export needs regenerating.
    func writeEAWarnings() {
        let missing = (config.customEas ?? []).filter { !columns.contains($0.column) }
        guard !missing.isEmpty else { return }

        let ws = workbook.addSheet("EA Warnings")
        var row = ws.writeSheetHeader(
            title: t("Custom EA Warnings"),
            subtitle: "The following Custom EAs could not be written — column not found in CSV",
            ncols: 3
        )
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 40)
        ws.setColumnWidth(2, 2, 10)

        ws.write("EA Name", row: row, col: 0, format: .header)
        ws.write("Expected CSV Column", row: row, col: 1, format: .header)
        ws.write("Status", row: row, col: 2, format: .header)
        row += 1

        for ea in missing {
            ws.write(ea.name, row: row, col: 0, format: .yellow)
            ws.write(ea.column, row: row, col: 1, format: .yellow)
            ws.write("Column not found", row: row, col: 2, format: .yellow)
            row += 1
        }
    }

    // MARK: - Fleet Drift sheet

    func writeFleetDrift(prior: PriorCSVLoader.Result) {
        let writer = FleetDriftWriter(
            config: config,
            currentRows: rows,
            priorRows: prior.rows,
            priorLabel: prior.label,
            workbook: workbook
        )
        writer.writeFleetDrift()
    }

    // MARK: - Mobile CSV sheets

    /// Resolve a mobile column name from `mobile_columns` config.
    private func mobileCol(_ keyPath: KeyPath<MobileColumnConfig, String?>) -> String? {
        guard let mc = config.mobileColumns else { return nil }
        let value = mc[keyPath: keyPath]
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mobile column value from row, or `""` if not configured or absent.
    private func mobileValue(_ row: CSVRow, _ keyPath: KeyPath<MobileColumnConfig, String?>) -> String {
        guard let colName = mobileCol(keyPath) else { return "" }
        return row[colName] ?? ""
    }

    /// Write the "Mobile Device Inventory" sheet — active devices only.
    ///
    /// Active = last_checkin parses to a valid date and days-since is 0..<staleThreshold.
    /// Devices with no parseable check-in date are excluded.
    func writeMobileInventoryCSV() {
        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let ts = ISO8601DateFormatter().string(from: Date())
        let ws = workbook.addSheet("Mobile Device Inventory")
        var row = ws.writeSheetHeader(
            title: t("Mobile Device Inventory"),
            subtitle: "Active devices (checked in within \(staleThreshold) days) | Generated: \(ts)",
            ncols: 9
        )
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 8, 22)

        let headers = ["Device Name", "Serial Number", "OS Version", "Last Inventory Update",
                       "Email Address", "Model", "Device Family", "Managed", "Supervised"]
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: row, col: colIdx, format: .header)
        }
        row += 1

        let checkinColName = mobileCol(\.lastCheckin)
        for csvRow in rows {
            let checkinStr = checkinColName.flatMap { csvRow[$0] } ?? ""
            guard let days = daysSince(checkinStr), days >= 0, days < staleThreshold else { continue }
            ws.write(mobileValue(csvRow, \.deviceName), row: row, col: 0, format: .cell)
            ws.write(mobileValue(csvRow, \.serialNumber), row: row, col: 1, format: .cell)
            ws.write(mobileValue(csvRow, \.operatingSystem), row: row, col: 2, format: .cell)
            ws.write(checkinStr, row: row, col: 3, format: .cell)
            ws.write(mobileValue(csvRow, \.email), row: row, col: 4, format: .cell)
            ws.write(mobileValue(csvRow, \.model), row: row, col: 5, format: .cell)
            ws.write(mobileValue(csvRow, \.deviceFamily), row: row, col: 6, format: .cell)
            ws.write(mobileValue(csvRow, \.managed), row: row, col: 7, format: .cell)
            ws.write(mobileValue(csvRow, \.supervised), row: row, col: 8, format: .cell)
            row += 1
        }
    }

    /// Write the "Mobile Stale Devices" sheet — devices not checked in within the threshold.
    ///
    /// Devices with no parseable check-in date are excluded (not treated as stale).
    func writeMobileStaleCSV() {
        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        let ts = ISO8601DateFormatter().string(from: Date())
        let ws = workbook.addSheet("Mobile Stale Devices")
        var row = ws.writeSheetHeader(
            title: t("Mobile Stale Devices"),
            subtitle: "Devices not checked in within \(staleThreshold) days | Generated: \(ts)",
            ncols: 9
        )
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 8, 22)

        let headers = ["Device Name", "Serial Number", "Days Stale", "OS Version",
                       "Email Address", "Model", "Device Family", "Managed", "Supervised"]
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: row, col: colIdx, format: .header)
        }
        row += 1

        let checkinColName = mobileCol(\.lastCheckin)
        for csvRow in rows {
            let checkinStr = checkinColName.flatMap { csvRow[$0] } ?? ""
            guard let days = daysSince(checkinStr), days > staleThreshold else { continue }
            ws.write(mobileValue(csvRow, \.deviceName), row: row, col: 0, format: .yellow)
            ws.write(mobileValue(csvRow, \.serialNumber), row: row, col: 1, format: .yellow)
            ws.write(days, row: row, col: 2, format: .int)
            ws.write(mobileValue(csvRow, \.operatingSystem), row: row, col: 3, format: .yellow)
            ws.write(mobileValue(csvRow, \.email), row: row, col: 4, format: .yellow)
            ws.write(mobileValue(csvRow, \.model), row: row, col: 5, format: .yellow)
            ws.write(mobileValue(csvRow, \.deviceFamily), row: row, col: 6, format: .yellow)
            ws.write(mobileValue(csvRow, \.managed), row: row, col: 7, format: .yellow)
            ws.write(mobileValue(csvRow, \.supervised), row: row, col: 8, format: .yellow)
            row += 1
        }
    }

    // MARK: - Logo embed

    /// Load and validate the PNG at `branding.logo_path`.
    ///
    /// Returns `nil` (with a stderr warning) when no path is configured, the file is
    /// absent, unreadable, or the magic bytes are not a valid PNG.
    /// The returned Data is safe to embed via `Worksheet.insertImage` on any sheet.
    static func loadLogoData(from config: ReportConfig) -> Data? {
        guard let logoPath = config.branding?.logoPath,
              !logoPath.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let url = URL(fileURLWithPath: logoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let msg = "[warn] branding.logo_path '\(logoPath)' not found — logo not embedded."
            engineLog.warning("\(msg)")
            fputs(msg + "\n", stderr)
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            let msg = "[warn] branding.logo_path '\(logoPath)' could not be read — logo not embedded."
            engineLog.warning("\(msg)")
            fputs(msg + "\n", stderr)
            return nil
        }

        // PNG magic bytes: 0x89 50 4E 47 0D 0A 1A 0A
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= pngMagic.count,
              data.prefix(pngMagic.count).elementsEqual(pngMagic) else {
            let msg = "[warn] branding.logo_path '\(logoPath)' is not a PNG — logo not embedded."
            engineLog.warning("\(msg)")
            fputs(msg + "\n", stderr)
            return nil
        }
        return data
    }

    // MARK: - Helpers

    private func isStale(_ csvRow: CSVRow, days: Int) -> Bool {
        guard let checkinCol = col(.lastCheckin),
              let raw = csvRow[checkinCol],
              !raw.isEmpty else { return true }
        guard let d = daysSince(raw) else { return false }
        return d >= days
    }

    private func daysSince(_ dateString: String) -> Int? {
        let parser = DateParser()
        guard let date = parser.parse(dateString) else { return nil }
        let seconds = Date().timeIntervalSince(date)
        return Int(seconds / 86400)
    }

    private func normalizeOSVersion(_ raw: String) -> String {
        // Strip common Jamf prefixes like "macOS " / "Mac OS X "
        let prefixes = ["macOS ", "Mac OS X ", "Mac OS ", "macOS", "iOS ", "iPadOS "]
        var s = raw.trimmingCharacters(in: .whitespaces)
        for prefix in prefixes {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        return s
    }

    private func isSecurityCompliant(logical: String, value: String) -> Bool {
        let norm = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !norm.isEmpty else { return false }
        switch logical {
        case "filevault":
            if norm.range(of: #"^(\d+)/(\d+)$"#, options: .regularExpression) != nil {
                let parts = norm.split(separator: "/")
                if parts.count == 2, let e = Int(parts[0]), let t = Int(parts[1]) {
                    return t > 0 && e == t
                }
            }
            return ["encrypted", "all partitions encrypted", "boot partitions encrypted", "yes", "true", "enabled", "on"].contains(norm)
        case "secure_boot":
            return ["full security", "medium security"].contains(norm)
        case "bootstrap_token":
            return ["escrowed", "yes", "true", "enabled"].contains(norm)
        default:
            return ["enabled", "yes", "true", "1", "on", "active", "running", "connected"].contains(norm)
        }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let lParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rParts = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lParts.count, rParts.count) {
            let l = i < lParts.count ? lParts[i] : 0
            let r = i < rParts.count ? rParts[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }
}

// MARK: - DateParser

/// Lightweight date parser that handles the common Jamf CSV date formats without
/// allocating a new DateFormatter per call.
struct DateParser: Sendable {
    private static let formats = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
        "MM/dd/yyyy HH:mm:ss",
        "MM/dd/yyyy",
    ]

    func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in Self.formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }
}
