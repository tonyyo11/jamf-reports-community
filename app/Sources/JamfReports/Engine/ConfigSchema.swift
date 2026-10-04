import Foundation

/// A key in config.yaml that the app does not read, with the known key it most likely meant.
/// `keyPath` is safe to show: the unknown key in it has passed `ConfigSchema.displayText`.
struct UnknownKey: Sendable, Equatable {
    let keyPath: String
    let suggestion: String?
    /// The release that stopped reading this key, for one the app once wrote
    /// (`ConfigSchema.retiredKeys`). Such a key has no suggestion.
    var retiredSince: String?

    /// What to say beside the key, or nil when there is nothing to add.
    var note: String? {
        if let retiredSince { return "No longer read since \(retiredSince)." }
        return suggestion.map { "Did you mean \"\($0)\"?" }
    }
}

/// The keys the app reads from config.yaml, taken from the decoder's own `CodingKeys`, so a
/// key the decoder learns is known here without a second list to keep in step.
enum ConfigSchema {

    /// The keys of the mapping at `path`, or of each item when the value there is a list of
    /// mappings (`["custom_eas"]`). Nil when `path` names no mapping the app reads: a scalar,
    /// a list of scalars, or anything under a key the app does not know.
    static func knownKeys(at path: [String]) -> Set<String>? {
        var node = tree
        for key in path {
            guard let child = node.children[key] else { return nil }
            node = child
        }
        return node.keys
    }

    /// Every key in `root` the app does not read, depth first, keys in sorted order. The walk
    /// does not descend into an unknown key, nor into a value of the wrong shape, which the
    /// decoder already rejects by key path.
    static func unknownKeys(in root: [String: Any]) -> [UnknownKey] {
        var found: [UnknownKey] = []
        collect(root, node: tree, at: [], path: "", into: &found)
        return found
    }

    /// Keys the app wrote or documented and no longer reads, by key path, with the release that
    /// stopped. Config Doctor words one as retired rather than unknown, and a save that rewrites
    /// the block holding it removes it (`ConfigService.dropRetiredKeys`). A key whose reader
    /// returns leaves this list.
    static let retiredKeys: [String: String] = [
        "branding.accent_dark": "2.9",
        "charts.os_adoption.enabled": "2.9",
        "jamf_cli.allow_live_overview": "2.9",
        "jamf_cli.enabled": "2.9",
        "platform.enabled": "2.9",
        "thresholds.profile_error_critical": "2.9",
    ]

    /// Names people write instead of a real key, copied from CLAUDE.md's "Actual key names"
    /// table and keyed by the schema path of their mapping. Consulted before edit distance.
    static let misnames: [[String]: [String: String]] = [
        ["columns"]: [
            "os_version": "operating_system", "last_contact": "last_checkin",
            "assigned_user_email": "email",
        ],
        ["jamf_cli"]: ["jamf_profile": "profile"],
        ["security_agents"]: ["installed_value": "connected_value"],
        ["compliance"]: [
            "failed_count_column": "failures_count_column",
            "failed_list_column": "failures_list_column",
        ],
        // The table offers warning_threshold too; a row names one key.
        ["custom_eas"]: [
            "compliant_value": "true_value", "high_threshold": "critical_threshold",
            "min_version": "current_versions", "warn_within_days": "warning_days",
        ],
        ["thresholds"]: ["inactive_device_days": "stale_device_days"],
        ["output"]: ["directory": "output_dir", "max_runs": "keep_latest_runs"],
        ["charts"]: ["snapshot_dir": "historical_csv_dir", "auto_archive": "archive_current_csv"],
    ]

    private static let displayCharacterCap = 60
    /// One character can carry any number of combining marks, so scalars are capped too.
    private static let displayScalarCap = displayCharacterCap * 4

    /// Text taken from config.yaml, safe to show: control and format characters (a pasted
    /// escape sequence, a right-to-left override) and line breaks removed, capped at 60
    /// characters and 240 Unicode scalars. Every screen and row that shows file text uses it.
    static func displayText(_ raw: String) -> String {
        let hidden = CharacterSet.controlCharacters.union(.newlines)
        let kept = Array(raw.unicodeScalars.lazy.filter { !hidden.contains($0) }
            .prefix(displayScalarCap + 1))
        let text = String(String.UnicodeScalarView(kept.prefix(displayScalarCap)))
        guard kept.count > displayScalarCap || text.count > displayCharacterCap else {
            return text
        }
        return String(text.prefix(displayCharacterCap - 1)) + "…"
    }

    // MARK: - The walk

    /// `schemaPath` is the mapping's place in `tree` (no list indices); `path` is what is shown.
    private static func collect(
        _ mapping: [String: Any], node: Node, at schemaPath: [String], path: String,
        into found: inout [UnknownKey]
    ) {
        for key in mapping.keys.sorted() {
            let keyPath = path.isEmpty ? displayText(key) : "\(path).\(displayText(key))"
            guard node.keys.contains(key) else {
                let retiredSince = retiredKeys[(schemaPath + [key]).joined(separator: ".")]
                found.append(UnknownKey(
                    keyPath: keyPath,
                    suggestion: retiredSince != nil ? nil : misnames[schemaPath]?[key]
                        ?? suggestion(for: key, among: node.keys),
                    retiredSince: retiredSince))
                continue
            }
            guard let child = node.children[key] else { continue }
            let childPath = schemaPath + [key]
            if child.isList, let items = mapping[key] as? [Any] {
                for (index, item) in items.enumerated() {
                    guard let itemMapping = item as? [String: Any] else { continue }
                    collect(itemMapping, node: child, at: childPath,
                            path: "\(keyPath)[\(index)]", into: &found)
                }
            } else if !child.isList, let nested = mapping[key] as? [String: Any] {
                collect(nested, node: child, at: childPath, path: keyPath, into: &found)
            }
        }
    }

    /// The one known key within two edits of `key`, compared as written; nil on a tie.
    private static func suggestion(for key: String, among known: Set<String>) -> String? {
        let near = known.compactMap { candidate -> (key: String, distance: Int)? in
            guard abs(candidate.count - key.count) <= 2 else { return nil }
            let distance = editDistance(key, candidate)
            return distance <= 2 ? (candidate, distance) : nil
        }
        guard let best = near.map(\.distance).min() else { return nil }
        let nearest = near.filter { $0.distance == best }
        return nearest.count == 1 ? nearest.first?.key : nil
    }

    /// Levenshtein distance over characters.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let target = Array(rhs)
        var previous = Array(0...target.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            for (column, right) in target.enumerated() {
                current.append(min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (left == right ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[target.count]
    }

    // MARK: - The schema

    /// A mapping the app reads: its keys, and the mappings under them that the app reads too.
    private struct Node: Sendable {
        let keys: Set<String>
        let children: [String: Node]
        /// The value is a list, and each item is a mapping with these keys.
        let isList: Bool

        init<Key: CodingKey & CaseIterable>(
            _ type: Key.Type, also extra: Set<String> = [], list: Bool = false,
            _ children: [String: Node] = [:]
        ) {
            self.init(names: Set(type.allCases.map(\.stringValue)).union(extra),
                      list: list, children)
        }

        init(names: Set<String>, list: Bool = false, _ children: [String: Node] = [:]) {
            keys = names
            self.children = children
            isList = list
        }
    }

    private static let tree = Node(ReportConfig.CodingKeys.self, [
        "columns": Node(ColumnConfig.CodingKeys.self),
        "mobile_columns": Node(MobileColumnConfig.CodingKeys.self),
        "security_agents": Node(SecurityAgentConfig.CodingKeys.self, list: true),
        "jamf_cli": Node(JamfCLIConfig.CodingKeys.self),
        "compliance": Node(ComplianceConfig.CodingKeys.self, [
            "baselines": Node(ComplianceBaselineConfig.CodingKeys.self, list: true),
        ]),
        "custom_eas": Node(CustomEAConfig.CodingKeys.self, list: true),
        "exceptions": Node(ConfigException.CodingKeys.self, list: true),
        "sheets": Node(SheetsConfig.CodingKeys.self),
        "thresholds": Node(ThresholdsConfig.CodingKeys.self),
        // `WorkspacePaths` reads `allow_absolute_paths` from the file, not the decoder.
        "output": Node(OutputConfig.CodingKeys.self, also: ["allow_absolute_paths"]),
        "charts": Node(ChartsConfig.CodingKeys.self, [
            "os_adoption": Node(OSAdoptionConfig.CodingKeys.self),
            "compliance_trend": Node(ComplianceTrendConfig.CodingKeys.self, [
                "bands": Node(ComplianceBandConfig.CodingKeys.self, list: true),
            ]),
            "device_state_trend": Node(DeviceStateTrendConfig.CodingKeys.self),
        ]),
        "branding": Node(BrandingConfig.CodingKeys.self),
        "platform": Node(PlatformConfig.CodingKeys.self),
        "protect": Node(ProtectConfig.CodingKeys.self),
        "school_cli": Node(SchoolCLIConfig.CodingKeys.self),
        "notify": Node(NotifyConfig.CodingKeys.self),
        "alerts": Node(AlertsConfig.CodingKeys.self, [
            "rules": Node(AlertRule.CodingKeys.self, list: true),
        ]),
        "retention": Node(RetentionConfig.CodingKeys.self),
        "shared_workspace": Node(SharedWorkspaceConfig.CodingKeys.self),
        "ai": Node(AIConfig.CodingKeys.self),
        // `HtmlReport` reads `track_history` and `history_file` from the file.
        "html": Node(HTMLReportConfig.CodingKeys.self, also: ["track_history", "history_file"], [
            "section_limits": Node(HTMLSectionLimits.CodingKeys.self),
        ]),
        // A later change decodes `score_weights`, one weight per Security Score metric.
        "security_policy": Node(SecurityControlPolicy.CodingKeys.self, also: ["score_weights"], [
            "controls": Node(SecurityControlPolicy.ControlKeys.self),
            "score_weights": Node(names: [
                "filevault", "sip", "firewall", "edr_agent", "mscp", "xprotect", "cve",
                "secure_boot",
            ]),
        ]),
    ])
}
