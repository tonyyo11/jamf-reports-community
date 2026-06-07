import Foundation

// MARK: - Top-level config

/// Decoded representation of `config.yaml`, matching `DEFAULT_CONFIG` keys exactly.
///
/// All fields are optional at the Swift level to allow partial configs created
/// by `scaffold` or hand-edited by users. `ReportConfig.merged(with:)` folds in
/// defaults before any sheet-generation logic runs.
struct ReportConfig: Decodable, Sendable {
    var columns: ColumnConfig?
    var mobileColumns: MobileColumnConfig?
    var securityAgents: [SecurityAgentConfig]?
    var jamfCli: JamfCLIConfig?
    var compliance: ComplianceConfig?
    var customEas: [CustomEAConfig]?
    var exceptions: [ConfigException]?
    var sheets: SheetsConfig?
    var thresholds: ThresholdsConfig?
    var output: OutputConfig?
    var charts: ChartsConfig?
    var branding: BrandingConfig?
    var platform: PlatformConfig?
    var protect: ProtectConfig?
    var schoolCli: SchoolCLIConfig?
    var notify: NotifyConfig?
    var retention: RetentionConfig?
    var html: HTMLReportConfig?
    /// PR-22 T-3: per-report cadence + preset overrides. Top-level (not
    /// nested under `jamf_cli`) because the GUI's new Cadence tab edits it
    /// directly and the preset choice (`on-prem` / `cloud` / `custom`)
    /// reads more like its own concept than a `jamf_cli` knob.
    /// Absent ⇒ resolver substitutes on-prem defaults (see `CadenceResolver`).
    var collectCadence: CollectCadenceConfig?

    private enum CodingKeys: String, CodingKey {
        case columns
        case mobileColumns = "mobile_columns"
        case securityAgents = "security_agents"
        case jamfCli = "jamf_cli"
        case compliance
        case customEas = "custom_eas"
        case exceptions
        case sheets
        case thresholds
        case output
        case charts
        case branding
        case platform
        case protect
        case schoolCli = "school_cli"
        case notify
        case retention
        case html
        case collectCadence = "collect_cadence"
    }

    /// Produce a config with all optional fields filled in from hardcoded defaults,
    /// mirroring the Python script's `DEFAULT_CONFIG` deep-merge.
    func withDefaults() -> ReportConfig {
        var r = self
        if r.columns == nil { r.columns = ColumnConfig() }
        if r.mobileColumns == nil { r.mobileColumns = MobileColumnConfig() }
        if r.securityAgents == nil { r.securityAgents = [] }
        if r.jamfCli == nil { r.jamfCli = JamfCLIConfig() }
        if r.compliance == nil { r.compliance = ComplianceConfig() }
        if r.customEas == nil { r.customEas = [] }
        if r.sheets == nil { r.sheets = SheetsConfig() }
        if r.thresholds == nil { r.thresholds = ThresholdsConfig() }
        if r.output == nil { r.output = OutputConfig() }
        if r.charts == nil { r.charts = ChartsConfig() }
        if r.branding == nil { r.branding = BrandingConfig() }
        if r.platform == nil { r.platform = PlatformConfig() }
        r.migrateCollectSkipToPerReport()
        return r
    }

    /// PR-22 T-12 + T-13: migrate `jamf_cli.collect_skip` entries to the
    /// new `collect_cadence.per_report: <kind>: never` schema.
    ///
    /// Both keys are read during the transition window so an operator who
    /// hand-edited `collect_skip` (or who runs the Python script on the
    /// same config) sees identical behavior in both engines without
    /// needing to re-scaffold. PR-23's GUI write path stops emitting
    /// `collect_skip` so newly-saved configs are clean.
    ///
    /// Merge rules:
    /// - Underscore/hyphen normalization (`update_status` ≡ `update-status`)
    ///   matches the Python script's PR-16 behavior.
    /// - Existing `per_report` entries WIN over the migration — operators
    ///   who explicitly set `per_report: <kind>: 86400` should not have
    ///   it silently downgraded to `.never` by an old `collect_skip` entry.
    /// - Empty/whitespace entries are dropped silently rather than
    ///   throwing — the YAML can have stray blank list items.
    /// - Logs once per migrated kind via `AppLogger.engine.info`, prefix
    ///   `[migrate]`, so operators see what changed in unified logs.
    private mutating func migrateCollectSkipToPerReport() {
        guard let raw = jamfCli?.collectSkip, !raw.isEmpty else { return }

        let normalized: [String] = raw.compactMap { entry in
            let trimmed = entry
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !normalized.isEmpty else { return }

        var cadence = collectCadence ?? CollectCadenceConfig()
        var perReport = cadence.perReport ?? [:]

        for kind in normalized {
            if perReport[kind] != nil { continue }  // explicit override wins
            perReport[kind] = PerReportCadence(cadence: .never)
            AppLogger.engine.info(
                "[migrate] jamf_cli.collect_skip → per_report: \(kind, privacy: .public): never"
            )
        }
        cadence.perReport = perReport
        collectCadence = cadence
    }
}

// MARK: - columns

/// Maps logical field names → actual CSV column header strings.
/// Key names must match `DEFAULT_CONFIG["columns"]` exactly.
struct ColumnConfig: Decodable, Sendable {
    var computerName: String?
    var serialNumber: String?
    var operatingSystem: String?       // key is `operating_system`, NOT `os_version`
    var lastCheckin: String?            // key is `last_checkin`, NOT `last_contact`
    var department: String?
    var manager: String?
    var email: String?                  // key is `email`, NOT `assigned_user_email`
    var filevault: String?
    var sip: String?
    var firewall: String?
    var gatekeeper: String?
    var secureBoot: String?
    var bootstrapToken: String?
    var diskPercentFull: String?
    var architecture: String?
    var model: String?
    var lastEnrollment: String?
    var mdmExpiry: String?
    var fullName: String?
    var assetTag: String?
    var building: String?
    var position: String?
    var lastLoggedInUser: String?
    var recoveryLock: String?
    var batteryHealth: String?
    var entraSSOStatus: String?
    /// Hardware warranty expiration date column. YAML key: `warranty_expires`.
    var warrantyExpires: String?
    /// Device purchase or acquisition date column. YAML key: `purchase_date`.
    var purchaseDate: String?

    private enum CodingKeys: String, CodingKey {
        case computerName = "computer_name"
        case serialNumber = "serial_number"
        case operatingSystem = "operating_system"
        case lastCheckin = "last_checkin"
        case department
        case manager
        case email
        case filevault
        case sip
        case firewall
        case gatekeeper
        case secureBoot = "secure_boot"
        case bootstrapToken = "bootstrap_token"
        case diskPercentFull = "disk_percent_full"
        case architecture
        case model
        case lastEnrollment = "last_enrollment"
        case mdmExpiry = "mdm_expiry"
        case fullName = "full_name"
        case assetTag = "asset_tag"
        case building
        case position
        case lastLoggedInUser = "last_logged_in_user"
        case recoveryLock = "recovery_lock"
        case batteryHealth = "battery_health"
        case entraSSOStatus = "entra_sso_status"
        case warrantyExpires = "warranty_expires"
        case purchaseDate = "purchase_date"
    }

    /// Return the configured column name for the given logical field, or nil if unset.
    func columnName(for field: ColumnField) -> String? {
        let value: String?
        switch field {
        case .computerName: value = computerName
        case .serialNumber: value = serialNumber
        case .operatingSystem: value = operatingSystem
        case .lastCheckin: value = lastCheckin
        case .department: value = department
        case .manager: value = manager
        case .email: value = email
        case .filevault: value = filevault
        case .sip: value = sip
        case .firewall: value = firewall
        case .gatekeeper: value = gatekeeper
        case .secureBoot: value = secureBoot
        case .bootstrapToken: value = bootstrapToken
        case .diskPercentFull: value = diskPercentFull
        case .architecture: value = architecture
        case .model: value = model
        case .lastEnrollment: value = lastEnrollment
        case .mdmExpiry: value = mdmExpiry
        case .fullName: value = fullName
        case .assetTag: value = assetTag
        case .building: value = building
        case .position: value = position
        case .lastLoggedInUser: value = lastLoggedInUser
        case .recoveryLock: value = recoveryLock
        case .batteryHealth: value = batteryHealth
        case .entraSSOStatus: value = entraSSOStatus
        case .warrantyExpires: value = warrantyExpires
        case .purchaseDate: value = purchaseDate
        }
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Logical column field identifiers, matching `DEFAULT_CONFIG["columns"]` keys in Python.
///
/// This enum is a hub — adding a new case requires edits in five places:
///
/// 1. **This enum** — add the new `case`.
/// 2. **`ColumnConfig.columnName(for:)`** (same file) — add a `case` branch that returns
///    the corresponding `ColumnConfig` property.
/// 3. **`ColumnConfig.CodingKeys`** (same file) — add a `CodingKeys` entry if the raw
///    YAML key name differs from the Swift property name (snake_case vs camelCase).
/// 4. **`CSVDashboard.mappedExtraInventoryFields()`** — add the field if it should appear
///    as an optional column in the Device Inventory sheet.
/// 5. **`CustomizeView.swift`** — add the field if it should appear in the column-picker UI.
///
/// Also add a matching key to `DEFAULT_CONFIG["columns"]` in `jamf-reports-community.py`
/// and document it in `config.example.yaml`. See CLAUDE.md "Config-shape change checklist".
enum ColumnField: String, CaseIterable, Sendable {
    case computerName, serialNumber, operatingSystem, lastCheckin
    case department, manager, email
    case filevault, sip, firewall, gatekeeper, secureBoot, bootstrapToken
    case diskPercentFull, architecture, model, lastEnrollment, mdmExpiry
    case fullName, assetTag, building, position
    case lastLoggedInUser, recoveryLock, batteryHealth, entraSSOStatus
    /// Hardware warranty expiration date. YAML key: `warranty_expires`.
    case warrantyExpires
    /// Device purchase or acquisition date. YAML key: `purchase_date`.
    case purchaseDate
}

// MARK: - mobile_columns

struct MobileColumnConfig: Decodable, Sendable {
    var deviceName: String?
    var serialNumber: String?
    var operatingSystem: String?
    var lastCheckin: String?
    var email: String?
    var model: String?
    var deviceFamily: String?
    var managed: String?
    var supervised: String?

    private enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case serialNumber = "serial_number"
        case operatingSystem = "operating_system"
        case lastCheckin = "last_checkin"
        case email, model
        case deviceFamily = "device_family"
        case managed, supervised
    }
}

// MARK: - security_agents (list, not dict)

struct SecurityAgentConfig: Decodable, Sendable {
    let name: String
    let column: String
    let connectedValue: String  // key is `connected_value`, NOT `installed_value`

    private enum CodingKeys: String, CodingKey {
        case name, column
        case connectedValue = "connected_value"
    }
}

// MARK: - jamf_cli

struct JamfCLIConfig: Decodable, Sendable {
    var enabled: Bool?
    var dataDir: String?
    var profile: String?             // key is `profile`, NOT `jamf_profile`
    var useCachedData: Bool?
    var allowLiveOverview: Bool?
    var requireManifest: Bool?       // PR-10 / threat-model T-11
    /// PR-16 legacy: list of jamf-cli report kinds to skip during collect.
    /// PR-22 T-12 migrates these to `collect_cadence.per_report: <kind>: never`
    /// at load time so the Swift engine reads both keys during the
    /// transition window. The Python script keeps reading the original
    /// key directly. PR-23 GUI saves stop emitting the legacy key.
    var collectSkip: [String]?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case dataDir = "data_dir"
        case profile
        case useCachedData = "use_cached_data"
        case allowLiveOverview = "allow_live_overview"
        case requireManifest = "require_manifest"
        case collectSkip = "collect_skip"
    }

    var resolvedProfile: String { profile?.trimmingCharacters(in: .whitespaces) ?? "" }
    var resolvedDataDir: String { dataDir?.trimmingCharacters(in: .whitespaces) ?? "jamf-cli-data" }
    var isCachedDataEnabled: Bool { useCachedData ?? true }
    var isLiveOverviewAllowed: Bool { allowLiveOverview ?? true }
    var isEnabled: Bool { enabled ?? true }

    /// PR-10 / threat-model T-11: when true, the Swift engine aborts on
    /// snapshot integrity violations (`.mismatch` / `.corrupt`) rather than
    /// warn-and-continue. Default false preserves PR-7's behavior for
    /// users who upgrade without re-scaffolding their config.yaml; new
    /// workspaces seeded by `workspace-init` get `true`.
    var isManifestRequired: Bool { requireManifest ?? false }
}

// MARK: - ComplianceFramework

/// Controlled vocabulary for the `compliance.framework` config key.
///
/// Auditors must select from this list or use `.custom` for non-standard frameworks.
/// String raw values are the display labels rendered in HTML reports and exception lists.
enum ComplianceFramework: String, CaseIterable, Codable, Sendable {
    case nist80053r5Mod   = "NIST 800-53r5 Moderate"
    case nist80053r5High  = "NIST 800-53r5 High"
    case disaSTIGmacOS    = "DISA STIG macOS"
    case cisLevel1        = "CIS Level 1"
    case cisLevel2        = "CIS Level 2"
    case cmmcL2           = "CMMC Level 2"
    case fedRAMPModerate  = "FedRAMP Moderate"
    case custom           = "Custom"

    /// Parse a user-supplied string to a `ComplianceFramework` case.
    ///
    /// Matching is case-insensitive on the raw value. Simplified aliases are also accepted:
    /// - `"nist-800-53"`, `"nist 800-53"` → `.nist80053r5Mod`
    /// - `"stig"`, `"disa-stig"` → `.disaSTIGmacOS`
    /// - `"cis-l1"`, `"cis-level-1"` → `.cisLevel1`
    /// - `"cis-l2"`, `"cis-level-2"` → `.cisLevel2`
    /// - `"cmmc"`, `"cmmc-l2"` → `.cmmcL2`
    /// - `"fedramp"`, `"fedramp-mod"` → `.fedRAMPModerate`
    ///
    /// Returns `nil` when the string does not match any known case or alias.
    static func parse(rawValue: String) -> ComplianceFramework? {
        let normalized = rawValue.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        let lower = normalized.lowercased()

        // Exact match on raw values (case-insensitive)
        for c in allCases {
            if c.rawValue.lowercased() == lower { return c }
        }

        // Simplified aliases
        switch lower {
        case "nist-800-53", "nist 800-53", "nist800-53", "nist80053",
             "nist-800-53r5", "nist 800-53r5 moderate":
            return .nist80053r5Mod
        case "nist-800-53r5-high", "nist 800-53r5 high", "nist80053high":
            return .nist80053r5High
        case "stig", "disa-stig", "disa stig", "disa stig macos":
            return .disaSTIGmacOS
        case "cis-l1", "cis-level-1", "cis level 1", "cis1":
            return .cisLevel1
        case "cis-l2", "cis-level-2", "cis level 2", "cis2":
            return .cisLevel2
        case "cmmc", "cmmc-l2", "cmmc l2", "cmmc level 2":
            return .cmmcL2
        case "fedramp", "fedramp-mod", "fedramp moderate", "fedramp-moderate":
            return .fedRAMPModerate
        case "custom":
            return .custom
        default:
            return nil
        }
    }
}

// MARK: - compliance

/// A single mSCP/STIG baseline entry under `compliance.baselines`.
///
/// `failuresCountColumn` is the EA name whose integer value is the per-device
/// failure count for this baseline. Must match the `ea_name` field in
/// `ea-results` snapshots exactly (case-sensitive).
///
/// `ruleCount` is reserved for future use (e.g. compliance percentage relative
/// to total rules). Nothing reads it in the foundation increment; declare it now
/// so the on-disk config format is stable and parsers can round-trip it without
/// data loss.
struct ComplianceBaselineConfig: Decodable, Sendable {
    var name: String
    var failuresCountColumn: String
    /// Total rule count for this baseline. Reserved — not read by any engine
    /// path in the foundation increment.
    var ruleCount: Int?

    private enum CodingKeys: String, CodingKey {
        case name
        case failuresCountColumn = "failures_count_column"
        case ruleCount = "rule_count"
    }
}

struct ComplianceConfig: Decodable, Sendable {
    var enabled: Bool?
    var failuresCountColumn: String?   // key is `failures_count_column`
    var failuresListColumn: String?    // key is `failures_list_column`
    var baselineLabel: String?
    var framework: String?             // key is `framework`; surfaces in Compliance Posture sheet
    /// Per-baseline list for multi-baseline mSCP/STIG tracking.
    ///
    /// When non-empty, each entry maps a baseline label to the EA column that
    /// carries its per-device failure count. The first entry is the "primary"
    /// baseline: its data drives `compliancePct` in the daily summary and the
    /// Compliance Benchmark trend.
    ///
    /// Backward compat: when absent, `MSCPComplianceService` synthesizes a
    /// single baseline from `failures_count_column` + `baseline_label` (the
    /// pre-baselines config shape). If both are absent the service returns no
    /// real-data result and the proxy remains active.
    var baselines: [ComplianceBaselineConfig]?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case failuresCountColumn = "failures_count_column"
        case failuresListColumn = "failures_list_column"
        case baselineLabel = "baseline_label"
        case framework
        case baselines
    }

    var isEnabled: Bool { enabled ?? false }
    var resolvedLabel: String { baselineLabel?.trimmingCharacters(in: .whitespaces) ?? "Compliance" }
    /// The compliance framework label as configured. Returns empty when no
    /// framework has been chosen. Renderers should treat empty as "no framework
    /// configured" and either omit the label or show "Not configured" — they
    /// should NOT assume any specific framework on the user's behalf.
    var resolvedFramework: String {
        framework?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Parse `framework` against the controlled vocabulary.
    /// Returns `nil` when the value is absent, empty, or does not match any known case.
    var parsedFramework: ComplianceFramework? {
        let raw = framework?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !raw.isEmpty else { return nil }
        return ComplianceFramework.parse(rawValue: raw)
    }

    /// Display label for the framework.
    ///
    /// Prefers the canonical `ComplianceFramework` raw value when the configured string
    /// matches a known case. Falls back to the operator's literal string when it doesn't
    /// match, or `"Not configured"` when no framework has been set.
    var displayFramework: String {
        if let parsed = parsedFramework { return parsed.rawValue }
        let raw = framework?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? "Not configured" : raw
    }

    /// Normalized baseline list for `MSCPComplianceService`.
    ///
    /// Returns `baselines` when non-empty. Otherwise synthesizes a single
    /// entry from the legacy `failures_count_column` + `baseline_label`
    /// fields. Returns `[]` when neither is configured.
    var resolvedBaselines: [ComplianceBaselineConfig] {
        if let list = baselines, !list.isEmpty { return list }
        guard let col = failuresCountColumn,
              !col.trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }
        let label = baselineLabel?.trimmingCharacters(in: .whitespaces)
        return [ComplianceBaselineConfig(
            name: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Compliance",
            failuresCountColumn: col,
            ruleCount: nil
        )]
    }
}

// MARK: - custom_eas (list, not dict)

struct CustomEAConfig: Decodable, Sendable {
    let name: String
    let column: String
    let type: EAType
    var trueValue: String?          // key is `true_value`
    var warningThreshold: Int?      // key is `warning_threshold`
    var criticalThreshold: Int?     // key is `critical_threshold`
    var currentVersions: [String]?  // key is `current_versions` (list)
    var warningDays: Int?            // key is `warning_days`

    enum EAType: String, Decodable, Sendable {
        case boolean, percentage, version, text, date
    }

    private enum CodingKeys: String, CodingKey {
        case name, column, type
        case trueValue = "true_value"
        case warningThreshold = "warning_threshold"
        case criticalThreshold = "critical_threshold"
        case currentVersions = "current_versions"
        case warningDays = "warning_days"
    }
}

// MARK: - sheets

struct SheetsConfig: Decodable, Sendable {
    var only: [String]?
    var skip: [String]?
    /// User-defined tab order. Sheets listed here appear first in the specified order;
    /// remaining sheets append in their default order. Combined with `only`/`skip`:
    /// skipped sheets stay removed; `only` limits to the allowed subset; `order` controls
    /// position within the survivors.
    var order: [String]?

    /// Apply `only`, `skip`, and `order` to a sheet plan.
    ///
    /// - Parameter plan: Ordered pairs of (name, closure) from the dashboard.
    /// - Returns: Reordered and filtered plan ready for sequential execution.
    /// - Note: Names in `order` that don't match any plan entry are silently skipped.
    func applyTo<T>(_ plan: [(name: String, write: T)]) -> [(name: String, write: T)] {
        let skipSet = Set((skip ?? []).map { $0.lowercased() })
        let onlySet = only.map { Set($0.map { $0.lowercased() }) }

        var survivors = plan.filter { entry in
            let lower = entry.name.lowercased()
            if skipSet.contains(lower) { return false }
            if let only = onlySet, !only.contains(lower) { return false }
            return true
        }

        guard let orderedNames = order, !orderedNames.isEmpty else { return survivors }

        let survivorNames = Set(survivors.map { $0.name.lowercased() })
        var result: [(name: String, write: T)] = []

        for name in orderedNames {
            let lower = name.lowercased()
            guard survivorNames.contains(lower) else { continue }
            if let idx = survivors.firstIndex(where: { $0.name.lowercased() == lower }) {
                result.append(survivors.remove(at: idx))
            }
        }
        result += survivors
        return result
    }
}

// MARK: - thresholds

struct ThresholdsConfig: Decodable, Sendable {
    var staleDeviceDays: Int?          // key is `stale_device_days`
    var checkinOverdueDays: Int?
    var criticalDiskPercent: Int?
    var warningDiskPercent: Int?
    var certWarningDays: Int?
    var profileErrorCritical: Int?
    var profileErrorWarning: Int?

    private enum CodingKeys: String, CodingKey {
        case staleDeviceDays = "stale_device_days"
        case checkinOverdueDays = "checkin_overdue_days"
        case criticalDiskPercent = "critical_disk_percent"
        case warningDiskPercent = "warning_disk_percent"
        case certWarningDays = "cert_warning_days"
        case profileErrorCritical = "profile_error_critical"
        case profileErrorWarning = "profile_error_warning"
    }

    var resolvedStaleDays: Int { staleDeviceDays ?? 30 }
    var resolvedCheckinOverdueDays: Int { checkinOverdueDays ?? 7 }
    var resolvedCriticalDisk: Int { criticalDiskPercent ?? 90 }
    var resolvedWarningDisk: Int { warningDiskPercent ?? 80 }
    var resolvedCertWarningDays: Int { certWarningDays ?? 90 }
    var resolvedProfileErrorCritical: Int { profileErrorCritical ?? 50 }
    var resolvedProfileErrorWarning: Int { profileErrorWarning ?? 10 }
}

// MARK: - output

struct OutputConfig: Decodable, Sendable {
    var outputDir: String?          // key is `output_dir`
    var timestampOutputs: Bool?
    var archiveEnabled: Bool?
    var archiveDir: String?
    var keepLatestRuns: Int?        // key is `keep_latest_runs`

    private enum CodingKeys: String, CodingKey {
        case outputDir = "output_dir"
        case timestampOutputs = "timestamp_outputs"
        case archiveEnabled = "archive_enabled"
        case archiveDir = "archive_dir"
        case keepLatestRuns = "keep_latest_runs"
    }

    var resolvedOutputDir: String { outputDir?.trimmingCharacters(in: .whitespaces) ?? "Generated Reports" }
    var isTimestampEnabled: Bool { timestampOutputs ?? true }
    var isArchiveEnabled: Bool { archiveEnabled ?? true }
    var resolvedKeepLatestRuns: Int { keepLatestRuns ?? 10 }
}

// MARK: - charts

struct ChartsConfig: Decodable, Sendable {
    var enabled: Bool?
    var savePng: Bool?
    var embedInXlsx: Bool?
    var historicalCsvDir: String?   // key is `historical_csv_dir`
    var archiveCurrentCsv: Bool?    // key is `archive_current_csv`
    var osAdoption: OSAdoptionConfig?
    var complianceTrend: ComplianceTrendConfig?
    var deviceStateTrend: DeviceStateTrendConfig?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case savePng = "save_png"
        case embedInXlsx = "embed_in_xlsx"
        case historicalCsvDir = "historical_csv_dir"
        case archiveCurrentCsv = "archive_current_csv"
        case osAdoption = "os_adoption"
        case complianceTrend = "compliance_trend"
        case deviceStateTrend = "device_state_trend"
    }

    var isEnabled: Bool { enabled ?? true }
}

struct OSAdoptionConfig: Decodable, Sendable {
    var enabled: Bool?
    var perMajorCharts: Bool?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case perMajorCharts = "per_major_charts"
    }
}

struct ComplianceTrendConfig: Decodable, Sendable {
    var enabled: Bool?
    var bands: [ComplianceBandConfig]?
}

struct ComplianceBandConfig: Decodable, Sendable {
    let label: String
    let minFailures: Int
    let maxFailures: Int
    let color: String

    private enum CodingKeys: String, CodingKey {
        case label
        case minFailures = "min_failures"
        case maxFailures = "max_failures"
        case color
    }
}

struct DeviceStateTrendConfig: Decodable, Sendable {
    var enabled: Bool?
}

// MARK: - branding

struct BrandingConfig: Decodable, Sendable {
    var orgName: String?
    var logoPath: String?
    var accentColor: String?
    var accentDark: String?

    private enum CodingKeys: String, CodingKey {
        case orgName = "org_name"
        case logoPath = "logo_path"
        case accentColor = "accent_color"
        case accentDark = "accent_dark"
    }

    var resolvedOrgName: String { orgName?.trimmingCharacters(in: .whitespaces) ?? "" }
    var resolvedAccentColor: String { accentColor?.trimmingCharacters(in: .whitespaces) ?? "#2D5EA2" }

    /// Accent color validated to `#RRGGBB` or `#RGB` hex format; falls back to `#2D5EA2`.
    var sanitizedAccentColor: String { Self.sanitizeHex(resolvedAccentColor, fallback: "#2D5EA2") }

    /// Dark-mode accent color validated to `#RRGGBB` or `#RGB` hex format; falls back to `#4A7EC8`.
    var sanitizedAccentDark: String {
        let raw = accentDark?.trimmingCharacters(in: .whitespaces) ?? ""
        return Self.sanitizeHex(raw, fallback: "#4A7EC8")
    }

    /// Return `value` if it matches `#RRGGBB` or `#RGB`; otherwise return `fallback`.
    private static func sanitizeHex(_ value: String, fallback: String) -> String {
        let hex3 = #"^#[0-9A-Fa-f]{3}$"#
        let hex6 = #"^#[0-9A-Fa-f]{6}$"#
        if value.range(of: hex3, options: .regularExpression) != nil { return value }
        if value.range(of: hex6, options: .regularExpression) != nil { return value }
        return fallback
    }
}

// MARK: - protect

/// Configuration for Jamf Protect integration.
/// Protect uses a separate GraphQL API with its own OAuth2 credentials,
/// managed by jamf-cli via a named `--profile`. When `enabled` is false
/// (or absent), all protect commands are skipped silently.
struct ProtectConfig: Decodable, Sendable {
    var enabled: Bool?
    var profile: String?
    var dataDir: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, profile
        case dataDir = "data_dir"
    }

    var isEnabled: Bool { enabled ?? false }
    var resolvedProfile: String { profile?.trimmingCharacters(in: .whitespaces) ?? "" }
    var resolvedDataDir: String { dataDir?.trimmingCharacters(in: .whitespaces) ?? "jamf-cli-data/protect" }
}

// MARK: - school_cli

/// Configuration for Jamf School integration.
/// School uses API-key auth (no bearer token), managed by jamf-cli via a named `--profile`.
/// When `enabled` is false (or absent), all school commands are skipped and the profile
/// is treated as Jamf Pro for collect routing. Written by `OnboardingFlow.writeSchoolConfig`.
struct SchoolCLIConfig: Decodable, Sendable {
    var enabled: Bool?
    var profile: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, profile
    }

    var isEnabled: Bool { enabled ?? false }
    var resolvedProfile: String { profile?.trimmingCharacters(in: .whitespaces) ?? "" }
}

// MARK: - notify (opt-in webhook digest)

/// `notify:` block — opt-in scheduled-run webhook digest. OFF by default; the
/// operator must set `enabled: true`, a `provider`, and an `https://` `url`.
struct NotifyConfig: Decodable, Sendable {
    enum Provider: String, Decodable, Sendable, CaseIterable { case teams, slack }

    var enabled: Bool?
    var provider: String?
    var url: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, url
    }

    var isEnabled: Bool { enabled ?? false }
    var resolvedProvider: Provider {
        Provider(rawValue: (provider ?? "teams").lowercased()) ?? .teams
    }
    var resolvedURL: String { url?.trimmingCharacters(in: .whitespaces) ?? "" }
    /// Usable only when enabled AND a usable https URL is present — the gate
    /// every send path checks so an off/misconfigured block silently no-ops.
    var isUsable: Bool { isEnabled && resolvedURL.lowercased().hasPrefix("https://") }
}

// MARK: - retention (snapshot archive/cleanup)

/// `retention:` block — admin-controlled snapshot lifecycle (v2.2.0).
///
/// **OFF by default** — raw jamf-cli snapshots are kept indefinitely so per-device
/// history stays available (the old jamf_reports_cli generated graphs from raw
/// data, not just summaries). When enabled, the default mode is `archive`: old
/// snapshots are MOVED to an archive folder (still on disk; the admin decides
/// whether to trash them), not deleted. `delete` mode removes them outright.
/// Summaries (the durable trend source) are never touched unless
/// `include_summaries` is explicitly true.
struct RetentionConfig: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable, CaseIterable { case archive, delete }

    var enabled: Bool?
    var mode: String?
    var snapshotKeepDays: Int?
    var snapshotKeepCount: Int?
    var includeSummaries: Bool?
    var archiveDir: String?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case snapshotKeepDays = "snapshot_keep_days"
        case snapshotKeepCount = "snapshot_keep_count"
        case includeSummaries = "include_summaries"
        case archiveDir = "archive_dir"
    }

    var isEnabled: Bool { enabled ?? false }
    var resolvedMode: Mode { Mode(rawValue: (mode ?? "archive").lowercased()) ?? .archive }
    /// Snapshots older than this many days are archived/deleted. <= 0 disables
    /// the age rule (keep all by age). Default 365.
    var keepDays: Int { snapshotKeepDays ?? 365 }
    /// Always keep at least this many newest files per kind regardless of age.
    /// 0 = no count floor. Default 0.
    var keepCount: Int { max(0, snapshotKeepCount ?? 0) }
    var includesSummaries: Bool { includeSummaries ?? false }
    var resolvedArchiveDir: String { archiveDir?.trimmingCharacters(in: .whitespaces) ?? "" }
}

// MARK: - exceptions (list, not dict)

/// A single documented compliance exception or waiver entry under `exceptions:` in config.yaml.
///
/// When `expires_date` is present and is a valid ISO-8601 `yyyy-MM-dd` date that has passed,
/// the HTML renderer highlights the row with an "Expired" pill.
struct ConfigException: Decodable, Sendable, Equatable {
    let id: String
    let description: String
    let signedOffBy: String
    let signedOffDate: String
    var expiresDate: String?
    var linkedFinding: String?
    /// Optional NIST/STIG/CIS control identifier (e.g. `"AC-2"`, `"AC-2(1).a"`).
    /// Validated by `ControlID.parse(_:)` for canonical form when surfaced via
    /// `ConfigException.typedControlID` (`ConfigSchema+ControlID.swift`).
    var controlID: String?

    private enum CodingKeys: String, CodingKey {
        case id, description
        case signedOffBy = "signed_off_by"
        case signedOffDate = "signed_off_date"
        case expiresDate = "expires_date"
        case linkedFinding = "linked_finding"
        case controlID = "control_id"
    }

    init(
        id: String,
        description: String,
        signedOffBy: String,
        signedOffDate: String,
        expiresDate: String? = nil,
        linkedFinding: String? = nil,
        controlID: String? = nil
    ) {
        self.id = id
        self.description = description
        self.signedOffBy = signedOffBy
        self.signedOffDate = signedOffDate
        self.expiresDate = expiresDate
        self.linkedFinding = linkedFinding
        self.controlID = controlID
    }
}

// MARK: - html

/// Configuration for the HTML instance report (`html:` top-level block).
struct HTMLReportConfig: Decodable, Sendable {
    var sectionLimits: HTMLSectionLimits?

    private enum CodingKeys: String, CodingKey {
        case sectionLimits = "section_limits"
    }
}

/// Configurable display caps for HTML report sections.
///
/// `protectAlerts` is bounded [1, 200]; values outside this range are clamped
/// silently.  `insightsDriftSnapshots` is bounded [1, 12].
struct HTMLSectionLimits: Decodable, Sendable {
    var protectAlerts: Int?
    var insightsDriftSnapshots: Int?

    private enum CodingKeys: String, CodingKey {
        case protectAlerts = "protect_alerts"
        case insightsDriftSnapshots = "insights_drift_snapshots"
    }

    /// Maximum protect alerts to display per run. Clamped to [1, 200].
    var resolvedProtectAlerts: Int {
        let raw = protectAlerts ?? 25
        if raw < 1 || raw > 200 {
            AppLogger.engine.warning(
                "html.section_limits.protect_alerts=\(raw) out of [1,200]; clamped."
            )
            return max(1, min(200, raw))
        }
        return raw
    }

    /// Number of insight snapshots to compare. Clamped to [1, 12].
    var resolvedInsightsDriftSnapshots: Int {
        let raw = insightsDriftSnapshots ?? 2
        if raw < 1 || raw > 12 {
            AppLogger.engine.warning(
                "html.section_limits.insights_drift_snapshots=\(raw) out of [1,12]; clamped."
            )
            return max(1, min(12, raw))
        }
        return raw
    }
}

// MARK: - platform

struct PlatformConfig: Decodable, Sendable {
    var enabled: Bool?
    var complianceBenchmarks: [String]?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case complianceBenchmarks = "compliance_benchmarks"
    }

    var isEnabled: Bool { enabled ?? false }
    var benchmarkTitles: [String] { complianceBenchmarks?.compactMap { $0.isEmpty ? nil : $0 } ?? [] }
}

// MARK: - YAML loader

/// Minimal YAML-to-Decodable bridge using the existing `YAMLCodec` infrastructure.
/// Falls back to property-by-property scanning via `WorkspacePaths.configValue` for
/// simple scalars, but for full `ReportConfig` deserialization we convert the YAML
/// document to JSON first.
/// Tests written against the older `ConfigDecoder` symbol resolve via this
/// top-level alias. Production callers prefer `ConfigLoader`.
typealias ConfigDecoder = ConfigLoader

enum ConfigLoader {

    enum LoadError: Error, LocalizedError {
        case fileNotFound(URL)
        case encodingError(URL)
        case decodeError(String, Error)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let u): return "config.yaml not found at \(u.path)"
            case .encodingError(let u): return "Could not read config.yaml at \(u.path)"
            case .decodeError(let ctx, let e): return "Config decode failed (\(ctx)): \(e.localizedDescription)"
            }
        }
    }

    /// Decode a `ReportConfig` directly from a YAML string (convenience for tests).
    static func loadFromString(_ yaml: String) throws -> ReportConfig {
        do {
            let document = try YAMLCodec.decode(yaml)
            let jsonData = try yamlDocumentToJSONData(document)
            let decoder = JSONDecoder()
            let config = try decoder.decode(ReportConfig.self, from: jsonData)
            return config.withDefaults()
        } catch {
            throw LoadError.decodeError("<string>", error)
        }
    }

    /// Load and decode `config.yaml` at `url`, merging defaults via `withDefaults()`.
    static func load(from url: URL) throws -> ReportConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.fileNotFound(url)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LoadError.encodingError(url)
        }
        // Convert YAML → JSON via YAMLCodec, then decode with JSONDecoder.
        // This avoids pulling in a full YAML library and re-uses the existing codec.
        do {
            let document = try YAMLCodec.decode(text)
            let jsonData = try yamlDocumentToJSONData(document)
            let decoder = JSONDecoder()
            let config = try decoder.decode(ReportConfig.self, from: jsonData)
            return config.withDefaults()
        } catch let e as LoadError {
            throw e
        } catch {
            throw LoadError.decodeError(url.lastPathComponent, error)
        }
    }

    // MARK: - YAML → JSON conversion

    private static func yamlDocumentToJSONData(_ document: YAMLCodec.YAMLDocument) throws -> Data {
        let jsonObject = nodeToJSONObject(document.root)
        return try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    }

    private static func nodeToJSONObject(_ node: YAMLCodec.YAMLValue) -> Any {
        switch node {
        case .scalar(let scalar):
            return scalarToJSON(scalar)
        case .mapping(let mapping):
            var dict: [String: Any] = [:]
            for entry in mapping.entries {
                dict[entry.key] = nodeToJSONObject(entry.value)
            }
            return dict
        case .sequence(let items):
            return items.map { nodeToJSONObject($0) }
        }
    }

    private static func scalarToJSON(_ scalar: YAMLCodec.YAMLScalar) -> Any {
        switch scalar {
        case .string(let s):
            // Coerce only YAML 1.2 boolean tokens (true/false) and nulls.
            // "yes"/"no" are plain strings in YAML 1.2 and must not be coerced.
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            case "null", "~": return NSNull()
            default: return s
            }
        case .int(let i): return i
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}
