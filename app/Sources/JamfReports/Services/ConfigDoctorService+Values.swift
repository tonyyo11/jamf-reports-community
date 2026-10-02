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
        notifyValueRows(config.notify)
            + retentionValueRows(config.retention, workspace: workspace)
            + sharedWorkspaceValueRows(config.sharedWorkspace)
            + limitValueRows(config)
            + colourValueRows(config)
    }

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
