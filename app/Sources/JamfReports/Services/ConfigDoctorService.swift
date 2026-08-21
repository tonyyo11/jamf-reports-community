import Foundation

// MARK: - Result types

/// Severity of a single config-doctor check, ordered least → most serious.
enum DoctorSeverity: String, Sendable {
    case pass, suggest, warn, fail
}

/// One config-validation finding. `hint` carries fix-it guidance; `nil` for `.pass`.
struct DoctorRow: Identifiable, Sendable, Equatable {
    let id: String
    let severity: DoctorSeverity
    let title: String
    let detail: String
    let hint: String?
}

/// The full result of a config-doctor run, with per-severity counts.
struct DoctorReport: Sendable {
    let rows: [DoctorRow]
    var passCount: Int { rows.filter { $0.severity == .pass }.count }
    var warnCount: Int { rows.filter { $0.severity == .warn }.count }
    var failCount: Int { rows.filter { $0.severity == .fail }.count }
    var suggestCount: Int { rows.filter { $0.severity == .suggest }.count }
}

// MARK: - ConfigDoctorService

/// Native port of the Python `cmd_check` config-validation logic (EPIC #182 #1).
///
/// Validates a profile's `config.yaml` against its CSV export and cached EA results,
/// surfacing missing/mismatched column mappings and structural mistakes. Skips the
/// Python check's jamf-cli auth/command probes and the matplotlib check (charts are
/// native here). The pure `evaluate(...)` seam is the test entry point; `run(...)`
/// loads the on-disk artifacts and calls it.
enum ConfigDoctorService {

    private typealias RequiredComputer = (field: ColumnField, label: String, logical: String)
    private typealias RequiredMobile =
        (label: String, logical: String, path: KeyPath<MobileColumnConfig, String?>)

    private static let requiredComputerFields: [RequiredComputer] = [
        (.computerName, "Computer name", "computer_name"),
        (.serialNumber, "Serial number", "serial_number"),
        (.operatingSystem, "Operating system", "operating_system"),
        (.lastCheckin, "Last check-in", "last_checkin"),
    ]

    nonisolated(unsafe) private static let requiredMobileFields: [RequiredMobile] = [
        ("Device name", "device_name", \.deviceName),
        ("Serial number", "serial_number", \.serialNumber),
        ("Operating system", "operating_system", \.operatingSystem),
        ("Last check-in", "last_checkin", \.lastCheckin),
    ]

    // MARK: - Wiring

    /// Load `config.yaml`, the newest csv-inbox CSV headers, and cached EA coverage
    /// names for `profile`, then evaluate. Missing artifacts are non-fatal — their
    /// checks are skipped rather than crashing.
    static func run(profile: String, workspaceRoot: URL? = nil) -> DoctorReport {
        var config: ReportConfig?
        var parseError: String?
        do {
            let url = try ConfigService.configURL(for: profile, workspaceRoot: workspaceRoot)
            config = try ConfigLoader.load(from: url)
        } catch let error as ConfigLoader.LoadError {
            parseError = error.keyPathDetail
                ?? error.errorDescription
                ?? "config could not be parsed"
        } catch {
            parseError = error.localizedDescription
        }

        let csvHeaders = loadNewestCSVHeaders(profile: profile)
        let csvFamily = csvHeaders.map { CSVFamilyDetector.detect(headers: $0) } ?? nil
        let eaNames = ExtensionAttributeService.load(profile: profile).coverage.map(\.eaName)

        var rows = evaluate(
            config: config,
            parseError: parseError,
            csvHeaders: csvHeaders,
            csvFamily: csvFamily,
            eaCoverageNames: eaNames
        )
        if let config, parseError == nil {
            rows += accuracyRows(config: config, profile: profile)
        }
        rows += evaluateCloudStorage(cloudStorageInputs(profile: profile))
        return DoctorReport(rows: rows)
    }

    /// Read the header row of the newest CSV in the profile workspace. Returns `nil`
    /// when no CSV is present (its checks are then skipped).
    private static func loadNewestCSVHeaders(profile: String) -> [String]? {
        guard let url = CLIBridge.newestCSV(in: profile),
              var text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }
        let firstLine = text.components(separatedBy: CharacterSet.newlines).first ?? ""
        let headers = firstLine.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) }
        return headers.allSatisfy(\.isEmpty) ? nil : headers
    }

    // MARK: - Pure evaluator (test seam)

    /// Pure evaluation over already-loaded inputs. Order: parse → required columns →
    /// CSV checks → structural → baselines. Passing checks emit `.pass` rows so the
    /// doctor shows green confirmations (like Python's `[ok]` lines).
    static func evaluate(
        config: ReportConfig?,
        parseError: String?,
        csvHeaders: [String]?,
        csvFamily: CSVFamily?,
        eaCoverageNames: [String]
    ) -> [DoctorRow] {
        if let parseError {
            return [DoctorRow(
                id: "config.parse",
                severity: .fail,
                title: "Config could not be parsed",
                detail: parseError,
                hint: "Fix the YAML at the location above, or restore defaults in Config."
            )]
        }
        guard let config else { return [] }

        var rows: [DoctorRow] = []
        if let headers = csvHeaders {
            // A CSV validates every configured column against real headers, which
            // supersedes the bare "is it configured" required-column check — running
            // both would emit a contradictory OK (configured) + ERROR (not in CSV)
            // pair for the same field. Same reasoning gates the structural agent
            // checks, which the CSV path already covers.
            rows += csvRows(config, headers: headers, family: csvFamily)
        } else {
            // No CSV to validate against: fall back to config-presence checks.
            rows += requiredColumnRows(config)
            rows += securityAgentStructuralRows(config)
        }
        rows += structuralRows(config)
        rows += baselineRows(config, eaCoverageNames: eaCoverageNames)
        rows += alertsRows(config)
        return rows
    }

    // MARK: - Required columns

    private static func requiredColumnRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        let columns = config.columns
        for required in requiredComputerFields {
            let value = columns?.columnName(for: required.field)
            rows.append(requiredRow(
                id: "required.columns.\(required.logical)",
                label: required.label,
                value: value
            ))
        }
        // Only validate mobile required columns when the config opts into a mobile
        // fleet (at least one mobile column mapped). Defaults still populate an empty
        // mobile_columns, so a computer-only config must not warn on every mobile
        // field — matches Python cmd_check, which validates the detected CSV family.
        if let mobile = config.mobileColumns, !mobileMappings(config).isEmpty {
            for required in requiredMobileFields {
                rows.append(requiredRow(
                    id: "required.mobile_columns.\(required.logical)",
                    label: "Mobile \(required.label.lowercased())",
                    value: nonEmpty(mobile[keyPath: required.path])
                ))
            }
        }
        return rows
    }

    private static func requiredRow(id: String, label: String, value: String?) -> DoctorRow {
        if let value {
            return DoctorRow(id: id, severity: .pass, title: label,
                             detail: "Mapped to '\(value)'.", hint: nil)
        }
        return DoctorRow(
            id: id, severity: .warn, title: label, detail: "Not configured.",
            hint: "Run scaffold or map this column in Config."
        )
    }

    // MARK: - CSV checks

    private static func csvRows(
        _ config: ReportConfig,
        headers: [String],
        family: CSVFamily?
    ) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        let normalized = Set(headers.map { CSVFamilyDetector.normalize($0) })

        if family == nil {
            rows.append(DoctorRow(
                id: "csv.family", severity: .warn, title: "CSV family",
                detail: "CSV doesn't look like a Jamf computer or mobile export.",
                hint: "Re-export from Jamf Pro, or check the file in csv-inbox."
            ))
        }

        rows += mappedColumnRows(config, headers: headers, normalized: normalized, family: family)
        rows += customEARows(config, normalized: normalized)
        if family != .mobile {
            rows += securityAgentCSVRows(config, normalized: normalized)
            rows += complianceColumnCSVRows(config, normalized: normalized)
        }
        return rows
    }

    private static func mappedColumnRows(
        _ config: ReportConfig,
        headers: [String],
        normalized: Set<String>,
        family: CSVFamily?
    ) -> [DoctorRow] {
        let mappings: [(logical: String, column: String)] = family == .mobile
            ? mobileMappings(config)
            : computerMappings(config)
        return mappings.map { mapping in
            columnRow(
                logical: mapping.logical, column: mapping.column,
                headers: headers, normalized: normalized, family: family
            )
        }
    }

    private static func columnRow(
        logical: String,
        column: String,
        headers: [String],
        normalized: Set<String>,
        family: CSVFamily?
    ) -> DoctorRow {
        let id = "columns.\(logical)"
        guard normalized.contains(CSVFamilyDetector.normalize(column)) else {
            return DoctorRow(
                id: id, severity: .fail, title: logical,
                detail: "'\(column)' not found in CSV.",
                hint: "Re-run scaffold or fix the mapping."
            )
        }
        let best = ScaffoldService
            .bestColumnMatch(headers: headers, logical: logical, family: family)
        if let best,
           CSVFamilyDetector.normalize(best.header) != CSVFamilyDetector.normalize(column),
           best.score > columnScore(column: column, logical: logical, family: family) {
            return DoctorRow(
                id: id, severity: .suggest, title: logical,
                detail: "Mapped to '\(column)', but '\(best.header)' looks like a stronger match.",
                hint: "Consider re-mapping to '\(best.header)'."
            )
        }
        return DoctorRow(id: id, severity: .pass, title: logical,
                         detail: "Mapped to '\(column)'.", hint: nil)
    }

    private static func columnScore(column: String, logical: String, family: CSVFamily?) -> Int {
        ScaffoldService
            .bestColumnMatch(headers: [column], logical: logical, family: family)?.score ?? 0
    }

    private static func customEARows(
        _ config: ReportConfig,
        normalized: Set<String>
    ) -> [DoctorRow] {
        (config.customEas ?? []).compactMap { ea in
            let column = ea.column.trimmingCharacters(in: .whitespaces)
            guard !column.isEmpty else { return nil }
            let id = "custom_ea.\(ea.name).column"
            if normalized.contains(CSVFamilyDetector.normalize(column)) {
                return DoctorRow(id: id, severity: .pass, title: "EA: \(ea.name)",
                                 detail: "Mapped to '\(column)'.", hint: nil)
            }
            return DoctorRow(
                id: id, severity: .fail, title: "EA: \(ea.name)",
                detail: "'\(column)' not found in CSV.",
                hint: "Re-run scaffold or fix the custom_eas column."
            )
        }
    }

    private static func securityAgentCSVRows(
        _ config: ReportConfig,
        normalized: Set<String>
    ) -> [DoctorRow] {
        (config.securityAgents ?? []).map { agent in
            let column = agent.column.trimmingCharacters(in: .whitespaces)
            let id = "security_agent.\(agent.name).column"
            if column.isEmpty || !normalized.contains(CSVFamilyDetector.normalize(column)) {
                return DoctorRow(
                    id: id, severity: .fail, title: "Agent: \(agent.name)",
                    detail: column.isEmpty
                        ? "No column configured."
                        : "'\(column)' not found in CSV.",
                    hint: "Map the agent's status column to a CSV header."
                )
            }
            if agent.connectedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                return DoctorRow(
                    id: "security_agent.\(agent.name).connected_value", severity: .warn,
                    title: "Agent: \(agent.name)",
                    detail: "No connected_value set — any non-empty cell counts as connected.",
                    hint: "Set connected_value (e.g. 'Installed') for a precise match."
                )
            }
            return DoctorRow(id: id, severity: .pass, title: "Agent: \(agent.name)",
                             detail: "Mapped to '\(column)'.", hint: nil)
        }
    }

    private static func complianceColumnCSVRows(
        _ config: ReportConfig,
        normalized: Set<String>
    ) -> [DoctorRow] {
        let compliance = config.compliance
        var rows: [DoctorRow] = []
        if let count = nonEmpty(compliance?.failuresCountColumn) {
            rows.append(complianceColumnRow(
                id: "compliance.failures_count_column", label: "Compliance failures count",
                column: count, normalized: normalized
            ))
        }
        if let list = nonEmpty(compliance?.failuresListColumn) {
            rows.append(complianceColumnRow(
                id: "compliance.failures_list_column", label: "Compliance failures list",
                column: list, normalized: normalized
            ))
        }
        return rows
    }

    private static func complianceColumnRow(
        id: String,
        label: String,
        column: String,
        normalized: Set<String>
    ) -> DoctorRow {
        if normalized.contains(CSVFamilyDetector.normalize(column)) {
            return DoctorRow(id: id, severity: .pass, title: label,
                             detail: "Mapped to '\(column)'.", hint: nil)
        }
        return DoctorRow(
            id: id, severity: .fail, title: label, detail: "'\(column)' not found in CSV.",
            hint: "Re-run scaffold or fix the compliance mapping."
        )
    }

    // MARK: - Structural checks

    private static func structuralRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        rows += complianceStructuralRows(config)
        rows += duplicateColumnRows(config)
        rows += platformRows(config)
        rows += customEAStructuralRows(config)
        return rows
    }

    private static func complianceStructuralRows(_ config: ReportConfig) -> [DoctorRow] {
        guard let compliance = config.compliance, compliance.isEnabled else { return [] }
        let hasCount = nonEmpty(compliance.failuresCountColumn) != nil
        let hasList = nonEmpty(compliance.failuresListColumn) != nil
        guard !hasCount || !hasList else { return [] }
        return [DoctorRow(
            id: "compliance.columns", severity: .warn, title: "Compliance enabled",
            detail: "Compliance is on but failures_count_column or failures_list_column is empty.",
            hint: "Set both compliance columns, or disable compliance."
        )]
    }

    private static func duplicateColumnRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        rows += duplicates(in: computerMappings(config), section: "columns")
        rows += duplicates(in: mobileMappings(config), section: "mobile_columns")
        return rows
    }

    private static func duplicates(
        in mappings: [(logical: String, column: String)],
        section: String
    ) -> [DoctorRow] {
        var byColumn: [String: [String]] = [:]
        for mapping in mappings {
            let key = CSVFamilyDetector.normalize(mapping.column)
            byColumn[key, default: []].append(mapping.logical)
        }
        return byColumn.filter { $0.value.count >= 2 }.sorted { $0.key < $1.key }.map { entry in
            let fields = entry.value.sorted().joined(separator: ", ")
            return DoctorRow(
                id: "\(section).duplicate.\(entry.key)", severity: .warn,
                title: "Duplicate column mapping",
                detail: "'\(entry.key)' is mapped to: \(fields).",
                hint: "Each CSV column should map to a single logical field."
            )
        }
    }

    private static func platformRows(_ config: ReportConfig) -> [DoctorRow] {
        guard let platform = config.platform, platform.isEnabled,
              platform.benchmarkTitles.isEmpty else { return [] }
        return [DoctorRow(
            id: "platform.benchmarks", severity: .warn, title: "Platform enabled",
            detail: "Platform is on but no compliance_benchmarks are listed.",
            hint: "Add at least one benchmark title, or disable platform."
        )]
    }

    private static func customEAStructuralRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        for ea in config.customEas ?? [] {
            // `ea.type` is a decoded enum, so an invalid type string is already a
            // ConfigLoader parse failure — no type-validity row is reachable here.
            if ea.type == .boolean, nonEmpty(ea.trueValue) == nil {
                rows.append(DoctorRow(
                    id: "custom_ea.\(ea.name).true_value", severity: .warn, title: "EA: \(ea.name)",
                    detail: "Boolean EA has no true_value set.",
                    hint: "Set true_value (the cell value that counts as a pass)."
                ))
            }
        }
        return rows
    }

    private static func securityAgentStructuralRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        for agent in config.securityAgents ?? [] {
            if agent.column.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(DoctorRow(
                    id: "security_agent.\(agent.name).column.structural", severity: .warn,
                    title: "Agent: \(agent.name)", detail: "No column configured.",
                    hint: "Set the agent's status column."
                ))
            }
            if agent.connectedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(DoctorRow(
                    id: "security_agent.\(agent.name).connected_value.structural", severity: .warn,
                    title: "Agent: \(agent.name)", detail: "No connected_value set.",
                    hint: "Set connected_value for a precise match."
                ))
            }
        }
        return rows
    }

    // MARK: - Baselines vs EA results

    private static func baselineRows(
        _ config: ReportConfig,
        eaCoverageNames: [String]
    ) -> [DoctorRow] {
        guard !eaCoverageNames.isEmpty else { return [] }
        let seen = Set(eaCoverageNames.map { $0.lowercased() })
        return config.compliance?.resolvedBaselines.compactMap { baseline -> DoctorRow? in
            let column = baseline.failuresCountColumn.trimmingCharacters(in: .whitespaces)
            guard !column.isEmpty else { return nil }
            if seen.contains(column.lowercased()) {
                return DoctorRow(
                    id: "compliance.baseline.\(baseline.name)", severity: .pass,
                    title: "Baseline: \(baseline.name)",
                    detail: "EA '\(column)' seen in cached ea-results.", hint: nil
                )
            }
            return DoctorRow(
                id: "compliance.baseline.\(baseline.name)", severity: .warn,
                title: "Baseline: \(baseline.name)",
                detail: "Baseline EA '\(column)' not seen in cached ea-results.",
                hint: "Collect EA results, or fix the baseline column name."
            )
        } ?? []
    }

    // MARK: - Alerts (2.6 metric-threshold alerting)

    /// Validates the `alerts:` block. Only emitted when the block is present at
    /// all (an unopted-in workspace gets no rows). Each malformed rule (unknown
    /// metric/when, absent/non-finite/negative threshold — the same criteria as
    /// `AlertsConfig.resolvedRules`) gets its own error row; an enabled-but-
    /// undeliverable configuration warns; a healthy configuration confirms.
    private static func alertsRows(_ config: ReportConfig) -> [DoctorRow] {
        guard let alerts = config.alerts else { return [] }
        var rows: [DoctorRow] = []

        for (index, rule) in (alerts.rules ?? []).enumerated() {
            guard let failure = alertRuleFailure(rule) else { continue }
            let label = rule.metric ?? "(no metric)"
            rows.append(DoctorRow(
                id: "alerts.rule.\(index)", severity: .fail,
                title: "Alert rule ignored",
                detail: "Rule for '\(label)' ignored — \(failure).",
                hint: "Fix the rule under alerts.rules in config.yaml, or remove it."
            ))
        }

        let notifyUsable = config.notify?.isUsable ?? false
        if alerts.isEnabled, !notifyUsable {
            rows.append(DoctorRow(
                id: "alerts.notify_missing", severity: .warn,
                title: "Alerts enabled without a webhook",
                detail: "Alerts are enabled but no usable webhook is configured "
                    + "(notify.url must be https and notify.enabled true) — "
                    + "alerts cannot be delivered.",
                hint: "Configure notify: in config.yaml, or disable alerts."
            ))
        } else if alerts.isEnabled, notifyUsable, !alerts.resolvedRules.isEmpty {
            rows.append(DoctorRow(
                id: "alerts.armed", severity: .pass, title: "Alerts armed",
                detail: "\(alerts.resolvedRules.count) alert rule(s) armed.", hint: nil
            ))
        }
        return rows
    }

    /// Reason a raw alert rule doesn't survive `AlertsConfig.resolvedRules`, or
    /// `nil` when the rule is valid. Mirrors that filter's criteria exactly.
    private static func alertRuleFailure(_ rule: AlertRule) -> String? {
        let sampleKeys = AlertMetric.allCases.prefix(4).map(\.rawValue).joined(separator: ", ")
        guard let metricRaw = nonEmpty(rule.metric) else {
            return "no metric set — valid keys: \(sampleKeys), … (see config.example.yaml)"
        }
        guard AlertMetric(rawValue: metricRaw) != nil else {
            return "unknown metric '\(metricRaw)' — valid keys: \(sampleKeys), … "
                + "(see config.example.yaml)"
        }
        guard let whenRaw = nonEmpty(rule.when) else {
            return "no 'when' comparison set — valid values: below, above, drops_more_than"
        }
        guard AlertRule.Comparison(rawValue: whenRaw) != nil else {
            return "unknown 'when' comparison '\(whenRaw)' — "
                + "valid values: below, above, drops_more_than"
        }
        guard let threshold = rule.threshold else {
            return "no threshold set"
        }
        guard threshold.isFinite, threshold >= 0 else {
            return "threshold \(threshold) is not a valid non-negative number"
        }
        return nil
    }

    // MARK: - Column-mapping helpers

    private typealias Mapping = (logical: String, column: String)

    private static func computerMappings(_ config: ReportConfig) -> [Mapping] {
        guard let columns = config.columns else { return [] }
        return ColumnField.allCases.compactMap { field in
            columns.columnName(for: field).map { (field.rawValue.snakeCased, $0) }
        }
    }

    private static func mobileMappings(_ config: ReportConfig) -> [Mapping] {
        guard let mobile = config.mobileColumns else { return [] }
        let pairs: [(String, String?)] = [
            ("device_name", mobile.deviceName), ("serial_number", mobile.serialNumber),
            ("operating_system", mobile.operatingSystem), ("last_checkin", mobile.lastCheckin),
            ("email", mobile.email), ("model", mobile.model),
            ("device_family", mobile.deviceFamily), ("managed", mobile.managed),
            ("supervised", mobile.supervised),
        ]
        return pairs.compactMap { logical, value in
            nonEmpty(value).map { (logical, $0) }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Data-accuracy family (checks 1–4)

extension ConfigDoctorService {

    // MARK: Pure inputs (test seam)

    /// Newest CSV export, pre-parsed. `columns` is the header row; `rows` are the
    /// data rows (dictionary per row). `ageDays` is the file's age in whole days.
    /// Absent when no CSV is present.
    struct AccuracyCSV: Sendable {
        let columns: [String]
        let rows: [CSVRow]
        let ageDays: Int
        let fileName: String
    }

    /// Everything the accuracy checks need, already loaded off `evaluate`'s path so
    /// the pure seam never touches disk. Any field may be nil/empty — each check
    /// degrades to a single info row or no row rather than failing the doctor.
    struct AccuracyInputs: Sendable {
        var csv: AccuracyCSV?
        /// Device count from the newest `computers` snapshot; nil when absent.
        var computersCount: Int?
        /// Newest decodable `ea-results` rows; nil when absent/undecodable.
        var eaRows: [EAResultRow]?
        /// Coverage drift outcome between the two newest ea-results days; nil
        /// when the caller never gathered a data dir to check (e.g. tests that
        /// don't exercise this check at all). When gathered, distinguishes a
        /// computed drift (possibly empty/stable) from insufficient data.
        var coverageDrift: EAParseHealthService.CoverageDriftOutcome?
    }

    // MARK: IO gather (real run)

    /// Load the on-disk inputs (decoding the ~13 MB ea-results snapshot ONCE and
    /// sharing it across checks 1/2/4), then evaluate the pure seam.
    static func accuracyRows(config: ReportConfig, profile: String) -> [DoctorRow] {
        let dataDir = try? WorkspacePaths.dataDir(for: profile)

        let inputs = AccuracyInputs(
            csv: loadAccuracyCSV(profile: profile),
            computersCount: loadComputersCount(dataDir: dataDir),
            eaRows: loadNewestEARows(dataDir: dataDir),
            coverageDrift: dataDir.map { EAParseHealthService.coverageDriftOutcome(dataDir: $0) }
        )
        return evaluateAccuracy(config: config, inputs: inputs)
    }

    /// Read + parse the newest csv-inbox CSV and stamp its age. Nil when absent or
    /// unreadable (its dependent checks then skip).
    private static func loadAccuracyCSV(profile: String) -> AccuracyCSV? {
        guard let url = CLIBridge.newestCSV(in: profile),
              let data = try? Data(contentsOf: url),
              let (columns, rows) = try? CSVParser.parse(data) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let ageDays = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: modified, to: Date()).day ?? 0
        return AccuracyCSV(
            columns: columns, rows: rows,
            ageDays: max(0, ageDays), fileName: url.lastPathComponent
        )
    }

    /// Device count from the newest `computers` snapshot (a bare JSON array). Nil
    /// when the snapshot is absent or not an array.
    private static func loadComputersCount(dataDir: URL?) -> Int? {
        guard let dataDir else { return nil }
        let dir = dataDir.appendingPathComponent("computers", isDirectory: true)
        guard let url = FileManager.newestSnapshotFile(in: dir),
              let data = try? Data(contentsOf: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return items.count
    }

    /// Decode the newest `ea-results` snapshot ONCE. Nil when absent/undecodable.
    private static func loadNewestEARows(dataDir: URL?) -> [EAResultRow]? {
        guard let dataDir else { return nil }
        let dir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        guard let url = FileManager.newestSnapshotFile(in: dir),
              let data = try? Data(contentsOf: url) else { return nil }
        return EAResultRow.decodeSnapshot(data).rows
    }

    // MARK: Pure evaluator

    /// Pure over already-loaded inputs. Emits the accuracy family in check order.
    /// Every check degrades gracefully — a missing input drops its rows, never an
    /// error that blocks the doctor.
    static func evaluateAccuracy(config: ReportConfig, inputs: AccuracyInputs) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        rows += reconciliationRows(config: config, inputs: inputs)
        rows += staleCSVRows(config: config, inputs: inputs)
        rows += parseHealthRows(config: config, inputs: inputs)
        rows += coverageDriftRows(inputs: inputs)
        rows += crossCheckRows(config: config, inputs: inputs)
        return rows
    }

    // MARK: Check 1 — cross-source device-count reconciliation

    private struct CountSource { let label: String; let count: Int }

    private static func reconciliationRows(
        config: ReportConfig,
        inputs: AccuracyInputs
    ) -> [DoctorRow] {
        var sources: [CountSource] = []
        if let csv = inputs.csv, let serial = mappedSerialColumn(config) {
            let deduped = distinctSerials(rows: csv.rows, column: serial)
            if deduped > 0 { sources.append(CountSource(label: "CSV export", count: deduped)) }
        }
        if let computers = inputs.computersCount, computers > 0 {
            sources.append(CountSource(label: "computers snapshot", count: computers))
        }
        if let eaRows = inputs.eaRows {
            let ids = MSCPComplianceService.allDistinctDeviceIds(in: eaRows).count
            if ids > 0 { sources.append(CountSource(label: "ea-results", count: ids)) }
        }

        guard sources.count >= 2 else { return [] }  // < 2 comparable sources → skip

        if let divergent = firstDivergentPair(sources) {
            let (a, b) = divergent
            return [DoctorRow(
                id: "accuracy.reconciliation", severity: .warn,
                title: "Device counts disagree",
                detail: "\(a.label) has \(a.count) devices but \(b.label) has \(b.count) "
                    + "(more than 10% apart).",
                hint: "Re-collect, or replace the stale export, so the sources agree."
            )]
        }
        let summary = sources.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
        return [DoctorRow(
            id: "accuracy.reconciliation", severity: .pass,
            title: "Device counts agree",
            detail: "Within 10% across sources (\(summary)).", hint: nil
        )]
    }

    /// First pair (in source order) whose counts diverge by more than 10% of the
    /// larger count. Nil when every pair is within tolerance.
    private static func firstDivergentPair(
        _ sources: [CountSource]
    ) -> (CountSource, CountSource)? {
        for i in sources.indices {
            for j in sources.index(after: i)..<sources.endIndex {
                let a = sources[i], b = sources[j]
                let larger = Double(max(a.count, b.count))
                guard larger > 0 else { continue }
                if Double(abs(a.count - b.count)) / larger > 0.10 { return (a, b) }
            }
        }
        return nil
    }

    private static func mappedSerialColumn(_ config: ReportConfig) -> String? {
        nonEmpty(config.columns?.columnName(for: .serialNumber))
    }

    /// Distinct non-empty values in `column` across `rows` (case-insensitive).
    private static func distinctSerials(rows: [CSVRow], column: String) -> Int {
        var seen: Set<String> = []
        for row in rows {
            let value = (row[column] ?? "").trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { seen.insert(value.lowercased()) }
        }
        return seen.count
    }

    // MARK: Check 1b — stale CSV age

    private static func staleCSVRows(config: ReportConfig, inputs: AccuracyInputs) -> [DoctorRow] {
        guard let csv = inputs.csv else { return [] }
        let staleDays = config.thresholds?.resolvedStaleDays ?? 30
        guard csv.ageDays > staleDays else { return [] }
        return [DoctorRow(
            id: "accuracy.csv_age", severity: .warn,
            title: "CSV export is stale",
            detail: "'\(csv.fileName)' is \(csv.ageDays) days old "
                + "(stale after \(staleDays)).",
            hint: "Delete or replace the stale export in csv-inbox."
        )]
    }

    // MARK: Check 2 — per-column parse health

    private static func parseHealthRows(config: ReportConfig, inputs: AccuracyInputs) -> [DoctorRow] {
        // Each health carries its assessed type (nil = int-count) for hint wording.
        var healths: [(health: EAParseHealthService.ColumnHealth, type: CustomEAConfig.EAType?)] = []

        // custom_eas assessed against the CSV column.
        if let csv = inputs.csv {
            for ea in config.customEas ?? [] {
                let column = ea.column.trimmingCharacters(in: .whitespaces)
                guard !column.isEmpty, csv.columns.contains(column) else { continue }
                let values = csv.rows.map { $0[column] ?? "" }
                healths.append((EAParseHealthService.assess(
                    column: column, values: values, type: ea.type
                ), ea.type))
            }
        }

        // compliance baselines assessed against the ea-results failure-count column.
        if let eaRows = inputs.eaRows {
            for baseline in config.compliance?.resolvedBaselines ?? [] {
                let column = baseline.failuresCountColumn.trimmingCharacters(in: .whitespaces)
                guard !column.isEmpty else { continue }
                let values = eaRows
                    .filter { $0.eaName?.caseInsensitiveCompare(column) == .orderedSame }
                    .map { $0.value?.stringValue ?? "" }
                guard !values.isEmpty else { continue }
                healths.append((EAParseHealthService.assessIntCount(
                    column: column, values: values, maxValid: baseline.ruleCount
                ), nil))
            }
        }

        guard !healths.isEmpty else { return [] }

        var rows: [DoctorRow] = []
        var cleanCount = 0
        for entry in healths {
            guard let rate = entry.health.parseRate else { continue }  // no non-empty → skip
            if rate < 0.90 {
                rows.append(parseHealthWarnRow(entry.health, type: entry.type, rate: rate))
            } else {
                cleanCount += 1
            }
        }
        if cleanCount > 0 {
            rows.insert(DoctorRow(
                id: "accuracy.parse_health.ok", severity: .pass,
                title: "Column values parse cleanly",
                detail: "\(cleanCount) column\(cleanCount == 1 ? "" : "s") parse cleanly (≥90%).",
                hint: nil
            ), at: 0)
        }
        return rows
    }

    private static func parseHealthWarnRow(
        _ health: EAParseHealthService.ColumnHealth,
        type: CustomEAConfig.EAType?,
        rate: Double
    ) -> DoctorRow {
        let pct = Int((rate * 100).rounded())
        var detail = "Only \(pct)% of '\(health.column)' values parse "
            + "(\(health.parseable) of \(health.nonEmpty))."
        let topSkeleton = health.topUnparseable.first
        if let top = topSkeleton {
            detail += " Most common unparseable shape: \(top.skeleton) (\(top.count))."
        }
        // A percentage EA whose worst skeleton is all-digits is usually a raw-count
        // column mis-typed by the scaffold (values >100 fail the 0–100 clamp).
        let looksLikeCounts = type == .percentage
            && topSkeleton?.skeleton.range(of: #"^9+$"#, options: .regularExpression) != nil
        let hint = looksLikeCounts
            ? "Values look like raw counts — if this EA holds counts rather than "
                + "percentages, change its type (percentage expects 0–100)."
            : "Check the EA type or the source column — bad values become No Data."
        return DoctorRow(
            id: "accuracy.parse_health.\(health.column)", severity: .warn,
            title: "Column parses poorly",
            detail: detail,
            hint: hint
        )
    }

    // MARK: Check 3 — EA coverage drift

    private static let coverageDriftCap = 5

    private static func coverageDriftRows(inputs: AccuracyInputs) -> [DoctorRow] {
        guard let outcome = inputs.coverageDrift else { return [] }  // nothing gathered → skip
        let drift: [EAParseHealthService.CoverageDrift]
        switch outcome {
        case .insufficientData(let reason):
            // Absence of a comparable pair of days is NOT the same as "stable" —
            // surface it distinctly rather than rendering the green OK row.
            return [DoctorRow(
                id: "accuracy.coverage_drift.unavailable", severity: .suggest,
                title: "EA coverage drift unavailable",
                detail: reason + ".",
                hint: "Collect ea-results on two different days to enable this check."
            )]
        case .computed(let computedDrift):
            drift = computedDrift
        }
        let drops = drift.filter { $0.deltaPP <= -15 }
        guard !drops.isEmpty else {
            return [DoctorRow(
                id: "accuracy.coverage_drift.ok", severity: .pass,
                title: "EA coverage stable",
                detail: "No EA lost more than 15 points of coverage since the prior snapshot.",
                hint: nil
            )]
        }
        var rows: [DoctorRow] = drops.prefix(coverageDriftCap).map { drop in
            let delta = Int(drop.deltaPP.rounded())
            return DoctorRow(
                id: "accuracy.coverage_drift.\(drop.eaName)", severity: .warn,
                title: "EA coverage dropped",
                detail: "'\(drop.eaName)' coverage fell \(delta) points "
                    + "(\(Int(drop.previousPct.rounded()))% → \(Int(drop.currentPct.rounded()))%).",
                hint: "Confirm the EA still populates — a drop can silently thin a report."
            )
        }
        if drops.count > coverageDriftCap {
            let more = drops.count - coverageDriftCap
            rows.append(DoctorRow(
                id: "accuracy.coverage_drift.more", severity: .warn,
                title: "More EAs dropped coverage",
                detail: "+\(more) more EA\(more == 1 ? "" : "s") dropped over 15 points.",
                hint: "Review the ea-results snapshot for a broader collection failure."
            ))
        }
        return rows
    }

    // MARK: Check 4 — mSCP count-vs-list cross-check

    private static func crossCheckRows(config: ReportConfig, inputs: AccuracyInputs) -> [DoctorRow] {
        guard let eaRows = inputs.eaRows else { return [] }
        let baselines = config.compliance?.resolvedBaselines ?? []
        let results = MSCPComplianceService.crossCheck(rows: eaRows, baselines: baselines)
        guard !results.isEmpty else { return [] }  // no list columns configured → skip

        return results.compactMap { result in
            guard let rate = result.disagreementRate else {
                // Both columns configured but no device had both rows → nothing to
                // compare; surface as a benign OK rather than a false alarm.
                return DoctorRow(
                    id: "accuracy.cross_check.\(result.baselineName)", severity: .pass,
                    title: "Baseline count vs list: \(result.baselineName)",
                    detail: "No devices had both a count and a list value to compare.",
                    hint: nil
                )
            }
            if rate > 0.05 {
                let pct = Int((rate * 100).rounded())
                return DoctorRow(
                    id: "accuracy.cross_check.\(result.baselineName)", severity: .warn,
                    title: "Baseline count vs list disagree: \(result.baselineName)",
                    detail: "\(pct)% of \(result.devicesCompared) compared devices have a "
                        + "failure count that doesn't match their failure list length.",
                    hint: "One EA is out of date — re-run the mSCP audit so both agree."
                )
            }
            return DoctorRow(
                id: "accuracy.cross_check.\(result.baselineName)", severity: .pass,
                title: "Baseline count vs list agree: \(result.baselineName)",
                detail: "Count and list agree on \(result.devicesCompared) compared devices.",
                hint: nil
            )
        }
    }
}

// MARK: - Logical-field naming

private extension String {
    /// camelCase → snake_case, matching `config.yaml` logical column keys
    /// (e.g. `operatingSystem` → `operating_system`).
    var snakeCased: String {
        var out = ""
        for ch in self {
            if ch.isUppercase {
                out += "_"
                out += ch.lowercased()
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Cloud-storage family

/// Inputs for the cloud-storage checks, resolved by `ConfigDoctorService.run`.
/// Split out so the rules are testable without touching a real synced volume.
struct CloudStorageInputs: Sendable {
    let workspace: URL?
    let outputDir: URL?
    let archiveDir: URL?
    let backupsDir: URL?
    /// Sync-conflict filenames found in the workspace (sampled, not exhaustive).
    let conflictCopies: [String]
}

extension ConfigDoctorService {

    /// Pure rules for the "Cloud storage" family.
    ///
    /// The app's storage model is a local, single-writer workspace, and the
    /// defaults keep it that way. Operators still want teammates to read the
    /// output, so the supported shape is: **workspace local, `output.output_dir`
    /// on the share.** These rows say which shape is in effect and what the
    /// risky one costs, rather than refusing to run.
    static func evaluateCloudStorage(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        var rows: [DoctorRow] = []

        let workspaceProvider = inputs.workspace.flatMap(CloudStorage.provider(for:))
        let outputProvider = inputs.outputDir.flatMap(CloudStorage.provider(for:))
        let archiveProvider = inputs.archiveDir.flatMap(CloudStorage.provider(for:))
        let backupsProvider = inputs.backupsDir.flatMap(CloudStorage.provider(for:))

        if let provider = workspaceProvider {
            rows.append(DoctorRow(
                id: "cloud.workspace",
                severity: .warn,
                title: "Workspace is on \(provider.displayName)",
                detail: "The whole workspace — raw device snapshots, run logs, backups and "
                    + "config.yaml — syncs to \(provider.displayName). Raw snapshots and run "
                    + "logs hold device serials, usernames and email addresses, and file "
                    + "permissions set here are not carried across by the sync provider. If a "
                    + "second Mac ever points at this folder, both write the same day-marker "
                    + "and state files and each will report success for work the other did.",
                hint: "Keep the workspace on local disk and publish instead: set "
                    + "output.output_dir to the shared folder (with output.allow_absolute_paths: "
                    + "true) so only finished reports sync."
            ))
        }

        if workspaceProvider == nil, let provider = outputProvider {
            rows.append(DoctorRow(
                id: "cloud.output",
                severity: .pass,
                title: "Reports publish to \(provider.displayName)",
                detail: "Generated reports are written to \(provider.displayName) while the "
                    + "workspace stays on local disk. This is the recommended way to share "
                    + "output with a team.",
                hint: nil
            ))
        }

        if workspaceProvider == nil, outputProvider == nil, let provider = archiveProvider {
            rows.append(DoctorRow(
                id: "cloud.archive",
                severity: .warn,
                title: "Report archive is on \(provider.displayName), reports are not",
                detail: "output.archive_dir points at \(provider.displayName) but "
                    + "output.output_dir does not, so rotated reports leave the machine while "
                    + "current ones stay behind.",
                hint: "Point output.output_dir at the shared folder too, or keep both local."
            ))
        }

        if let provider = backupsProvider {
            rows.append(DoctorRow(
                id: "cloud.backups",
                severity: .warn,
                title: "Backups are on \(provider.displayName)",
                detail: "Automatic pruning of scheduled backups is disabled while the backups "
                    + "folder is synced: ordering there depends on modification dates that the "
                    + "sync provider rewrites, and the folder may hold another Mac's backups. "
                    + "The folder will grow until you remove old backups yourself.",
                hint: "Keep backups/ on local disk to restore automatic retention."
            ))
        }

        if !inputs.conflictCopies.isEmpty {
            let sample = inputs.conflictCopies.prefix(3).joined(separator: ", ")
            let more = inputs.conflictCopies.count > 3
                ? " (+\(inputs.conflictCopies.count - 3) more)" : ""
            rows.append(DoctorRow(
                id: "cloud.conflicts",
                severity: .warn,
                title: "\(inputs.conflictCopies.count) sync-conflict file(s) in the workspace",
                detail: "Files such as \(sample)\(more) are duplicate copies a sync provider "
                    + "created when two machines wrote the same file. They are ignored when "
                    + "reading data, so no report is built from them — but their presence "
                    + "means something else is writing to this workspace.",
                hint: "Delete the duplicates, and make sure only one Mac writes to this folder."
            ))
        }

        return rows
    }

    /// Resolve the cloud-storage inputs for a profile. Path resolution failures
    /// are non-fatal — a workspace whose `output_dir` is rejected has bigger
    /// problems, already reported by other families.
    static func cloudStorageInputs(profile: String) -> CloudStorageInputs {
        let workspace = ProfileService.workspaceURL(for: profile)
        let scanRoots = [
            workspace?.appendingPathComponent("snapshots/summaries", isDirectory: true),
            try? WorkspacePaths.outputDir(for: profile),
        ].compactMap { $0 }
        let conflicts = scanRoots.flatMap { CloudStorage.conflictCopies(in: $0) }

        return CloudStorageInputs(
            workspace: workspace,
            outputDir: try? WorkspacePaths.outputDir(for: profile),
            archiveDir: try? WorkspacePaths.archiveDir(for: profile),
            backupsDir: workspace?.appendingPathComponent("backups", isDirectory: true),
            conflictCopies: conflicts
        )
    }
}
