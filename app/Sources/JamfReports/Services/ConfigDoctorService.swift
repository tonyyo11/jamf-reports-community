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
    /// A button the Config Doctor screen shows on the row; nil for every row but one.
    var action: DoctorAction?
    /// Parts of `detail` that carry a button of their own; empty for every row but one.
    var items: [DoctorRowItem] = []
}

/// One part of a row, such as a single drifted key, with its own button.
struct DoctorRowItem: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    var action: DoctorAction?
}

/// What a row's button does. The screen runs it for the active profile.
enum DoctorAction: Sendable, Equatable {
    /// Re-pin the listed values, each only while config.yaml still holds the value shown.
    case confirmSharedConfig([SharedConfigPin.Drift])
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
/// Validates a profile's `config.yaml` against its cached EA results, surfacing
/// mismatched mappings and structural mistakes. Skips the
/// Python check's jamf-cli auth/command probes and the matplotlib check (charts are
/// native here). The pure `evaluate(...)` seam is the test entry point; `run(...)`
/// loads the on-disk artifacts and calls it.
enum ConfigDoctorService {

    // MARK: - Wiring

    /// Load `config.yaml` and cached EA coverage names for `profile`, then evaluate. Missing artifacts are non-fatal — their
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

        let eaSnapshot = ExtensionAttributeService.load(profile: profile)
        let eaNames = eaSnapshot.coverage.map(\.eaName)

        var rows = evaluate(
            config: config,
            parseError: parseError,
            eaCoverageNames: eaNames,
            eaDefinitionNames: eaSnapshot.definitions.compactMap(\.name)
        )
        rows += unknownKeyRows(profile: profile, workspaceRoot: workspaceRoot)
        rows += readerRows(profile: profile, workspaceRoot: workspaceRoot)
        if let config, parseError == nil {
            rows += profileOwnerRows(profile: profile, config: config)
            rows += protectProfileFolderRows(profile: profile, config: config)
            rows += protectProfileProductRows(config: config, workspace: profile)
            rows += protectSyncedBackupRows(
                ProtectBackup.syncedStorageChoice(profile: profile, config: config))
            rows += proSyncedBackupRows(
                ProBackup.syncedStorageChoice(profile: profile, config: config))
            rows += valueRows(profile: profile, config: config, workspaceRoot: workspaceRoot)
            rows += accuracyRows(config: config, profile: profile)
            rows += securityPolicyRows(profile: profile, config: config)
        }
        rows += organizationLevelRows(profile: profile)
        rows += platformTwinRows(profile: profile)
        rows += sharedConfigRows(profile: profile)
        let workspace = (try? ConfigService.configURL(for: profile, workspaceRoot: workspaceRoot))?
            .deletingLastPathComponent()
        rows += automationFolderRows(workspace: workspace)
        rows += csvInboxRows(workspace: workspace)
        rows += evaluateCloudStorage(cloudStorageInputs(profile: profile, config: config))
        rows += evaluateWorkspaceContinuity(
            workspaceContinuityInputs(profile: profile, config: config))
        return DoctorReport(rows: rows)
    }

    /// `csv-inbox/` is not read since 2.11. A suggestion only, never a warning or failure.
    static func csvInboxRows(workspace: URL?) -> [DoctorRow] {
        guard let workspace,
              let names = try? FileManager.default.contentsOfDirectory(
                atPath: workspace.appendingPathComponent("csv-inbox").path),
              names.contains(where: { !$0.hasPrefix(".") }) else { return [] }
        return [DoctorRow(
            id: "workspace.csv_inbox", severity: .suggest, title: "csv-inbox",
            detail: "csv-inbox is no longer read since 2.11; you can delete it.",
            hint: "Move any export you still need elsewhere, then delete the folder.")]
    }

    // MARK: - Pure evaluator (test seam)

    /// Pure evaluation over already-loaded inputs. Order: parse → custom EAs → structural →
    /// baselines. Passing checks emit `.pass` rows so the doctor shows green confirmations
    /// (like Python's `[ok]` lines).
    static func evaluate(
        config: ReportConfig?,
        parseError: String?,
        eaCoverageNames: [String],
        eaDefinitionNames: [String] = []
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

        var rows = customEAResultRows(
            config, eaCoverageNames: eaCoverageNames, eaDefinitionNames: eaDefinitionNames)
        rows += securityAgentStructuralRows(config)
        rows += structuralRows(config)
        rows += baselineRows(config, eaCoverageNames: eaCoverageNames)
        rows += alertsRows(config)
        return rows
    }

    /// A custom EA's tab is built
    /// from the `ea-results` rows whose name is its `column` (`EASheets`). Never `.fail`: only
    /// fail rows reach the run log, and an EA that is not collected yet is a valid setup.
    private static func customEAResultRows(
        _ config: ReportConfig,
        eaCoverageNames: [String],
        eaDefinitionNames: [String]
    ) -> [DoctorRow] {
        let collected = Set(eaCoverageNames.map { $0.lowercased() })
        let defined = Set(eaDefinitionNames.map { $0.lowercased() })
        return (config.customEas ?? []).compactMap { ea in
            let column = ea.column.trimmingCharacters(in: .whitespaces)
            guard !column.isEmpty else { return nil }
            let id = "custom_ea.\(ea.name).ea_results"
            let title = "EA: \(ea.name)"
            if collected.contains(column.lowercased()) {
                return DoctorRow(id: id, severity: .pass, title: title,
                                 detail: "'\(column)' has collected values.", hint: nil)
            }
            if defined.isEmpty || defined.contains(column.lowercased()) {
                return DoctorRow(
                    id: id, severity: .warn, title: title,
                    detail: "No collected values for '\(column)', so this EA has no sheet.",
                    hint: "Run Collect; a defined extension attribute with no value on any Mac "
                        + "stays empty.")
            }
            return DoctorRow(
                id: id, severity: .warn, title: title,
                detail: "'\(column)' is not an extension attribute defined in Jamf Pro, so "
                    + "this EA has no sheet.",
                hint: "Fix the custom_eas column to match the extension attribute's name.")
        }
    }

    // MARK: - Structural checks

    private static func structuralRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        rows += complianceStructuralRows(config)
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
    /// metric/when, absent/non-finite/negative/oversized threshold — the same criteria as
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
        return thresholdFailure(threshold)
    }

    private static func thresholdFailure(_ threshold: Double) -> String? {
        guard threshold.isFinite, threshold >= 0 else {
            return "threshold \(threshold) is not a valid non-negative number"
        }
        guard threshold <= AlertRule.maxThreshold else {
            return "threshold \(threshold) is above \(Int(AlertRule.maxThreshold)), "
                + "the largest the app accepts"
        }
        return nil
    }

    // MARK: - Unknown keys

    private static let unknownKeyCap = 20

    /// Reads the profile's config.yaml as the decoder sees it, whether or not it decodes: a
    /// misspelled required key is the likeliest reason it does not. Nothing for a file that is
    /// missing or is not YAML.
    static func unknownKeyRows(profile: String, workspaceRoot: URL? = nil) -> [DoctorRow] {
        guard let url = try? ConfigService.configURL(for: profile, workspaceRoot: workspaceRoot),
              let text = try? ConfigLoader.readText(at: url),
              let root = try? ConfigLoader.rawMapping(fromYAML: text)
        else { return [] }
        return unknownKeyRows(ConfigSchema.unknownKeys(in: root))
    }

    /// One warning per unknown key, titled with its key path. The value is never shown: it can
    /// be a webhook URL under a misspelled key. A key the app once wrote and no longer reads
    /// gets a suggestion of its own instead (`retiredKeyRows`), so it is reported once.
    static func unknownKeyRows(_ allKeys: [UnknownKey]) -> [DoctorRow] {
        let keys = allKeys.filter { $0.retiredSince == nil }
        var rows = keys.prefix(unknownKeyCap).enumerated().map { index, key in
            DoctorRow(
                id: "config.unknown_key.\(index)", severity: .warn, title: key.keyPath,
                detail: "The app does not read this key."
                    + (key.suggestion.map { " Did you mean \"\($0)\"?" } ?? ""),
                hint: "Remove it from config.yaml, or check its spelling: keys are case-sensitive."
            )
        }
        if keys.count > unknownKeyCap {
            let more = keys.count - unknownKeyCap
            rows.append(DoctorRow(
                id: "config.unknown_key.more", severity: .warn,
                title: "More keys the app does not read",
                detail: "\(more) more key\(more == 1 ? "" : "s") in config.yaml that the app "
                    + "does not read.",
                hint: "Fix the keys above, then run the check again to see the rest."
            ))
        }
        return rows + retiredKeyRows(allKeys.compactMap { key in
            key.retiredSince.map { (key.keyPath, $0) }
        })
    }

    /// One suggestion per retired key (path, release): nothing is broken, the app just stopped
    /// reading it, and only `.fail` rows reach the run log. The hint says what removes it.
    private static func retiredKeyRows(_ keys: [(path: String, since: String)]) -> [DoctorRow] {
        keys.enumerated().map { index, key in
            let block = key.path.components(separatedBy: ".").first ?? ""
            let hint = ConfigService.retiredKeyRemover(inBlock: block)
                .map { "The next \($0) removes it." } ?? "Delete the line from config.yaml."
            return DoctorRow(
                id: "config.retired_key.\(index)", severity: .suggest, title: key.path,
                detail: "No longer read since \(key.since).", hint: hint)
        }
    }

    // MARK: - What the reader did not take as written

    /// Reads the profile's config.yaml whether or not it decodes: a skipped line can be why it
    /// does not. Nothing for a file that is missing or is not YAML.
    static func readerRows(profile: String, workspaceRoot: URL? = nil) -> [DoctorRow] {
        guard let url = try? ConfigService.configURL(for: profile, workspaceRoot: workspaceRoot),
              let text = try? ConfigLoader.readText(at: url),
              let document = try? YAMLCodec.decode(text),
              let root = try? ConfigLoader.rawMapping(fromYAML: text)
        else { return [] }
        return parseNoteRows(document.parseNotes) + fileReadBooleanRows(root)
    }

    private static let parseNoteCap = 20

    /// One warning per line the reader did not take as written, titled with its line number.
    static func parseNoteRows(_ notes: [YAMLCodec.ParseNote]) -> [DoctorRow] {
        var rows = notes.prefix(parseNoteCap).enumerated().map { index, note in
            DoctorRow(
                id: "config.parse_note.\(index)", severity: .warn,
                title: "config.yaml line \(note.line)",
                detail: note.detail.prefix(1).uppercased() + note.detail.dropFirst() + ".",
                hint: parseNoteHint(note.kind)
            )
        }
        if notes.count > parseNoteCap {
            let more = notes.count - parseNoteCap
            rows.append(DoctorRow(
                id: "config.parse_note.more", severity: .warn,
                title: "More lines the app did not read as written",
                detail: more == 1
                    ? "1 more line in config.yaml was not read as written."
                    : "\(more) more lines in config.yaml were not read as written.",
                hint: "Fix the lines above, then run the check again to see the rest."
            ))
        }
        return rows
    }

    private static func parseNoteHint(_ kind: YAMLCodec.ParseNote.Kind) -> String {
        switch kind {
        case .indentation: "Line it up with the other keys of its block."
        case .noKey: "Write it as key: value, or remove it."
        case .tab: "Replace the tab with spaces."
        case .duplicateKey: "Remove one of the two lines."
        case .blockScalar: "Put the value on the same line, in quotes."
        case .orphanItems: "Put the list under the key it belongs to, or remove it."
        case .unclosedFlow: "Close it on the same line, or put one item per line under the key."
        case .secondDocument: "Remove the --- line; config.yaml holds one document."
        case .nestingTooDeep: "Flatten it; no setting is nested that deep."
        }
    }

    /// true/false keys the decoder does not model, and `html.with_workbook`, `notify.heartbeat`,
    /// `protect.backup_on_synced_storage` and `backup.pro_on_synced_storage`, which it reads as
    /// off for any other value instead of failing the decode.
    /// `output.allow_absolute_paths` also takes yes, on and 1 (`WorkspacePaths.optIn`); the
    /// others take only true and false.
    static func fileReadBooleanRows(_ root: [String: Any]) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        if let value = typedNonBoolean(at: ["output", "allow_absolute_paths"], in: root) {
            switch WorkspacePaths.optIn(value) {
            case true?:
                rows.append(DoctorRow(
                    id: "config.value.output.allow_absolute_paths", severity: .suggest,
                    title: "output.allow_absolute_paths",
                    detail: "\(typedText(value)) opts in, as true does.",
                    hint: "Write true: the rest of config.yaml reads only true and false."))
            case false?: break
            case nil: rows.append(readsAsFalseRow("output.allow_absolute_paths", value))
            }
        }
        // A `backup:` that is not a block of settings reads as an explicit no.
        if let value = ConfigLoader.rawValue(at: ["backup"], in: root),
           !(value is NSNull), !(value is [String: Any]) {
            rows.append(DoctorRow(
                id: "config.value.backup", severity: .warn, title: "backup",
                detail: "\((value as? Bool).map { "\($0)" } ?? typedText(value)) is not a block of "
                    + "settings, so the app reads "
                    + "backup.pro_on_synced_storage as false.",
                hint: "Write backup: with pro_on_synced_storage: true or false under it."))
        }
        let switches = [
            ["html", "track_history"], ["html", "with_workbook"], ["notify", "heartbeat"],
            ["protect", "backup_on_synced_storage"], ["backup", "pro_on_synced_storage"],
        ]
        for path in switches {
            if let value = typedNonBoolean(at: path, in: root) {
                rows.append(readsAsFalseRow(path.joined(separator: "."), value))
            }
        }
        return rows
    }

    /// The value at `path` unless it is absent, null, true or false.
    private static func typedNonBoolean(at path: [String], in root: [String: Any]) -> Any? {
        guard let value = ConfigLoader.rawValue(at: path, in: root),
              !(value is NSNull), !(value is Bool) else { return nil }
        return value
    }

    private static func typedText(_ value: Any) -> String {
        ((value as? String) ?? (value as? Int).map { String($0) })
            .map { "\"\(ConfigSchema.displayText($0))\"" } ?? "This value"
    }

    private static func readsAsFalseRow(_ keyPath: String, _ value: Any) -> DoctorRow {
        DoctorRow(
            id: "config.value.\(keyPath)", severity: .warn, title: keyPath,
            detail: "\(typedText(value)) is not true or false, so the app reads it as false.",
            hint: "Write true or false."
        )
    }

    // MARK: - Security policy (hand-typed values)

    /// Reads what the workspace's `security_policy:` block says that the app did not use as
    /// written. Warnings only: a typo must not turn a healthy scheduled run red.
    static func securityPolicyRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        let policy = config.resolvedSecurityPolicy
        let hardware = (try? WorkspacePaths.dataDir(for: profile))
            .map { HardwareEncryption.index(dataDir: $0, for: policy) } ?? [:]
        return securityPolicyRows(
            issues: SecurityPolicyConfigLoader.issues(profile: profile),
            policy: policy, hardware: hardware)
            + edrAgentRows(policy: policy, agents: config.securityAgents ?? [])
            + scoreFactorRows(config: config)
    }

    /// Listed score factors the score cannot count: an agent no `security_agents` entry names,
    /// a baseline `compliance.baselines` does not have (or mSCP with no baseline), and an empty
    /// list, which scores nothing. A control set to `ignore` is left out by the policy, not
    /// by a mistake, so it is not named.
    static func scoreFactorRows(config: ReportConfig) -> [DoctorRow] {
        let policy = config.resolvedSecurityPolicy
        guard let listed = policy.scoreFactors else { return [] }
        let path = SecurityPolicyConfigLoader.factorsPath
        guard !listed.isEmpty else {
            return [DoctorRow(
                id: "security_policy.score_factors.empty", severity: .warn, title: path,
                detail: "The list is empty, so the security score counts nothing.",
                hint: "Add factors in Config > Scoring, or remove the key to use the defaults.")]
        }
        let kept = Set(config.resolvedScoreFactors.map(\.key))
        return listed.filter { $0.kind.control == nil && !kept.contains($0.key) }
            .enumerated().map { index, factor in
                let name = ConfigSchema.displayText(factor.target ?? "")
                let detail = factor.kind == .agent
                    ? "\"\(name)\" matches no security_agents entry, so it is not scored."
                    : factor.target == nil
                        ? "No compliance.baselines entry is configured, so mSCP is not scored."
                        : "\"\(name)\" matches no compliance.baselines entry, so it is not scored."
                return DoctorRow(
                    id: "security_policy.score_factors.unmatched.\(index)", severity: .warn,
                    title: path, detail: detail,
                    hint: "Write the name exactly as configured, or remove the factor in "
                        + "Config > Scoring.")
            }
    }

    /// `security_policy.edr_agent` names an agent the score would count as EDR; a name that
    /// matches no `security_agents` entry leaves the first agent counting.
    static func edrAgentRows(
        policy: SecurityControlPolicy, agents: [SecurityAgentConfig]
    ) -> [DoctorRow] {
        guard let chosen = policy.edrAgent,
              SecurityScoreInputs.edrAgent(among: agents, chosen: chosen)?.name
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .caseInsensitiveCompare(chosen) != .orderedSame
        else { return [] }
        let counted = SecurityScoreInputs.edrAgent(among: agents, chosen: nil)?.name
        return [DoctorRow(
            id: "security_policy.edr_agent", severity: .warn,
            title: SecurityPolicyConfigLoader.edrAgentPath,
            detail: "\"\(ConfigSchema.displayText(chosen))\" matches no security_agents entry, so "
                + (counted.map { "\"\(ConfigSchema.displayText($0))\" counts as the EDR agent" }
                    ?? "no agent counts as the EDR agent")
                + ".",
            hint: "Write the agent's name exactly as under security_agents, or pick it in "
                + "Config > Scoring."
        )]
    }

    /// One warning per value the app did not use as written, titled with its key path, plus
    /// one when the hardware rule is set but no Mac has hardware facts yet (the value is valid,
    /// so it is no issue). A key the app does not read (an empty `used`) is left to
    /// `unknownKeyRows`, so it is reported once.
    static func securityPolicyRows(
        issues: [SecurityPolicyIssue], policy: SecurityControlPolicy, hardware: [String: Bool]
    ) -> [DoctorRow] {
        var rows = issues.filter { !$0.used.isEmpty }.enumerated().map { index, issue in
            DoctorRow(
                id: "security_policy.issue.\(index)", severity: .warn, title: issue.keyPath,
                detail: securityPolicyDetail(issue), hint: securityPolicyHint(issue)
            )
        }
        if policy.usesHardwareRule, hardware.isEmpty {
            rows.append(DoctorRow(
                id: "security_policy.hardware_facts", severity: .warn,
                title: "security_policy.filevault_off_hardware_encrypted",
                detail: "No hardware information yet — the rule applies after an inventory "
                    + "collect. Until then FileVault off counts at the FileVault level.",
                hint: "Run a collect for this profile."
            ))
        }
        return rows
    }

    private static func securityPolicyDetail(_ issue: SecurityPolicyIssue) -> String {
        if issue.keyPath == SecurityPolicyConfigLoader.edrAgentPath {
            return "Expected the name of a security agent, found \"\(issue.value)\" — "
                + "using \(issue.used)"
        }
        if SecurityPolicyConfigLoader.blockKeyPaths.contains(issue.keyPath) {
            return "Expected a block of settings, found \"\(issue.value)\" — using \(issue.used)"
        }
        if SecurityPolicyConfigLoader.isFactorPath(issue.keyPath) {
            return issue.value.isEmpty
                ? "This entry is \(issue.used)" : "\"\(issue.value)\" — \(issue.used)"
        }
        if SecurityPolicyConfigLoader.isVocabularyPath(issue.keyPath) {
            return securityVocabularyDetail(issue)
        }
        return "\"\(issue.value)\" is not fail, warning or ignore — using \(issue.used)"
    }

    private static func securityVocabularyDetail(_ issue: SecurityPolicyIssue) -> String {
        let list = issue.keyPath.hasPrefix(SecurityPolicyConfigLoader.onValuesPath)
            ? "on_values" : "off_values"
        if issue.used == SecurityPolicyConfigLoader.vocabularyReadAsOff {
            return "\"\(issue.value)\" is listed in both on_values and off_values — "
                + "reading it as off"
        }
        if issue.value.isEmpty { return "An empty value in \(list) is skipped" }
        return "\"\(issue.value)\" in \(list) is not text — skipped"
    }

    private static func securityPolicyHint(_ issue: SecurityPolicyIssue) -> String {
        if issue.keyPath == SecurityPolicyConfigLoader.edrAgentPath {
            return "Write the agent's name as text, or remove the line."
        }
        if SecurityPolicyConfigLoader.blockKeyPaths.contains(issue.keyPath) {
            return "Write it as indented key: value lines in config.yaml, or remove it."
        }
        if SecurityPolicyConfigLoader.isFactorPath(issue.keyPath) {
            return "Fix the entry in config.yaml, or edit the factors in Config > Scoring."
        }
        if SecurityPolicyConfigLoader.isVocabularyPath(issue.keyPath) {
            return issue.used == SecurityPolicyConfigLoader.vocabularyReadAsOff
                ? "Remove it from on_values, or from off_values, in config.yaml."
                : "Write each value as text, such as \"Pass\" (quote a number), or remove it."
        }
        return "Set it to fail, warning or ignore in config.yaml, or remove the line."
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Data-accuracy family (checks 1–4)

extension ConfigDoctorService {

    // MARK: Pure inputs (test seam)

    /// Everything the accuracy checks need, already loaded off `evaluate`'s path so
    /// the pure seam never touches disk. Any field may be nil/empty — each check
    /// degrades to a single info row or no row rather than failing the doctor.
    struct AccuracyInputs: Sendable {
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
            computersCount: loadComputersCount(dataDir: dataDir),
            eaRows: loadNewestEARows(dataDir: dataDir),
            coverageDrift: dataDir.map { EAParseHealthService.coverageDriftOutcome(dataDir: $0) }
        )
        return evaluateAccuracy(config: config, inputs: inputs)
    }

    /// Device count from the newest `computers` snapshot (a bare JSON array). Nil
    /// when the snapshot is absent or not an array.
    private static func loadComputersCount(dataDir: URL?) -> Int? {
        guard let dataDir else { return nil }
        let dir = dataDir.appendingPathComponent("computers", isDirectory: true)
        guard let url = FileManager.newestSnapshotFile(in: dir),
              let data = BoundedFile.readLogged(url, inside: dataDir),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return items.count
    }

    /// Decode the newest `ea-results` snapshot ONCE. Nil when absent/undecodable.
    private static func loadNewestEARows(dataDir: URL?) -> [EAResultRow]? {
        guard let dataDir else { return nil }
        let dir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        guard let url = FileManager.newestSnapshotFile(in: dir),
              let data = BoundedFile.readLogged(url, inside: dataDir) else { return nil }
        return EAResultRow.decodeSnapshot(data).rows
    }

    // MARK: Pure evaluator

    /// Pure over already-loaded inputs. Emits the accuracy family in check order.
    /// Every check degrades gracefully — a missing input drops its rows, never an
    /// error that blocks the doctor.
    static func evaluateAccuracy(config: ReportConfig, inputs: AccuracyInputs) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        rows += reconciliationRows(config: config, inputs: inputs)
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

    // MARK: Check 2 — per-column parse health

    private static func parseHealthRows(config: ReportConfig, inputs: AccuracyInputs) -> [DoctorRow] {
        // Each health carries its assessed type (nil = int-count) for hint wording.
        var healths: [(health: EAParseHealthService.ColumnHealth, type: CustomEAConfig.EAType?)] = []

        if let eaRows = inputs.eaRows {
            func values(of column: String) -> [String] {
                eaRows.filter { $0.eaName?.caseInsensitiveCompare(column) == .orderedSame }
                    .map { $0.value?.stringValue ?? "" }
            }
            // custom_eas assessed against their collected values.
            for ea in config.customEas ?? [] {
                let column = ea.column.trimmingCharacters(in: .whitespaces)
                let found = values(of: column)
                guard !column.isEmpty, !found.isEmpty else { continue }
                healths.append((EAParseHealthService.assess(
                    column: column, values: found, type: ea.type
                ), ea.type))
            }
            // compliance baselines assessed against the ea-results failure-count column.
            for baseline in config.compliance?.resolvedBaselines ?? [] {
                let column = baseline.failuresCountColumn.trimmingCharacters(in: .whitespaces)
                let found = values(of: column)
                guard !column.isEmpty, !found.isEmpty else { continue }
                healths.append((EAParseHealthService.assessIntCount(
                    column: column, values: found, maxValid: baseline.ruleCount
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

// MARK: - Cloud-storage family

/// Inputs for the cloud-storage and shared-workspace checks.
///
/// Split out so every rule below is exercisable without a real synced volume,
/// a second Mac, or a mounted share.
struct CloudStorageInputs: Sendable {
    let workspaceRoot: URL
    let rootValidation: WorkspaceRootStore.Validation
    let rootIsCustom: Bool
    let workspace: URL?
    let outputDir: URL?
    let archiveDir: URL?
    let backupsDir: URL?
    /// Sync-conflict filenames found in the workspace (sampled, not exhaustive).
    let conflictCopies: [String]
    /// Whether multi-machine coordination is active for this workspace.
    let coordinationEnabled: Bool
    /// True when `shared_workspace.enabled` was set explicitly rather than
    /// inferred from the volume. Changes the advice: an explicit `false` on a
    /// synced volume is a deliberate (and risky) choice, not an oversight.
    let coordinationExplicit: Bool
    let minCollectInterval: TimeInterval
    let otherHosts: [SharedWorkspace.HostActivity]
    let claim: SharedWorkspace.Claim?
    let now: Date
    /// The provider syncing a folder. Path-only by default so the rules stay pure; the gather
    /// passes `CloudStorage.syncProvider`, which also finds iCloud Desktop & Documents.
    var providerOf: @Sendable (URL) -> CloudStorage.Provider? = { CloudStorage.provider(for: $0) }
}

extension ConfigDoctorService {

    /// Pure rules for the "Cloud storage" family.
    ///
    /// 2.7.0 changed what these rules are for. Previously a synced workspace
    /// was simply wrong and every row said so. Hosting the workspace on a team
    /// folder is now supported, so the rows describe **which shape is in
    /// effect**, whether the coordination that makes the shape safe is switched
    /// on, and what specifically remains the operator's responsibility. A row
    /// only warns when there is a real exposure, not merely because a sync
    /// provider is involved.
    static func evaluateCloudStorage(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        rootRows(inputs)
            + workspaceShapeRows(inputs)
            + coordinationRows(inputs)
            + publishTargetRows(inputs)
            + conflictRows(inputs)
    }

    // MARK: Workspace root

    private static func rootRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        let path = inputs.workspaceRoot.path

        switch inputs.rootValidation {
        case .missing:
            return [DoctorRow(
                id: "cloud.root",
                severity: .fail,
                title: "Workspace folder is not there",
                detail: "Nothing exists at \(path). On a synced folder this usually means the "
                    + "provider has not finished mounting, you are signed out of it, or the "
                    + "share was renamed. Until it returns, no profile can be read or written.",
                hint: "Open the folder in Finder to confirm it mounts, then reopen the app. "
                    + "To go back to local storage, clear the folder in Settings › Workspace."
            )]
        case .notADirectory:
            return [DoctorRow(
                id: "cloud.root",
                severity: .fail,
                title: "Workspace path is a file",
                detail: "\(path) is a file, so no workspace can live there.",
                hint: "Pick a folder in Settings › Workspace."
            )]
        case .notWritable:
            return [DoctorRow(
                id: "cloud.root",
                severity: .fail,
                title: "Workspace folder is read-only",
                detail: "\(path) cannot be written by your account. On a shared team folder this "
                    + "normally means you have been granted read access rather than edit access.",
                hint: "Ask the folder's owner for edit permission, or point Settings › Workspace "
                    + "at a folder you can write to."
            )]
        case .sensitiveLocation:
            return [DoctorRow(
                id: "cloud.root",
                severity: .fail,
                title: "Workspace folder is in a reserved location",
                detail: "\(path) is a system directory or holds credentials, so it will not be "
                    + "used for fleet data.",
                hint: "Pick a folder under your home directory or a synced team folder."
            )]
        case .notOwned, .groupOrWorldWritable, .hasACL:
            return [DoctorRow(
                id: "cloud.root",
                severity: .fail,
                title: "Workspace folder is open to other accounts",
                detail: "\(path): \(inputs.rootValidation.message ?? "") Device inventory and "
                    + "run logs kept here are exposed to them. The app keeps using this folder "
                    + "until the root is changed, and would refuse it as a new root.",
                hint: "Fix the folder's owner or permissions, or point Settings › Workspace at a "
                    + "folder you own."
            )]
        case .ok:
            guard inputs.rootIsCustom else { return ownershipUncheckedRows(inputs) }
            let provider = inputs.providerOf(inputs.workspaceRoot)
            let where_ = provider.map { "on \($0.displayName)" } ?? "at a custom location"
            return [DoctorRow(
                id: "cloud.root",
                severity: .pass,
                title: "Workspace is \(where_)",
                detail: "Profiles, history and reports are read from and written to \(path).",
                hint: nil
            )] + ownershipUncheckedRows(inputs)
        }
    }

    /// The owner and permission checks are skipped on network and File Provider volumes, which
    /// report modes that say nothing about who can write, so say so instead of staying silent.
    private static func ownershipUncheckedRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        let path = inputs.workspaceRoot.path
        guard WorkspaceRootStore.skipsOwnershipChecks(path) else { return [] }
        return [DoctorRow(
            id: "cloud.root_ownership_unchecked",
            severity: .warn,
            title: "Workspace folder ownership is not checked on this volume",
            detail: "\(path) is on a network or synced volume, where the app cannot read who "
                + "owns the folder or who can write to it. Device inventory and run logs "
                + "kept here are exposed to any account that can write it.",
            hint: "Make sure other accounts cannot write this folder, on the share or in the "
                + "provider's sharing settings."
        )]
    }

    // MARK: Workspace shape

    private static func workspaceShapeRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        guard let workspace = inputs.workspace,
              let provider = inputs.providerOf(workspace) else { return [] }

        // The genuinely risky state: the folder syncs to other people's Macs
        // but nothing is coordinating writes to it.
        guard inputs.coordinationEnabled else {
            let why = inputs.coordinationExplicit
                ? "shared_workspace.enabled is set to false, so coordination is switched off "
                    + "even though this folder syncs."
                : "Coordination could not be enabled automatically for this folder."
            return [DoctorRow(
                id: "cloud.workspace",
                severity: .warn,
                title: "Shared folder with coordination off",
                detail: "\(why) If a second Mac points at this folder, both will collect the "
                    + "same day's inventory, each will report success for work the other did, "
                    + "and neither will wait for the other to finish writing.",
                hint: "Set shared_workspace.enabled: true in config.yaml — or leave it unset so "
                    + "it turns on by itself — unless you are certain this Mac is the only "
                    + "writer."
            )]
        }

        return [DoctorRow(
            id: "cloud.workspace",
            severity: .pass,
            title: "Shared workspace on \(provider.displayName)",
            detail: "Several Macs can report against these tenants and build one shared "
                + "history. \(collectSpacing(inputs.minCollectInterval)) Each run is announced "
                + "with a short claim so two machines do not collect at once.",
            hint: nil
        )] + privacyRow(provider: provider)
    }

    /// Phrase the configured spacing as the number an operator set, not the key
    /// name — zero is a real choice here and reads very differently.
    private static func collectSpacing(_ interval: TimeInterval) -> String {
        guard interval > 0 else {
            return "Freshness checks are off, so every Mac collects on its own schedule."
        }
        let hours = Int(interval / 3600)
        return "A scheduled collect stands down if another Mac collected in the last "
            + "\(hours) hour\(hours == 1 ? "" : "s")."
    }

    /// Always paired with an enabled shared workspace. Coordination solves
    /// collisions; it does nothing about who can read the folder, and that is
    /// the part an operator has to decide deliberately.
    private static func privacyRow(provider: CloudStorage.Provider) -> [DoctorRow] {
        [DoctorRow(
            id: "cloud.privacy",
            severity: .suggest,
            title: "Everyone with folder access can read raw fleet data",
            detail: "Raw snapshots under jamf-cli-data/ and the files in automation/logs/ hold "
                + "device serials, usernames and email addresses in clear text, and config.yaml "
                + "holds any webhook URL you have configured. \(provider.displayName) shares "
                + "those with everyone the folder is shared with; the file permissions this Mac "
                + "sets are not carried across.",
            hint: "Confirm the folder is shared only with people cleared to see device-level "
                + "inventory. To share findings more widely, keep the workspace private and "
                + "point output.output_dir at a second, wider folder so only finished reports "
                + "are published."
        )]
    }

    // MARK: Multi-machine coordination

    private static func coordinationRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        guard inputs.coordinationEnabled else { return [] }
        var rows: [DoctorRow] = []

        rows += peerRows(inputs)
        rows += claimRows(inputs)
        rows += clockSkewRows(inputs)
        return rows
    }

    private static func peerRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        guard !inputs.otherHosts.isEmpty else {
            return [DoctorRow(
                id: "cloud.peers",
                severity: .pass,
                title: "This Mac is the only one writing here",
                detail: "No other machine has recorded a run in this workspace. Coordination is "
                    + "armed and will engage as soon as one does.",
                hint: nil
            )]
        }

        let named = inputs.otherHosts
            .sorted { ($0.lastCollectAt ?? .distantPast) > ($1.lastCollectAt ?? .distantPast) }
            .prefix(4)
            .map { activity -> String in
                guard let at = activity.lastCollectAt else {
                    return "\(activity.host.display) (no collect recorded)"
                }
                let age = ReportEngine.approximateAge(since: at, now: inputs.now)
                return "\(activity.host.display) \(age)"
            }
            .joined(separator: ", ")
        let more = inputs.otherHosts.count > 4 ? " (+\(inputs.otherHosts.count - 4) more)" : ""

        // A mixed-version fleet is worth naming: an older build writing here
        // predates the ordering and pruning guards this one relies on.
        let versions = Set(inputs.otherHosts.map(\.appVersion))
            .subtracting([SharedWorkspace.appVersion])
        let mismatched = versions.subtracting(["unknown"]).sorted()

        var rows = [DoctorRow(
            id: "cloud.peers",
            severity: .pass,
            title: "\(inputs.otherHosts.count) other Mac(s) share this workspace",
            detail: "Last collects: \(named)\(more).",
            hint: nil
        )]

        if !mismatched.isEmpty {
            rows.append(DoctorRow(
                id: "cloud.peerversions",
                severity: .warn,
                title: "Other Macs are running different app versions",
                detail: "This Mac runs \(SharedWorkspace.appVersion); others report "
                    + "\(mismatched.joined(separator: ", ")). Versions before 2.7.0 order "
                    + "snapshots by modification date, which a sync provider rewrites, and "
                    + "prune backups without checking whose they are.",
                hint: "Update every Mac writing to this folder to the same version before "
                    + "relying on the shared history."
            ))
        }
        return rows
    }

    private static func claimRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        guard let claim = inputs.claim else { return [] }
        if claim.host.id == SharedWorkspace.currentHost.id { return [] }

        if claim.isExpired(at: inputs.now) {
            return [DoctorRow(
                id: "cloud.claim",
                severity: .suggest,
                title: "Stale claim left by \(claim.host.display)",
                detail: "\(claim.host.display) started \(claim.operation) "
                    + "\(ReportEngine.approximateAge(since: claim.startedAt, now: inputs.now)) and "
                    + "never released it — usually a Mac that slept or was shut down mid-run. "
                    + "It has expired, so the next run here takes it over automatically.",
                hint: nil
            )]
        }

        return [DoctorRow(
            id: "cloud.claim",
            severity: .pass,
            title: "\(claim.host.display) is running \(claim.operation)",
            detail: "Its claim lasts "
                + "\(ReportEngine.approximateAge(until: claim.expiresAt, now: inputs.now)). "
                + "Scheduled runs on this Mac will stand down until then; Refresh still works "
                + "and will say it is running alongside.",
            hint: nil
        )]
    }

    /// Every coordination decision compares timestamps written by different
    /// machines, so a badly-set clock is not cosmetic here — it decides whether
    /// a collect is skipped as recent or treated as overdue.
    private static func clockSkewRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        let tolerance = SharedWorkspace.clockSkewTolerance
        let ahead = inputs.otherHosts.compactMap { activity -> (String, Date)? in
            guard let at = activity.lastCollectAt,
                  at.timeIntervalSince(inputs.now) > tolerance else { return nil }
            return (activity.host.display, at)
        }
        guard !ahead.isEmpty else { return [] }

        let names = ahead.map(\.0).joined(separator: ", ")
        return [DoctorRow(
            id: "cloud.clockskew",
            severity: .warn,
            title: "Another Mac's clock is ahead of this one",
            detail: "\(names) recorded a collect dated in the future relative to this Mac. "
                + "Freshness checks compare these timestamps, so this Mac may keep standing "
                + "down for a collect that has not actually happened recently.",
            hint: "Turn on Set date and time automatically in System Settings › General › "
                + "Date & Time on every Mac sharing this folder."
        )]
    }

    // MARK: Publish targets

    private static func publishTargetRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        let workspaceProvider = inputs.workspace.flatMap(inputs.providerOf)
        let outputProvider = inputs.outputDir.flatMap(inputs.providerOf)
        let archiveProvider = inputs.archiveDir.flatMap(inputs.providerOf)

        if workspaceProvider == nil, let provider = outputProvider {
            rows.append(DoctorRow(
                id: "cloud.output",
                severity: .pass,
                title: "Reports publish to \(provider.displayName)",
                detail: "Generated reports are written to \(provider.displayName) while the "
                    + "workspace stays on local disk — the narrowest way to share output, since "
                    + "only finished reports leave this Mac.",
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
                    + "current ones stay behind — the opposite of what most people intend.",
                hint: "Point output.output_dir at the shared folder too, or set archive_dir back "
                    + "to a local path."
            ))
        }

        if workspaceProvider != nil || inputs.backupsDir.flatMap(inputs.providerOf) != nil {
            rows.append(DoctorRow(
                id: "cloud.backups",
                severity: .suggest,
                title: "Only this Mac's backups are pruned here",
                detail: "Retention on a shared folder applies to backups this Mac made — each "
                    + "one records which machine produced it. Another Mac's backups, and any "
                    + "made before ownership was recorded, are left alone rather than counted "
                    + "against this machine's retention budget.",
                hint: "Backups from other Macs, and any predating this version, need removing "
                    + "by hand or by running each machine at least once so it prunes its own."
            ))
        }
        return rows
    }

    // MARK: Conflict copies

    private static func conflictRows(_ inputs: CloudStorageInputs) -> [DoctorRow] {
        guard !inputs.conflictCopies.isEmpty else { return [] }
        let sample = inputs.conflictCopies.prefix(3).joined(separator: ", ")
        let more = inputs.conflictCopies.count > 3
            ? " (+\(inputs.conflictCopies.count - 3) more)" : ""

        // With coordination on, conflict copies are expected background noise
        // from overlapping runs rather than evidence of an unknown writer.
        let severity: DoctorSeverity = inputs.coordinationEnabled ? .suggest : .warn
        let cause = inputs.coordinationEnabled
            ? "Two Macs wrote the same file closely enough that the provider kept both copies. "
                + "They are ignored when reading data, so no report is built from them."
            : "A sync provider created these when two machines wrote the same file. They are "
                + "ignored when reading data, but their presence means something other than "
                + "this Mac is writing here."
        let hint = inputs.coordinationEnabled
            ? "Safe to delete. If they keep appearing, raise "
                + "shared_workspace.min_collect_interval_hours so runs overlap less often."
            : "Delete the duplicates, then either turn on shared_workspace.enabled or make sure "
                + "only one Mac writes to this folder."

        return [DoctorRow(
            id: "cloud.conflicts",
            severity: severity,
            title: "\(inputs.conflictCopies.count) sync-conflict file(s) in the workspace",
            detail: "Files such as \(sample)\(more). \(cause)",
            hint: hint
        )]
    }

    // MARK: IO gather

    /// Resolve the cloud-storage inputs for a profile. Path resolution failures
    /// are non-fatal — a workspace whose `output_dir` is rejected has bigger
    /// problems, already reported by other families.
    static func cloudStorageInputs(profile: String, config: ReportConfig? = nil)
        -> CloudStorageInputs {
        let root = ProfileService.workspacesRoot()
        let workspace = ProfileService.workspaceURL(for: profile)
        let scanRoots = [
            workspace?.appendingPathComponent("snapshots/summaries", isDirectory: true),
            workspace?.appendingPathComponent("automation", isDirectory: true),
            try? WorkspacePaths.outputDir(for: profile),
        ].compactMap { $0 }
        let conflicts = scanRoots.flatMap { CloudStorage.conflictCopies(in: $0) }

        let shared = config?.sharedWorkspace ?? SharedWorkspaceConfig()
        // The coordination gate's own rule, so network volumes and sync markers count too.
        let coordinating = workspace.map {
            SharedWorkspace.isEffectivelyShared(workspace: $0, config: config?.sharedWorkspace)
        } ?? shared.isEnabled(workspaceIsSynced: false)

        return CloudStorageInputs(
            workspaceRoot: root,
            rootValidation: WorkspaceRootStore.validate(root),
            rootIsCustom: WorkspaceRootStore.isCustomised(),
            workspace: workspace,
            outputDir: try? WorkspacePaths.outputDir(for: profile),
            archiveDir: try? WorkspacePaths.archiveDir(for: profile),
            backupsDir: workspace?.appendingPathComponent("backups", isDirectory: true),
            conflictCopies: conflicts,
            coordinationEnabled: coordinating,
            coordinationExplicit: shared.enabled != nil,
            minCollectInterval: shared.minCollectInterval,
            otherHosts: coordinating ? SharedWorkspace.otherHosts(profile: profile) : [],
            claim: coordinating ? SharedWorkspace.readClaim(profile: profile) : nil,
            now: Date(),
            providerOf: { CloudStorage.syncProvider(for: $0) }
        )
    }
}

// MARK: - Workspace continuity

/// Inputs for the "did I lose my history?" family. Every other family reports a
/// workspace that is *broken*; this one reports a workspace that is healthy but
/// not the one the operator expected — the state after moving the workspace to a
/// shared folder, where nothing is wrong and everything looks empty.
struct WorkspaceContinuityInputs: Sendable, Equatable {
    /// One candidate workspace found outside the active root.
    struct Elsewhere: Sendable, Equatable {
        let profile: String
        let root: URL
        let summaryCount: Int
    }

    /// Where this profile's history currently lives, and how much of it there is.
    let activeRoot: URL
    let activeSummaryCount: Int
    /// True when the root came from the stored preference rather than the default.
    let rootIsCustom: Bool
    /// True when config.yaml carries operator-authored content — custom EAs,
    /// security agents or compliance baselines. A scaffold-fresh file has none.
    let configIsCustomised: Bool
    /// Workspaces for the same profile found under other roots, richest first.
    let elsewhere: [Elsewhere]
}

extension ConfigDoctorService {

    /// Two checks that fire on a *valid* workspace:
    ///
    /// 1. history for this profile exists somewhere else with more of it, which
    ///    is what a workspace move looks like from the inside;
    /// 2. this workspace is new, so settings are defaults and nothing was lost.
    ///
    /// Both are `.suggest`: nothing is broken, and only `.fail` rows reach the run
    /// log, so neither can turn a healthy scheduled run red.
    static func evaluateWorkspaceContinuity(_ inputs: WorkspaceContinuityInputs) -> [DoctorRow] {
        var rows: [DoctorRow] = []

        // 1 — richer history elsewhere. Only worth saying when the other copy has
        // strictly more, otherwise a stale leftover folder nags forever.
        if let best = inputs.elsewhere.max(by: { $0.summaryCount < $1.summaryCount }),
           best.summaryCount > inputs.activeSummaryCount {
            rows.append(DoctorRow(
                id: "continuity.history-elsewhere",
                severity: .suggest,
                title: "More history for this profile exists in another folder",
                detail: "This workspace has \(inputs.activeSummaryCount) daily "
                    + "summar\(inputs.activeSummaryCount == 1 ? "y" : "ies"); "
                    + "\(best.root.path) has \(best.summaryCount). Trends and every "
                    + "period-over-period figure read only the folder in use, so the "
                    + "older history is not lost — it is simply not being read.",
                hint: "To use it, point Settings › Workspace at that folder, or copy its "
                    + "snapshots/summaries into this workspace."
            ))
        }

        // 2 — a fresh workspace. Deliberately silent once real history exists, and
        // silent when the config is customised: an operator who has configured EAs
        // knows where they are.
        if inputs.activeSummaryCount == 0 && !inputs.configIsCustomised {
            let moved = inputs.rootIsCustom
                ? "This is a new workspace at a folder you chose"
                : "This is a new workspace"
            rows.append(DoctorRow(
                id: "continuity.fresh-workspace",
                severity: .suggest,
                title: "Settings here are defaults",
                detail: "\(moved), so it starts with a scaffold config and no history. "
                    + "Custom extension attributes and thresholds are at their defaults "
                    + "rather than anything you set previously.",
                hint: inputs.rootIsCustom
                    ? "If you moved here from another folder, copy its config.yaml and "
                        + "snapshots/ across — changing the workspace location does not "
                        + "move existing data."
                    : "Set up custom extension attributes and thresholds in Config."
            ))
        }

        return rows
    }

    /// Gather continuity inputs. Scans the default root and, when the active root
    /// differs, the active one — enough to answer "is my history somewhere else"
    /// without walking arbitrary disk.
    static func workspaceContinuityInputs(profile: String, config: ReportConfig?)
        -> WorkspaceContinuityInputs {
        let activeRoot = ProfileService.workspacesRoot()
        let candidateRoots = [activeRoot, WorkspaceRootStore.defaultRoot]
        var seen: Set<String> = []
        var counts: [(URL, Int)] = []
        for root in candidateRoots where seen.insert(root.standardizedFileURL.path).inserted {
            counts.append((root, summaryCount(profile: profile, root: root)))
        }
        let active = counts.first { $0.0.standardizedFileURL == activeRoot.standardizedFileURL }
        let elsewhere = counts
            .filter { $0.0.standardizedFileURL != activeRoot.standardizedFileURL && $0.1 > 0 }
            .map { WorkspaceContinuityInputs.Elsewhere(
                profile: profile, root: $0.0, summaryCount: $0.1) }

        return WorkspaceContinuityInputs(
            activeRoot: activeRoot,
            activeSummaryCount: active?.1 ?? 0,
            rootIsCustom: WorkspaceRootStore.isCustomised(),
            configIsCustomised: isCustomised(config),
            elsewhere: elsewhere
        )
    }

    /// Scaffold-fresh configs have no operator-authored content.
    private static func isCustomised(_ config: ReportConfig?) -> Bool {
        guard let config else { return false }
        if !(config.customEas ?? []).isEmpty { return true }
        if !(config.securityAgents ?? []).isEmpty { return true }
        if !(config.compliance?.baselines ?? []).isEmpty { return true }
        return false
    }

    private static func summaryCount(profile: String, root: URL) -> Int {
        guard ProfileService.isValid(profile) else { return 0 }
        let dir = root
            .appendingPathComponent(ProfileName.pathComponent(profile), isDirectory: true)
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("summary_") && $0.hasSuffix(".json") }.count
    }
}
