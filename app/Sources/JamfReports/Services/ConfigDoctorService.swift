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

    private static let validEATypes: Set<String> =
        ["boolean", "date", "percentage", "text", "version"]

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

        let rows = evaluate(
            config: config,
            parseError: parseError,
            csvHeaders: csvHeaders,
            csvFamily: csvFamily,
            eaCoverageNames: eaNames
        )
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
        rows += requiredColumnRows(config)
        if let headers = csvHeaders {
            rows += csvRows(config, headers: headers, family: csvFamily)
        }
        rows += structuralRows(config)
        rows += baselineRows(config, eaCoverageNames: eaCoverageNames)
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
        let mobile = config.mobileColumns
        for required in requiredMobileFields {
            let value = mobile.flatMap { nonEmpty($0[keyPath: required.path]) }
            rows.append(requiredRow(
                id: "required.mobile_columns.\(required.logical)",
                label: "Mobile \(required.label.lowercased())",
                value: value
            ))
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
        rows += securityAgentStructuralRows(config)
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
            if !validEATypes.contains(ea.type.rawValue) {
                rows.append(DoctorRow(
                    id: "custom_ea.\(ea.name).type", severity: .warn, title: "EA: \(ea.name)",
                    detail: "Unknown type '\(ea.type.rawValue)'.",
                    hint: "Use one of: \(validEATypes.sorted().joined(separator: ", "))."
                ))
            }
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
