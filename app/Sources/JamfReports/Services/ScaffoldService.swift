import Foundation

/// Native Swift implementation of the CSV column scaffolding logic, porting the
/// Python `COLUMN_HINTS` / `COLUMN_EXCLUDES` / `MOBILE_COLUMN_HINTS` scoring algorithm.
enum ScaffoldService {

    // MARK: - Public types

    struct ScaffoldResult: Sendable {
        /// Detected CSV family (`nil` when headers are ambiguous).
        let family: CSVFamily?
        /// Matched computer column mappings (logical → CSV header).
        let columns: [String: String]
        /// Matched compliance column mappings (logical → CSV header).
        let complianceColumns: [String: String]
        /// Matched mobile column mappings (logical → CSV header).
        let mobileColumns: [String: String]
    }

    // MARK: - Hint tables (ported verbatim from Python COLUMN_HINTS / COLUMN_EXCLUDES)

    private static let columnHints: [String: [String]] = [
        "computer_name":    ["computer name", "device name", "hostname", "name"],
        "serial_number":    ["serial number", "serial", "serialnumber"],
        "operating_system": ["operating system version", "operating system", "macos version"],
        "last_checkin":     [
            "last check-in", "last checkin", "last contact",
            "last inventory update", "checkin",
        ],
        "department":       ["department", "dept"],
        "manager":          ["manager", "managed by", "direct manager"],
        "email":            ["email address", "email", "e-mail"],
        "filevault":        [
            "filevault 2 status", "filevault 2 - status", "filevault status", "filevault",
        ],
        "sip":              ["system integrity protection", "sip"],
        "firewall":         ["firewall", "firewall enabled", "fw"],
        "gatekeeper":       ["gatekeeper"],
        "secure_boot":      ["secure boot level", "secure boot"],
        "bootstrap_token":  ["bootstrap token escrowed", "bootstrap token is escrowed"],
        "disk_percent_full": ["boot drive percentage full", "percentage full", "disk percent full"],
        "architecture":     ["architecture", "arch", "cpu type"],
        "model":            ["model", "hardware model", "device model"],
        "last_enrollment":  ["last enrollment", "enrollment date", "enrolled"],
        "mdm_expiry":       ["mdm profile expiration date", "mdm expiry", "profile expiration date"],
    ]

    private static let columnExcludes: [String: [String]] = [
        "manager":          ["managed", "unmanaged"],
        "secure_boot":      ["external boot"],
        "bootstrap_token":  ["allowed"],
        "disk_percent_full": ["available mb", "capacity mb", "free mb"],
    ]

    private static let complianceHints: [String: [String]] = [
        "failures_count_column": [
            "failed mscp results count", "failed mscp result count",
            "failed results count", "failed rule count", "compliance failures count",
        ],
        "failures_list_column": [
            "failed mscp result list", "failed mscp results list",
            "failed results list", "failed rule list", "compliance failures list",
        ],
    ]

    // MARK: - Mobile hint tables (ported verbatim from Python MOBILE_COLUMN_HINTS / MOBILE_COLUMN_EXCLUDES)

    private static let mobileColumnHints: [String: [String]] = [
        "device_name":      ["display name", "device name"],
        "serial_number":    ["serial number", "serial"],
        "operating_system": ["os version"],
        "last_checkin":     ["last inventory update", "last check-in", "last checkin"],
        "email":            ["email address", "email"],
        "model":            ["model"],
        "device_family":    ["device family"],
        "managed":          ["managed"],
        "supervised":       ["supervised"],
    ]

    private static let mobileColumnExcludes: [String: [String]] = [
        "device_name":      ["computer"],
        "serial_number":    [],
        "operating_system": ["build", "supplemental", "rapid"],
        "last_checkin":     ["enrollment"],
        "email":            [],
        "model":            ["identifier", "number"],
        "device_family":    [],
        "managed":          ["by"],
        "supervised":       [],
    ]

    // MARK: - Scoring

    private static func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).lowercased()
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Score a header/logical field pairing against a hint table and optional exclude table.
    ///
    /// Ported verbatim from Python ``_column_match_score``. Exact matches score
    /// ``200 - hintIndex`` so the hint listed first for a logical field wins exact-match
    /// ties (e.g. "Last Check-in" before "Last Inventory Update"). Prefix, substring, and
    /// reverse-substring tiers stay below any exact match.
    ///
    /// - Parameters:
    ///   - header: CSV column name being scored.
    ///   - logical: Logical field name (key into `hints`/`excludes`).
    ///   - hints: Hint table to score against.
    ///   - excludes: Exclude table; pass `[:]` to skip exclusions.
    /// - Returns: An integer score (0 when below the match threshold).
    private static func matchScore(
        header: String,
        logical: String,
        hints: [String: [String]],
        excludes: [String: [String]]
    ) -> Int {
        let normalized = normalizedText(header)
        var score = 0

        for (index, candidate) in (hints[logical] ?? []).enumerated() {
            let candidateNorm = normalizedText(candidate)
            if normalized == candidateNorm {
                score = max(score, 200 - index)
            } else if normalized.hasPrefix(candidateNorm) {
                score = max(score, 80 + candidateNorm.count)
            } else if normalized.contains(candidateNorm) {
                score = max(score, 60 + candidateNorm.count)
            } else if normalized.count >= 8, candidateNorm.contains(normalized) {
                score = max(score, 40 + normalized.count)
            }
        }

        for blocked in excludes[logical] ?? [] {
            if normalized.contains(normalizedText(blocked)) {
                score -= 80
            }
        }

        return score >= 60 ? score : 0
    }

    private static func columnMatchScore(header: String, logical: String) -> Int {
        matchScore(header: header, logical: logical, hints: columnHints, excludes: columnExcludes)
    }

    private static func complianceMatchScore(header: String, logical: String) -> Int {
        matchScore(header: header, logical: logical, hints: complianceHints, excludes: [:])
    }

    private static func mobileMatchScore(header: String, logical: String) -> Int {
        matchScore(
            header: header,
            logical: logical,
            hints: mobileColumnHints,
            excludes: mobileColumnExcludes
        )
    }

    // MARK: - Public API

    /// Read the first line of `csvURL`, detect the CSV family (computers vs mobile),
    /// fuzzy-match headers to logical column names, and return the best matches.
    ///
    /// For a computer export the `columns` block is populated and `mobileColumns` is
    /// empty. For a mobile export `mobileColumns` is populated and `columns` is empty.
    ///
    /// - Parameters:
    ///   - csvURL: URL of the CSV file whose header row should be parsed.
    ///   - profile: Profile slug (used for logging only; not embedded in the result).
    /// - Returns: `ScaffoldResult` with detected family, matched columns, and
    ///   compliance columns.
    /// - Throws: `CocoaError` or `ScaffoldError` if the file cannot be read.
    static func matchColumns(from csvURL: URL, profile: String) throws -> ScaffoldResult {
        var text = try String(contentsOf: csvURL, encoding: .utf8)
        // Strip UTF-8 BOM if present.
        if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }

        let firstLine = text.components(separatedBy: CharacterSet.newlines).first ?? ""
        let headers = parseHeaderLine(firstLine)

        let family = CSVFamilyDetector.detect(headers: headers)

        if family == .mobile {
            let mobile = matchLogicalFields(
                headers: headers,
                hintTable: mobileColumnHints,
                scorer: mobileMatchScore
            )
            return ScaffoldResult(
                family: family,
                columns: [:],
                complianceColumns: [:],
                mobileColumns: mobile
            )
        }

        // computers or nil (ambiguous) — use computer column tables.
        let columns = matchLogicalFields(
            headers: headers,
            hintTable: columnHints,
            scorer: columnMatchScore
        )
        let compliance = matchLogicalFields(
            headers: headers,
            hintTable: complianceHints,
            scorer: complianceMatchScore
        )
        return ScaffoldResult(
            family: family,
            columns: columns,
            complianceColumns: compliance,
            mobileColumns: [:]
        )
    }

    /// Write a populated `config.yaml` to `url` based on scaffold results.
    ///
    /// Matched columns are placed in the `columns:` section. Unmatched columns
    /// are listed as empty strings. Compliance columns go in `compliance:`.
    /// - Parameters:
    ///   - url: Destination file URL. Parent directory must already exist.
    ///   - result: Column matches returned by `matchColumns(from:profile:)`.
    ///   - profile: Profile slug written into `jamf_cli.profile`.
    static func writeConfig(to url: URL, result: ScaffoldResult, profile: String) throws {
        let yaml = configYAML(result: result, profile: profile)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        // 0600: config.yaml may embed column names that reflect org EA naming.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    /// Write a minimal placeholder `config.yaml` (no CSV mapping) to `url`.
    ///
    /// Used by the "Skip CSV mapping" path in onboarding and workspace-init.
    /// - Parameters:
    ///   - url: Destination file URL. Parent directory must already exist.
    ///   - profile: Profile slug written into `jamf_cli.profile`.
    static func writeMinimalConfig(to url: URL, profile: String) throws {
        let yaml = minimalConfigYAML(profile: profile)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Private helpers

    /// Escape a string for embedding inside a YAML double-quoted scalar.
    /// YAML requires `\` → `\\`, `"` → `\"`, and control chars to be escaped.
    private static func yamlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Minimal RFC 4180 header parser.
    /// Handles quoted fields (which may contain commas or escaped quotes `""`).
    private static func parseHeaderLine(_ line: String) -> [String] {
        let stripped = line.hasSuffix("\r") ? String(line.dropLast()) : line
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var idx = stripped.startIndex

        while idx < stripped.endIndex {
            let ch = stripped[idx]
            if inQuotes {
                if ch == "\"" {
                    let next = stripped.index(after: idx)
                    if next < stripped.endIndex && stripped[next] == "\"" {
                        // Escaped double-quote inside a quoted field ("").
                        current.append("\"")
                        idx = stripped.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    fields.append(current.trimmingCharacters(in: .init(charactersIn: " \t")))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            idx = stripped.index(after: idx)
        }
        fields.append(current.trimmingCharacters(in: .init(charactersIn: " \t")))
        return fields
    }

    private static func matchLogicalFields(
        headers: [String],
        hintTable: [String: [String]],
        scorer: (String, String) -> Int
    ) -> [String: String] {
        var result: [String: String] = [:]
        var usedHeaders = Set<String>()

        let logicalKeys = hintTable.keys.sorted()
        var candidates: [(logical: String, header: String, score: Int)] = []

        for logical in logicalKeys {
            for header in headers {
                let s = scorer(header, logical)
                if s > 0 {
                    candidates.append((logical, header, s))
                }
            }
        }
        // Highest score wins; break ties by logical key alphabetical order (deterministic).
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.logical < rhs.logical
        }
        for candidate in candidates {
            guard result[candidate.logical] == nil,
                  !usedHeaders.contains(candidate.header) else {
                continue
            }
            result[candidate.logical] = candidate.header
            usedHeaders.insert(candidate.header)
        }
        return result
    }

    private static let orderedColumnKeys = [
        "computer_name", "serial_number", "operating_system", "last_checkin",
        "department", "manager", "email",
        "filevault", "sip", "firewall", "gatekeeper", "secure_boot", "bootstrap_token",
        "disk_percent_full", "architecture", "model", "last_enrollment", "mdm_expiry",
    ]

    // Mobile column key order matches Python DEFAULT_CONFIG["mobile_columns"].
    private static let orderedMobileColumnKeys = [
        "device_name", "serial_number", "operating_system", "last_checkin",
        "email", "model", "device_family", "managed", "supervised",
    ]

    private static func configYAML(result: ScaffoldResult, profile: String) -> String {
        let isMobile = result.family == .mobile
        var lines: [String] = [
            "# config.yaml — generated by Jamf Reports scaffold",
            "# Edit column values to match your Jamf Pro CSV export headers.",
            "",
            "jamf_cli:",
            "  data_dir: \"jamf-cli-data\"",
            "  profile: \"\(yamlEscape(profile))\"",
            "  use_cached_data: true",
            "  allow_live_overview: true",
            "",
            "columns:",
        ]

        // For a mobile export all computer columns are left empty (mirrors Python behavior).
        for key in orderedColumnKeys {
            let value = isMobile ? "" : yamlEscape(result.columns[key] ?? "")
            lines.append("  \(key): \"\(value)\"")
        }

        lines += [
            "",
            "mobile_columns:",
        ]
        for key in orderedMobileColumnKeys {
            let value = isMobile ? yamlEscape(result.mobileColumns[key] ?? "") : ""
            lines.append("  \(key): \"\(value)\"")
        }

        // Compliance block is only meaningful for computer exports.
        lines += [
            "",
            "compliance:",
        ]
        let countCol = yamlEscape(result.complianceColumns["failures_count_column"] ?? "")
        let listCol  = yamlEscape(result.complianceColumns["failures_list_column"] ?? "")
        lines.append("  failures_count_column: \"\(countCol)\"")
        lines.append("  failures_list_column: \"\(listCol)\"")

        lines += [
            "",
            "thresholds:",
            "  stale_device_days: 30",
            "",
            "output:",
            "  output_dir: \"Generated Reports\"",
            "  timestamp_outputs: true",
            "  archive_enabled: true",
            "  keep_latest_runs: 10",
            "",
            "charts:",
            "  enabled: true",
            "  save_png: true",
            "  embed_in_xlsx: true",
            "",
            "security_agents: []",
            "custom_eas: []",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func minimalConfigYAML(profile: String) -> String {
        var lines: [String] = [
            "# config.yaml — minimal workspace config (no CSV mapping)",
            "# Fill in column values once you have a Jamf Pro CSV export.",
            "",
            "jamf_cli:",
            "  data_dir: \"jamf-cli-data\"",
            "  profile: \"\(yamlEscape(profile))\"",
            "  use_cached_data: true",
            "  allow_live_overview: true",
            "",
            "columns:",
        ]
        for key in orderedColumnKeys {
            lines.append("  \(key): \"\"")
        }
        lines += ["", "mobile_columns:"]
        for key in orderedMobileColumnKeys {
            lines.append("  \(key): \"\"")
        }
        lines += [
            "",
            "compliance:",
            "  failures_count_column: \"\"",
            "  failures_list_column: \"\"",
            "",
            "thresholds:",
            "  stale_device_days: 30",
            "",
            "output:",
            "  output_dir: \"Generated Reports\"",
            "  timestamp_outputs: true",
            "  archive_enabled: true",
            "  keep_latest_runs: 10",
            "",
            "charts:",
            "  enabled: true",
            "  save_png: true",
            "  embed_in_xlsx: true",
            "",
            "security_agents: []",
            "custom_eas: []",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}
