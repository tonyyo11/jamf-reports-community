import Foundation

/// Writes the minimal workspace config.yaml and reads a Jamf Pro CSV export once, to propose
/// Extension Attributes and security agents. No column mapping is read or written.
enum ScaffoldService {

    // MARK: - Public types

    /// Header + sample rows parsed from a CSV, for EA proposal previewing.
    struct CSVSample: Sendable {
        let headers: [String]
        let rows: [[String]]
    }

    // MARK: - Public API

    /// Write a `config.yaml` to `url` holding the proposed EAs as `custom_eas` (the CLI's
    /// one-time CSV import). Nothing else is derived from the CSV.
    /// - Parameters:
    ///   - url: Destination file URL. Parent directory must already exist.
    ///   - eas: Proposals from `proposeEAs`.
    ///   - profile: Profile slug written into `jamf_cli.profile`.
    static func writeConfig(to url: URL, eas: [ProposedEA], profile: String) throws {
        try write(minimalConfigYAML(profile: profile, eas: eas), to: url)
    }

    /// Write the minimal `config.yaml` (jamf-cli data needs no mapping) to `url`.
    /// - Parameters:
    ///   - url: Destination file URL. Parent directory must already exist.
    ///   - profile: Profile slug written into `jamf_cli.profile`.
    static func writeMinimalConfig(to url: URL, profile: String) throws {
        try write(minimalConfigYAML(profile: profile, eas: []), to: url)
    }

    /// The minimal config.yaml plus a Protect-only `profiles:` block, created exclusively: an
    /// existing file is never replaced and a failed create leaves no half-written config.
    static func createProtectOnlyConfig(at url: URL, profile: String) throws {
        let yaml = minimalConfigYAML(profile: profile, eas: [])
            + ProfilesConfigWriter.protectOnlyBlock(login: profile)
        try Data(yaml.utf8).write(to: url, options: .withoutOverwriting)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    private static func write(_ yaml: String, to url: URL) throws {
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        // 0600: config.yaml may embed column names that reflect org EA naming.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Private helpers

    private static func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).lowercased()
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Escape a string for embedding inside a YAML double-quoted scalar.
    /// YAML requires `\` → `\\`, `"` → `\"`, and control chars to be escaped.
    ///
    /// U+2028/U+2029/U+0085/U+000B/U+000C are also neutralized: they are all
    /// members of `CharacterSet.newlines`, which `YAMLCodec`'s parser splits
    /// the document on *before* any quote handling — an unescaped one inside
    /// this scalar would become a real line break at attacker-chosen
    /// indentation, letting a crafted CSV header inject a sibling top-level
    /// key. `YAMLCodec` does not decode `\uXXXX`, so (like `\n`/`\r`/`\t`
    /// above) this is a one-way, structurally-safe escape, not a
    /// round-trippable one.
    static func yamlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
            .replacingOccurrences(of: "\u{000B}", with: "\\u000B")
            .replacingOccurrences(of: "\u{000C}", with: "\\u000C")
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

    static func minimalConfigYAML(profile: String, eas: [ProposedEA]) -> String {
        var lines: [String] = [
            "# config.yaml — minimal workspace config",
            "",
            "jamf_cli:",
            "  data_dir: \"jamf-cli-data\"",
            "  profile: \"\(yamlEscape(profile))\"",
            "  use_cached_data: true",
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
        ]
        if eas.isEmpty {
            lines.append("custom_eas: []")
        } else {
            lines.append("custom_eas:")
            for ea in eas.map(ConfigEAAdopter.customEA(from:)) {
                lines += [
                    "  - name: \"\(yamlEscape(ea.name))\"",
                    "    column: \"\(yamlEscape(ea.column))\"",
                    "    type: \(ea.type)",
                ]
                if !ea.trueValue.isEmpty { lines.append("    true_value: \"\(yamlEscape(ea.trueValue))\"") }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - EA proposal (CSV → custom_eas walkthrough)

    /// Normalized built-in identity/inventory headers that are NEVER EA candidates.
    /// Conservative: when unsure, a header is left OUT of this set so the user can
    /// still see it as a proposal and deselect it.
    static let builtInHeaders: Set<String> = [
        "computer name", "device name", "display name", "hostname", "name",
        "serial number", "serial", "udid", "jss computer id", "jss mobile device id",
        "device id", "asset tag", "model", "model identifier", "processor type",
        "apple silicon", "architecture", "architecture type", "operating system version",
        "os version",
        "build", "last inventory update", "last check-in", "last checkin",
        "last contact", "last enrollment", "enrollment date", "managed", "supervised",
        "ip address", "last reported ip address", "mac address", "wi-fi mac address",
        "bluetooth mac address", "username", "user", "full name", "email address",
        "email", "e-mail", "phone number", "position", "building", "department",
        "dept", "manager", "managed by", "room", "site", "imei", "iccid", "meid",
        "device ownership type", "battery level",
    ]

    /// Propose `custom_eas` candidates from a CSV's headers and sample rows.
    ///
    /// Pure (no I/O) so it is unit-testable. Skips headers already mapped to a
    /// logical column (`mappedHeaders`, normalized compare) and obvious built-in
    /// identity/inventory headers. Each remaining header is title-cased into a
    /// `name`, given its first non-empty sample value, and assigned a guessed type.
    ///
    /// - Parameters:
    ///   - headers: CSV column names.
    ///   - sampleRows: Row cells aligned to `headers` (ragged rows tolerated).
    ///   - mappedHeaders: Headers already mapped to logical fields — excluded.
    /// - Returns: Proposals sorted by column name.
    static func proposeEAs(
        headers: [String],
        sampleRows: [[String]],
        mappedHeaders: Set<String>
    ) -> [ProposedEA] {
        let mappedNorm = Set(mappedHeaders.map(normalizedText))
        var proposals: [ProposedEA] = []

        for (index, header) in headers.enumerated() {
            let norm = normalizedText(header)
            if norm.isEmpty { continue }
            if mappedNorm.contains(norm) { continue }
            if builtInHeaders.contains(norm) { continue }

            let samples = columnSamples(at: index, rows: sampleRows)
            let sampleValue = samples.first(where: { !$0.isEmpty }) ?? ""
            let type = EATypeGuess.guess(header: norm, sampleValue: sampleValue, samples: samples)
            proposals.append(
                ProposedEA(
                    name: titleCased(header),
                    column: header,
                    type: type,
                    sampleValue: sampleValue
                )
            )
        }

        return proposals.sorted { $0.column < $1.column }
    }

    /// Extract a column's cells across the sample rows, trimmed.
    private static func columnSamples(at index: Int, rows: [[String]]) -> [String] {
        rows.compactMap { row in
            guard index < row.count else { return nil }
            return row[index].trimmingCharacters(in: .whitespaces)
        }
    }

    /// Title-case a CSV header into a readable EA name (collapse whitespace,
    /// capitalize each word, preserve acronym-ish all-caps tokens).
    private static func titleCased(_ header: String) -> String {
        let cleaned = header
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let words = cleaned.map { word -> String in
            if word.count > 1, word == word.uppercased() { return word }  // keep acronyms
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        return words.joined(separator: " ")
    }

    /// Read a CSV's header row and up to `maxRows` data rows.
    ///
    /// Reuses ``parseHeaderLine`` (RFC 4180) for each line and strips a UTF-8 BOM.
    /// Thin I/O wrapper; the proposal logic in ``proposeEAs`` stays pure.
    ///
    /// - Parameters:
    ///   - csvURL: CSV file to read.
    ///   - maxRows: Maximum number of data rows to sample (default 50).
    /// - Returns: Parsed headers and sample rows.
    /// - Throws: If the file cannot be read as UTF-8.
    static func readSample(from csvURL: URL, maxRows: Int = 50) throws -> CSVSample {
        let text = try InventoryCSV.readText(csvURL, followLinks: true)

        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerLine = lines.first else {
            return CSVSample(headers: [], rows: [])
        }
        let headers = parseHeaderLine(headerLine)
        let rows = lines.dropFirst().prefix(maxRows).map { parseHeaderLine($0) }
        return CSVSample(headers: headers, rows: Array(rows))
    }
}
