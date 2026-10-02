import Foundation

/// Rows for a value typed into config.yaml that the app replaced, clamped or ignored. Each says
/// what was typed and what the app uses, so a hand-typed value is never replaced in silence.
/// Warnings only (a key with no effect is a suggestion): a typo must not turn a healthy
/// scheduled run red. Text from the file reaches a row only through `ConfigSchema.displayText`,
/// and a URL never does.
extension ConfigDoctorService {

    /// Reads the file for the one value the decoder drops (`alerts.rules[].lookback_days`).
    static func valueRows(
        profile: String, config: ReportConfig, workspaceRoot: URL? = nil
    ) -> [DoctorRow] {
        let url = try? ConfigService.configURL(for: profile, workspaceRoot: workspaceRoot)
        let raw = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { try? ConfigLoader.rawMapping(fromYAML: $0) } ?? [:]
        return valueRows(config, raw: raw, workspace: url?.deletingLastPathComponent())
    }

    static func valueRows(
        _ config: ReportConfig, raw: [String: Any], workspace: URL? = nil
    ) -> [DoctorRow] {
        var rows = notifyValueRows(config.notify)
        rows += retentionValueRows(config.retention, workspace: workspace)
        rows += sharedWorkspaceValueRows(config.sharedWorkspace)
        rows += limitValueRows(config)
        rows += colourValueRows(config)
        rows += sheetValueRows(config)
        rows += exceptionValueRows(config)
        rows += thresholdValueRows(config)
        rows += customEAValueRows(config)
        rows += alertValueRows(config.alerts, raw: raw)
        rows += noEffectValueRows(config)
        rows += productValueRows(config)
        return rows
    }

    /// The tabs `CSVDashboard.sheetPlan` can write besides one per custom EA; the Jamf-cli tabs
    /// are `SheetID`.
    static let csvSheetNames = [
        "Device Inventory", "Stale Devices", "Security Controls", "Security Agents",
        "Compliance", "Mobile Device Inventory", "Mobile Stale Devices", "Fleet Drift",
        "EA Warnings",
    ]

    // MARK: - Settings the app replaced or clamped

    private static func notifyValueRows(_ notify: NotifyConfig?) -> [DoctorRow] {
        guard let notify else { return [] }
        var rows = [
            choiceRow("notify.provider", typed: notify.provider, of: NotifyConfig.Provider.self,
                      uses: notify.resolvedProvider.rawValue),
            choiceRow("notify.detail", typed: notify.detail, of: NotifyConfig.Detail.self,
                      uses: notify.resolvedDetail.rawValue),
        ].compactMap { $0 }
        if notify.isEnabled, !notify.isUsable {
            let why = notify.resolvedURL.isEmpty ? "is empty" : "does not start with https://"
            rows.append(valueRow(
                "notify.url", "notify.enabled is true but url \(why). The app sends no webhook.",
                "Set url to an https:// address, or set enabled to false."))
        }
        return rows
    }

    private static func retentionValueRows(
        _ retention: RetentionConfig?, workspace: URL?
    ) -> [DoctorRow] {
        guard let retention else { return [] }
        var rows = [
            choiceRow("retention.mode", typed: retention.mode, of: RetentionConfig.Mode.self,
                      uses: retention.resolvedMode.rawValue),
        ].compactMap { $0 }
        if retention.isEnabled, !SnapshotRetentionService.policy(from: retention).isActive {
            rows.append(valueRow(
                "retention.enabled",
                "retention.enabled is true but snapshot_keep_days is \(retention.keepDays) and "
                    + "snapshot_keep_count is \(retention.keepCount), so no snapshot is ever "
                    + "archived or deleted.",
                "Set snapshot_keep_days or snapshot_keep_count above 0, or set enabled to false."))
        }
        if let workspace, let row = archiveDirRow(retention, workspace: workspace) {
            rows.append(row)
        }
        return rows
    }

    /// The sweep falls back to `_archive` for an absolute path outside the workspaces folder.
    private static func archiveDirRow(_ retention: RetentionConfig, workspace: URL) -> DoctorRow? {
        let typed = (retention.resolvedArchiveDir as NSString).expandingTildeInPath
        guard typed.hasPrefix("/") else { return nil }
        let fallback = workspace.appendingPathComponent("_archive", isDirectory: true)
            .standardizedFileURL.path
        let used = SnapshotRetentionService
            .resolvedArchiveRoot(config: retention, workspace: workspace).standardizedFileURL.path
        guard used == fallback, URL(fileURLWithPath: typed).standardizedFileURL.path != fallback
        else { return nil }
        return valueRow(
            "retention.archive_dir",
            "\(shown(retention.resolvedArchiveDir)) is outside the workspaces folder. The app "
                + "archives to _archive in the workspace instead.",
            "Use a folder inside the workspaces folder, or a relative path.")
    }

    private static func sharedWorkspaceValueRows(_ shared: SharedWorkspaceConfig?) -> [DoctorRow] {
        guard let shared else { return [] }
        let hours = Int(shared.minCollectInterval / 3600)
        return [
            clampRow("shared_workspace.claim_ttl_minutes", typed: shared.claimTtlMinutes,
                     used: Int(shared.claimTTL / 60), range: "5 to 720"),
            clampRow("shared_workspace.min_collect_interval_hours",
                     typed: shared.minCollectIntervalHours, used: hours, range: "0 to 168",
                     note: hours == 0 ? ", which turns the freshness check off" : ""),
        ].compactMap { $0 }
    }

    private static func limitValueRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        let skipped = (config.jamfCli?.collectSkip ?? [])
            .filter { ReportEngine.collectSkipKinds([$0]).isEmpty }
        if !skipped.isEmpty {
            rows.append(valueRow(
                "jamf_cli.collect_skip",
                "\(listed(skipped)) cannot be skipped, so collect still runs "
                    + "\(skipped.count == 1 ? "it" : "them") and the stall guard does not apply.",
                "Kinds that can be skipped: "
                    + "\(ReportEngine.skippableKinds.sorted().joined(separator: ", "))."))
        }
        if let output = config.output, let typed = output.keepLatestRuns, typed < 1 {
            rows.append(valueRow(
                "output.keep_latest_runs",
                "\(typed) is below 1. The app keeps the newest \(output.resolvedKeepLatestRuns) "
                    + "report.", "Set a number from 1 up."))
        }
        if let limits = config.html?.sectionLimits {
            rows += [
                clampRow("html.section_limits.protect_alerts", typed: limits.protectAlerts,
                         used: limits.resolvedProtectAlerts, range: "1 to 200"),
                clampRow("html.section_limits.insights_drift_snapshots",
                         typed: limits.insightsDriftSnapshots,
                         used: limits.resolvedInsightsDriftSnapshots, range: "1 to 12"),
            ].compactMap { $0 }
        }
        if let ai = config.ai {
            rows += [
                choiceRow("ai.tier", typed: ai.tier, of: AIConfig.Tier.self,
                          uses: ai.resolvedTier.rawValue),
                choiceRow("ai.reasoning_level", typed: ai.reasoningLevel,
                          of: AIConfig.ReasoningLevel.self,
                          uses: ai.resolvedReasoningLevel.rawValue),
            ].compactMap { $0 }
        }
        return rows
    }

    /// Mirrors what each reader accepts: the HTML report's `sanitizedHexColor`, and the chart
    /// reader's six digits with or without the `#`.
    private static func colourValueRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        if let typed = config.branding?.accentColor?.trimmingCharacters(in: .whitespaces),
           !typed.isEmpty, HtmlReport.sanitizedHexColor(typed, fallback: "").isEmpty {
            rows.append(valueRow(
                "branding.accent_color",
                "\(shown(typed)) is not a hex colour such as #2D5EA2. The HTML report uses "
                    + "#2D5EA2 instead; the Excel workbook writes the value as typed.",
                "Write it as #RRGGBB."))
        }
        for (index, band) in (config.charts?.complianceTrend?.bands ?? []).enumerated() {
            let digits = band.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if digits.count == 6, UInt32(digits, radix: 16) != nil { continue }
            rows.append(valueRow(
                "charts.compliance_trend.bands[\(index)].color",
                "\(shown(band.color)) is not a hex colour such as #4472C4. The chart uses its "
                    + "default palette colour for this band.",
                "Write it as #RRGGBB."))
        }
        return rows
    }

    // MARK: - Values the app ignored

    private static func sheetValueRows(_ config: ReportConfig) -> [DoctorRow] {
        guard let sheets = config.sheets else { return [] }
        let lists = [("only", sheets.only), ("skip", sheets.skip), ("order", sheets.order)]
        if ProfileProductType.detect(from: config).type == .jamfSchool {
            guard lists.contains(where: { !($0.1 ?? []).isEmpty }) else { return [] }
            return [valueRow(
                "sheets", "sheets.only, skip and order do not apply to Jamf School workbooks. "
                    + "The app writes every School sheet.",
                "Remove the sheets block, or use it on a Jamf Pro profile.")]
        }
        let known = Set((SheetID.allCases.map(\.rawValue) + csvSheetNames
            + (config.customEas ?? []).map(\.name)).map { $0.lowercased() })
        return lists.compactMap { key, names in
            let unmatched = (names ?? []).filter { !known.contains($0.lowercased()) }
            guard !unmatched.isEmpty else { return nil }
            return valueRow("sheets.\(key)",
                            "\(listed(unmatched)) matches no sheet, so the app ignores it.",
                            "Names are matched against the tab names, ignoring case.")
        }
    }

    /// The same parse `HtmlReport` uses to mark an exception expired.
    private static func exceptionValueRows(_ config: ReportConfig) -> [DoctorRow] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return (config.exceptions ?? []).enumerated().compactMap { index, exception in
            guard let typed = exception.expiresDate, !typed.isEmpty,
                  day.date(from: typed) == nil else { return nil }
            return valueRow("exceptions[\(index)].expires_date",
                            "\(shown(typed)) is not a yyyy-MM-dd date. The report never marks "
                                + "this exception expired.",
                            "Write it as yyyy-MM-dd, for example 2027-03-31.")
        }
    }

    private static func thresholdValueRows(_ config: ReportConfig) -> [DoctorRow] {
        let limits = config.thresholds ?? ThresholdsConfig()
        let positive: [(key: String, typed: Int?, effect: String)] = [
            ("stale_device_days", limits.staleDeviceDays, "every Mac counts as stale"),
            ("warning_disk_percent", limits.warningDiskPercent,
             "every percentage value counts as over it"),
            ("critical_disk_percent", limits.criticalDiskPercent,
             "every percentage value counts as over it"),
            ("cert_warning_days", limits.certWarningDays,
             "no date is flagged ahead of its expiry"),
            ("profile_error_warning", limits.profileErrorWarning,
             "every profile is highlighted"),
        ]
        var rows = positive.compactMap { key, typed, effect -> DoctorRow? in
            guard let typed, typed <= 0 else { return nil }
            return valueRow("thresholds.\(key)",
                            "\(typed) is not above 0. The app uses it as written, so \(effect).",
                            "Set a number above 0, or remove the key for the default.")
        }
        let (warn, crit) = (limits.resolvedWarningDisk, limits.resolvedCriticalDisk)
        if limits.warningDiskPercent != nil || limits.criticalDiskPercent != nil, warn > crit {
            rows.append(valueRow(
                "thresholds.warning_disk_percent",
                "warning_disk_percent (\(warn)) is above critical_disk_percent (\(crit)), so the "
                    + "warning band never applies.", "Set the warning below the critical one.",
                tag: ".order"))
        }
        for (index, ea) in (config.customEas ?? []).enumerated() where ea.type == .percentage {
            guard ea.warningThreshold != nil || ea.criticalThreshold != nil else { continue }
            let (warn, crit) = (ea.warningThreshold ?? warn, ea.criticalThreshold ?? crit)
            guard warn > crit else { continue }
            rows.append(valueRow(
                "custom_eas[\(index)].warning_threshold",
                "warning_threshold (\(warn)) is above critical_threshold (\(crit)), so the "
                    + "warning band never applies.", "Set the warning below the critical one.",
                tag: ".order"))
        }
        return rows
    }

    /// `true_value` is left out: the period report reads it for any type.
    private static func customEAValueRows(_ config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        for (index, ea) in (config.customEas ?? []).enumerated() {
            let typed: [(key: String, applies: CustomEAConfig.EAType, set: Bool)] = [
                ("warning_threshold", .percentage, ea.warningThreshold != nil),
                ("critical_threshold", .percentage, ea.criticalThreshold != nil),
                ("current_versions", .version, !(ea.currentVersions ?? []).isEmpty),
                ("warning_days", .date, ea.warningDays != nil),
            ]
            for (key, applies, set) in typed where set && ea.type != applies {
                rows.append(valueRow(
                    "custom_eas[\(index)].\(key)",
                    "\(key) applies to \(applies.rawValue) extension attributes, and this one is "
                        + "\(ea.type.rawValue). The app ignores it.",
                    "Move it to a \(applies.rawValue) entry, or remove it."))
            }
        }
        return rows
    }

    private static func alertValueRows(
        _ alerts: AlertsConfig?, raw: [String: Any]
    ) -> [DoctorRow] {
        guard let alerts else { return [] }
        let rules = alerts.rules ?? []
        var rows: [DoctorRow] = []
        if alerts.enabled == nil, !rules.isEmpty {
            rows.append(valueRow(
                "alerts.enabled",
                "alerts.rules lists \(rules.count) rule\(rules.count == 1 ? "" : "s") but "
                    + "alerts.enabled is not set. Alerts are off unless it is true, so no rule "
                    + "runs.",
                "Set enabled: true under alerts, or remove the rules."))
        }
        let typedRules = ((raw["alerts"] as? [String: Any])?["rules"] as? [Any]) ?? []
        for (index, rule) in rules.enumerated()
        where rule.lookbackDays == nil && rule.resolvedComparison == .dropsMoreThan {
            guard index < typedRules.count, let item = typedRules[index] as? [String: Any],
                  let typed = item["lookback_days"], !(typed is NSNull) else { continue }
            rows.append(valueRow(
                "alerts.rules[\(index)].lookback_days",
                "\(shown("\(typed)")) is not a whole number of days. The app uses "
                    + "\(rule.resolvedLookbackDays).",
                "Set lookback_days to a whole number, or remove it."))
        }
        return rows
    }

    /// Keys the decoder reads that nothing else does (`ConfigService` and the Config screen only
    /// edit them). A key at its default says nothing: the app writes those itself.
    private static func noEffectValueRows(_ config: ReportConfig) -> [DoctorRow] {
        func text<Value>(_ value: Value?) -> String? { value.map { "\($0)" } }
        let keys: [(key: String, typed: String?, fallback: String)] = [
            ("jamf_cli.enabled", text(config.jamfCli?.enabled), "true"),
            ("jamf_cli.allow_live_overview", text(config.jamfCli?.allowLiveOverview), "true"),
            ("platform.enabled", text(config.platform?.enabled), "false"),
            ("thresholds.checkin_overdue_days", text(config.thresholds?.checkinOverdueDays), "7"),
            ("thresholds.profile_error_critical",
             text(config.thresholds?.profileErrorCritical), "50"),
            ("charts.os_adoption.enabled", text(config.charts?.osAdoption?.enabled), "true"),
            ("charts.compliance_trend.enabled",
             text(config.charts?.complianceTrend?.enabled), "true"),
        ]
        return keys.compactMap { key, typed, fallback in
            guard let typed, typed != fallback else { return nil }
            return valueRow(key, "This key currently has no effect.",
                            "Nothing reads it, so changing it changes nothing.", severity: .suggest)
        }
    }

    private static func productValueRows(_ config: ReportConfig) -> [DoctorRow] {
        guard config.schoolCli?.isEnabled == true, config.protect?.isEnabled == true else {
            return []
        }
        return [valueRow(
            "school_cli.enabled",
            "school_cli.enabled and protect.enabled are both true. The app collects Jamf School "
                + "only and never runs Protect for this profile.",
            "Set school_cli.enabled to false to collect Jamf Pro and Protect instead.")]
    }

    // MARK: - Row builders

    private static func valueRow(
        _ key: String, _ detail: String, _ hint: String, tag: String = "",
        severity: DoctorSeverity = .warn
    ) -> DoctorRow {
        DoctorRow(id: "config.value.\(key)\(tag)", severity: severity, title: key,
                  detail: detail, hint: hint)
    }

    /// File text, quoted, through the one display helper.
    private static func shown(_ text: String) -> String { "\"\(ConfigSchema.displayText(text))\"" }

    private static func listed(_ names: [String]) -> String {
        let head = names.prefix(5).map(shown).joined(separator: ", ")
        return names.count > 5 ? head + ", and \(names.count - 5) more" : head
    }

    /// A text value that is not one of the enum's cases, read case-insensitively as the app does.
    private static func choiceRow<Choice: RawRepresentable & CaseIterable>(
        _ key: String, typed: String?, of _: Choice.Type, uses: String
    ) -> DoctorRow? where Choice.RawValue == String {
        guard let typed, Choice(rawValue: typed.lowercased()) == nil else { return nil }
        let names = Choice.allCases.map(\.rawValue).joined(separator: ", ")
        return valueRow(key, "\(shown(typed)) is not one of \(names). The app uses \(uses).",
                        "Set it to one of: \(names).")
    }

    /// A number the app clamped into `range`.
    private static func clampRow(
        _ key: String, typed: Int?, used: Int, range: String, note: String = ""
    ) -> DoctorRow? {
        guard let typed, typed != used else { return nil }
        return valueRow(key, "\(typed) is outside \(range). The app uses \(used)\(note).",
                        "Set a value from \(range).")
    }
}
