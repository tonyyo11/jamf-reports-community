import Foundation

// MARK: - Report output types

/// The set of report formats the unified Generate sheet can produce.
enum GenerateOutputType: String, CaseIterable, Hashable, Sendable {
    case xlsx = "XLSX"
    case html = "HTML"
    case pdf  = "PDF"
    case csv  = "CSV"

    var description: String {
        switch self {
        case .xlsx: "Full data, all sheets"
        case .html: "Executive summary, browser"
        case .pdf:  "Paginated audit artifact"
        case .csv:  "Wide inventory export"
        }
    }

    var icon: String {
        switch self {
        case .xlsx: "tablecells"
        case .html: "safari"
        case .pdf:  "doc.richtext"
        case .csv:  "doc.plaintext"
        }
    }
}

// MARK: - Workspace / org

struct Org: Sendable {
    let name: String
    let short: String
    let jamfURL: String
    let profile: String
    let apiClient: String
    let workspaceRoot: String
}

// MARK: - API scope

/// Tracks the privilege level granted to this profile's API client.
/// Defaults to `.limited` until the admin explicitly elevates the profile.
/// Gating destructive operations on this value is deferred to W22+.
enum APIScope: String, Codable, CaseIterable, Sendable {
    case fullAdmin
    case limited

    var displayName: String {
        switch self {
        case .fullAdmin: "Full Admin"
        case .limited:   "Limited"
        }
    }
}

// MARK: - jamf-cli profile

struct JamfCLIProfile: Identifiable, Sendable {
    enum Status: String, Sendable { case ok, idle, error }
    var id: String { name }
    let name: String
    let url: String
    let schedules: Int
    let status: Status
    var authMethod: String = ""
    var isDefault: Bool = false
}

// MARK: - Schedules

// MARK: - Multi-profile target

struct MultiTarget: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        case all
        case filter(String)
        case list([String])
    }

    let scope: Scope
    var sequential: Bool = false

    var cliFlags: [String] {
        switch scope {
        case .all:           return []
        case .filter(let g): return ["--filter", g]
        case .list(let ps):  return ["--profiles", ps.joined(separator: ",")]
        }
    }

    var displayLabel: String {
        switch scope {
        case .all:           return "All profiles"
        case .filter(let g): return "~\(g)"
        case .list(let ps):  return "\(ps.count) profile\(ps.count == 1 ? "" : "s")"
        }
    }

    /// Profile names embedded in the target. Used by CLIBridge.runMulti to
    /// re-validate against `ProfileService.isValid` before invoking jamf-cli
    /// (B-02 defense-in-depth).
    var allProfileNames: [String] {
        switch scope {
        case .all, .filter:  return []
        case .list(let ps):  return ps
        }
    }
}

// MARK: - Schedule

struct Schedule: Identifiable, Sendable {
    enum RunMode: String, Sendable, CaseIterable, Identifiable {
        case snapshotOnly  = "snapshot-only"
        case jamfCLIOnly   = "jamf-cli-only"
        case jamfCLIFull   = "jamf-cli-full"
        case csvAssisted   = "csv-assisted"
        /// v2.2.0: scheduled `jamf-cli pro backup` — exports configuration
        /// objects into the workspace's backups/ folder. No collect, no report.
        case backup        = "backup"
        var id: String { rawValue }

        var displayTitle: String {
            switch self {
            case .snapshotOnly: "Refresh data only"
            case .jamfCLIOnly: "Generate from cached data"
            case .jamfCLIFull: "Refresh + Generate"
            case .csvAssisted: "Refresh + Generate (CSV required)"
            case .backup: "Configuration Backup"
            }
        }

        var displayDescription: String {
            switch self {
            case .snapshotOnly:
                "Runs jamf-cli pro collect, archives JSON snapshots, and updates the Trends summary. Does NOT generate a workbook. Use this when you want fresh data for trend tracking but don't need a report delivered."
            case .jamfCLIOnly:
                "Generates a workbook from the latest cached jamf-cli data. Does NOT collect fresh data first. Use this for a fast re-render after a recent collect — for example, after editing config.yaml or templates."
            case .jamfCLIFull:
                "Runs collect to refresh jamf-cli data, then generates a workbook. No CSV input. Use this for a self-contained scheduled run that does not depend on a CSV export."
            case .csvAssisted:
                "Runs collect, then combines the newest CSV in csv-inbox/ with cached jamf-cli data. The run fails if no CSV is available — use this when CSV data is required (e.g. for custom inventory columns jamf-cli can't reach)."
            case .backup:
                "Runs jamf-cli pro backup to export Jamf Pro configuration objects (policies, profiles, scripts, groups) into the workspace's backups folder. Keeps the last 10 scheduled backups. No data collection, no report."
            }
        }

        /// Default `CollectionTier` set for this mode (PR-23 T-17, ADR
        /// mode → tier-set table). `snapshot-only` narrows to Refresh —
        /// it's the cheap-KPI schedule. The two generate modes default to
        /// all tiers because the workbook needs every data source. The
        /// user can override per-schedule in the form.
        ///
        /// `jamf-cli-only` does not collect at all, so its tier set is
        /// moot — it returns all tiers as a harmless default; the form
        /// hides the tier picker for this mode. `backup` never collects;
        /// its empty tier set keeps the tier picker hidden too.
        var defaultTiers: Set<CollectionTier> {
            switch self {
            case .snapshotOnly:
                return [.refresh]
            case .jamfCLIOnly, .jamfCLIFull, .csvAssisted:
                return Set(CollectionTier.allCases)
            case .backup:
                return []
            }
        }

        /// Whether the LaunchAgent for this mode should set `RunAtLoad`.
        ///
        /// The collect modes (which gather jamf-cli data) run at login so a Mac
        /// that was asleep or logged out at the scheduled time catches up its
        /// missed collection as soon as the user logs in. This is safe because
        /// `ReportEngine.collect` is idempotent per its cadence — a non-forced
        /// collect skips every kind that isn't due, so repeated logins on the
        /// same day do no redundant work; only a genuinely-missed collect runs.
        ///
        /// `jamf-cli-only` (re-render from cache) and `backup` return false —
        /// regenerating a workbook or cutting a `pro backup` at every login is
        /// pure churn with no freshness benefit; a missed one simply runs on its
        /// next scheduled fire.
        var runsAtLoad: Bool {
            switch self {
            case .snapshotOnly, .jamfCLIFull, .csvAssisted: true
            case .jamfCLIOnly, .backup: false
            }
        }
    }
    enum LastStatus: String, Sendable, CaseIterable {
        case ok, warn, fail, partial

        /// VoiceOver label for a status pill describing the last run outcome.
        var accessibilityLabel: String {
            switch self {
            case .ok:      "Last run status: OK"
            case .warn:    "Last run status: Warning"
            case .fail:    "Last run status: Failed"
            case .partial: "Last run status: Partial"
            }
        }
    }

    /// VoiceOver label for this schedule's last-run status pill.
    var accessibilityStatusLabel: String { lastStatus.accessibilityLabel }

    var id: String { launchAgentLabel ?? "\(profile)/\(name)" }
    var name: String
    var profile: String
    var schedule: String
    var cadence: String
    var mode: RunMode
    var next: String
    var last: String
    var lastStatus: LastStatus
    var artifacts: [String]
    var enabled: Bool
    var launchAgentLabel: String? = nil
    var multiTarget: MultiTarget? = nil
    /// Which `CollectionTier`s this schedule's collect step fetches (PR-23
    /// T-17). `nil` means "not specified" — legacy plists written before
    /// PR-23 omit the `--tiers` flag, and `main.swift` defaults a missing
    /// value to all tiers so their behavior is unchanged.
    var tiers: Set<CollectionTier>? = nil
    /// Profiles excluded from a multi-profile (`--all-profiles`) run. Emitted
    /// as `--exclude-profiles <csv>` by `nativeMultiWrite` so the managed
    /// freshness/scan agents can skip a dummy/test tenant. Empty/nil → no flag
    /// (run-time discovery picks up every profile). Ignored for single-profile
    /// schedules.
    var excludedProfiles: [String]? = nil

    var isMulti: Bool { multiTarget != nil }
    var profileDisplayLabel: String { multiTarget?.displayLabel ?? profile }
}

// MARK: - OS distribution

struct OSDistribution: Identifiable, Sendable {
    var id: String { version }
    let version: String
    let count: Int
    let pct: Double
    let colorHex: UInt32
    let current: Bool
}

// MARK: - Security agents

struct SecurityAgent: Identifiable, Sendable {
    enum Trend: String, Sendable { case up, flat, down }
    var id: String { name }
    let name: String
    let installed: Int
    let pct: Double
    let column: String
    let trend: Trend
}

// MARK: - Compliance bands

struct ComplianceBand: Identifiable, Sendable {
    var id: String { label }
    let label: String
    let range: String
    let count: Int
    let pct: Double
    let colorHex: UInt32
}

// MARK: - Top failing rules

struct FailingRule: Identifiable, Sendable {
    var id: String { ruleID }
    let ruleID: String
    let fails: Int
    let baseline: String
}

// MARK: - Reports

struct Report: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let size: String
    let date: String
    let source: String
    let sheets: Int
    /// Device count sourced from the matching summary.json. Nil when the summary
    /// is absent, the filename carries no date, or totalDevices is non-numeric.
    let devices: Int?
}

struct BackupRecord: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let label: String
    let created: Date
    let sizeBytes: Int64
    let fileCount: Int
    let url: URL

    var createdLabel: String { FileDisplay.date(created) }
    var sizeLabel: String { FileDisplay.size(sizeBytes) }

    /// VoiceOver label for a backup row: display name, file count, size, date.
    var accessibilityLabel: String {
        let displayName = label.isEmpty ? name : label
        return "\(displayName), \(fileCount) files, \(sizeLabel), created \(createdLabel)"
    }

    /// VoiceOver summary describing the backup's content and purpose.
    var accessibilitySummary: String {
        let displayName = label.isEmpty ? name : label
        return "Configuration backup: \(displayName), \(fileCount) files, created \(createdLabel)"
    }
}

// MARK: - Sheet catalog (for Customize screen)

struct SheetGroup: Identifiable, Sendable {
    var id: String { group }
    let group: String
    var items: [SheetItem]
}

struct SheetItem: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let req: String   // "csv" | "cli" | "cli-1.2+" | "chart" | "platform"
    var on: Bool
}

// MARK: - Column mappings (Config screen)

struct ColumnMapping: Identifiable, Sendable {
    enum Status: String, Sendable { case ok, warn, fail, skip }
    var id: String { key }
    let key: String
    let label: String
    var value: String
    var required: Bool
    var status: Status
}

// MARK: - Custom EAs

struct CustomEA: Identifiable, Sendable {
    enum EAType: String, Sendable, CaseIterable, Identifiable {
        case boolean, percentage, version, text, date
        var id: String { rawValue }
    }
    var id: String { name }
    let name: String
    let column: String
    let type: EAType
    var warn: Int? = nil
    var crit: Int? = nil
    var currentVersions: [String]? = nil
    var warningDays: Int? = nil
    var trueValue: String? = nil
}

// MARK: - Devices

struct DeviceRow: Identifiable, Sendable {
    var id: String { serial }
    let name: String
    let serial: String
    var jamfID: String? = nil
    var numericJamfID: String? {
        guard let trimmed = jamfID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return trimmed
    }
    let os: String
    let user: String
    let dept: String
    let lastSeen: String
    let fileVault: Bool
    let fails: Int
    let model: String
}

// MARK: - Dedicated device inventory

struct DevicePatchFailure: Identifiable, Sendable, Hashable {
    var id: String { "\(title)|\(status)|\(date)" }
    var title: String
    var status: String
    var date: String
    var latestVersion: String
}

struct PatchTitleSummary: Identifiable, Sendable, Hashable {
    var id: String { title }
    var title: String
    var latestVersion: String
    var compliant: Int
    var total: Int
    var complianceLabel: String
}

struct DeviceOSSummary: Identifiable, Sendable, Hashable {
    var id: String { version }
    var version: String
    var count: Int
    var pct: Double
    var colorHex: UInt32
}

struct DeviceInventoryRecord: Identifiable, Sendable, Hashable {
    enum Risk: String, Sendable {
        case ok, attention, critical, unknown
    }

    var id: String
    var jamfID: String?
    var name: String
    var serial: String
    var osVersion: String
    var model: String
    var user: String
    var email: String
    var department: String
    var building: String
    var site: String
    var ipAddress: String
    var assetTag: String
    var managedState: String
    var lastContact: String
    var lastInventory: String
    var daysSinceContact: Int?
    var stale: Bool
    var fileVault: String
    var sip: String
    var firewall: String
    var gatekeeper: String
    var bootstrapToken: String
    var diskUsage: String
    var failedRules: Int
    var patchFailures: [DevicePatchFailure]
    var source: String

    var displayName: String { name.isEmpty ? "Unknown device" : name }
    var displaySerial: String { serial.isEmpty ? "No serial" : serial }
    var patchFailureCount: Int { patchFailures.count }
    var numericJamfID: String? {
        guard let trimmed = jamfID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return trimmed
    }

    var securityGapCount: Int {
        [fileVault, sip, firewall, gatekeeper, bootstrapToken].filter(Self.statusLooksBad).count
    }

    var risk: Risk {
        if failedRules > 30 || patchFailureCount > 2 || daysSinceContact ?? 0 > 90 {
            return .critical
        }
        if failedRules > 0 || patchFailureCount > 0 || stale || securityGapCount > 0 {
            return .attention
        }
        if source.isEmpty {
            return .unknown
        }
        return .ok
    }

    var searchableText: String {
        [
            jamfID ?? "", name, serial, osVersion, model, user, email, department, building, site,
            ipAddress, assetTag, managedState, source,
        ]
        .joined(separator: " ")
        .lowercased()
    }

    mutating func merge(_ other: DeviceInventoryRecord) {
        jamfID = firstNonEmpty(jamfID, other.jamfID)
        name = firstNonEmpty(name, other.name)
        serial = firstNonEmpty(serial, other.serial)
        osVersion = firstNonEmpty(osVersion, other.osVersion)
        model = firstNonEmpty(model, other.model)
        user = firstNonEmpty(user, other.user)
        email = firstNonEmpty(email, other.email)
        department = firstNonEmpty(department, other.department)
        building = firstNonEmpty(building, other.building)
        site = firstNonEmpty(site, other.site)
        ipAddress = firstNonEmpty(ipAddress, other.ipAddress)
        assetTag = firstNonEmpty(assetTag, other.assetTag)
        managedState = firstNonEmpty(managedState, other.managedState)
        lastContact = newestDateLabel(lastContact, other.lastContact)
        lastInventory = newestDateLabel(lastInventory, other.lastInventory)
        daysSinceContact = minKnown(daysSinceContact, other.daysSinceContact)
        stale = stale || other.stale
        fileVault = firstNonEmpty(fileVault, other.fileVault)
        sip = firstNonEmpty(sip, other.sip)
        firewall = firstNonEmpty(firewall, other.firewall)
        gatekeeper = firstNonEmpty(gatekeeper, other.gatekeeper)
        bootstrapToken = firstNonEmpty(bootstrapToken, other.bootstrapToken)
        diskUsage = firstNonEmpty(diskUsage, other.diskUsage)
        failedRules = max(failedRules, other.failedRules)
        for failure in other.patchFailures where !patchFailures.contains(failure) {
            patchFailures.append(failure)
        }
        source = [source, other.source]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, item in
                if !acc.contains(item) { acc.append(item) }
            }
            .joined(separator: " + ")
    }

    static func empty(id: String, source: String) -> DeviceInventoryRecord {
        DeviceInventoryRecord(
            id: id,
            jamfID: nil,
            name: "",
            serial: "",
            osVersion: "",
            model: "",
            user: "",
            email: "",
            department: "",
            building: "",
            site: "",
            ipAddress: "",
            assetTag: "",
            managedState: "",
            lastContact: "",
            lastInventory: "",
            daysSinceContact: nil,
            stale: false,
            fileVault: "",
            sip: "",
            firewall: "",
            gatekeeper: "",
            bootstrapToken: "",
            diskUsage: "",
            failedRules: 0,
            patchFailures: [],
            source: source
        )
    }

    private static func statusLooksBad(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
        guard !text.isEmpty else { return false }
        if text.contains("not ") || text.contains("disabled") {
            return true
        }
        return ["false", "no", "0", "unencrypted", "not escrowed"].contains(text)
    }
}

struct DeviceInventorySnapshot: Sendable {
    var devices: [DeviceInventoryRecord]
    var patchTitles: [PatchTitleSummary]
    var sourceFiles: [String]
    var warnings: [String]
    var generatedAt: String
    var generatedDate: Date?
    var isDemo: Bool

    static let empty = DeviceInventorySnapshot(
        devices: [], patchTitles: [], sourceFiles: [], warnings: [],
        generatedAt: "", generatedDate: nil, isDemo: false
    )

    var totalDevices: Int { devices.count }
    var patchIssueCount: Int { devices.filter { $0.patchFailureCount > 0 }.count }
    var securityGapCount: Int { devices.filter { $0.securityGapCount > 0 }.count }

    func staleCount(thresholdDays: Int) -> Int {
        devices.filter { device in
            if let days = device.daysSinceContact {
                return days >= thresholdDays
            }
            return device.stale
        }.count
    }

    var fileVaultPercent: Double {
        let known = devices.filter { !$0.fileVault.isEmpty }
        guard !known.isEmpty else { return 0 }
        let encrypted = known.filter { valueLooksGood($0.fileVault) }.count
        return Double(encrypted) / Double(known.count) * 100
    }

    var osDistribution: [DeviceOSSummary] {
        let counts = Dictionary(grouping: devices.filter { !$0.osVersion.isEmpty }, by: \.osVersion)
            .mapValues(\.count)
        let total = max(counts.values.reduce(0, +), 1)
        let colors: [UInt32] = [0xC9970A, 0x3A8A8A, 0x0A84FF, 0xBF5AF2, 0xFF9F0A, 0x7D8794]
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key > rhs.key }
                return lhs.value > rhs.value
            }
            .enumerated()
            .map { idx, item in
                DeviceOSSummary(
                    version: item.key,
                    count: item.value,
                    pct: Double(item.value) / Double(total) * 100,
                    colorHex: colors[idx % colors.count]
                )
            }
    }
}

struct DeviceDetail: Identifiable, Sendable {
    var id: String { lookupID }
    let lookupID: String
    let title: String
    let sections: [DeviceDetailSection]
    let warnings: [String]

    static func decode(from data: Data, lookupID: String) throws -> DeviceDetail {
        let object = try JSONSerialization.jsonObject(with: data)
        let sections = buildSections(from: object)
        return DeviceDetail(
            lookupID: lookupID,
            title: lookupID.isEmpty ? "Device Detail" : lookupID,
            sections: sections,
            warnings: sections.isEmpty ? ["jamf-cli returned no displayable detail rows."] : []
        )
    }
}

struct DeviceDetailSection: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let items: [DeviceDetailItem]
}

struct DeviceDetailItem: Identifiable, Sendable {
    let id: UUID
    let label: String
    let value: String
    let note: String

    init(label: String, value: String, note: String = "") {
        self.id = UUID()
        self.label = label
        self.value = value
        self.note = note
    }
}

private extension DeviceDetail {
    static func buildSections(from object: Any) -> [DeviceDetailSection] {
        var grouped: [String: [DeviceDetailItem]] = [:]
        var order: [String] = []

        func append(_ section: String, _ item: DeviceDetailItem) {
            let title = cleaned(section).isEmpty ? "Details" : cleaned(section)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(item)
        }

        if let rows = object as? [[String: Any]] {
            appendRows(rows, defaultSection: "Details", append: append)
        } else if let dict = object as? [String: Any] {
            appendDictionary(dict, append: append)
        }

        return order.compactMap { title in
            guard let items = grouped[title], !items.isEmpty else { return nil }
            return DeviceDetailSection(title: title, items: items)
        }
    }

    static func appendDictionary(
        _ dict: [String: Any],
        append: (String, DeviceDetailItem) -> Void
    ) {
        for key in dict.keys.sorted() {
            guard !metadataKeys.contains(key) else { continue }
            let value = dict[key]
            if let rows = value as? [[String: Any]] {
                appendRows(rows, defaultSection: titleLabel(key), append: append)
            } else if let nested = value as? [String: Any] {
                appendNested(nested, section: titleLabel(key), prefix: "", append: append)
            } else {
                let display = displayValue(value)
                if !display.isEmpty {
                    append("Details", DeviceDetailItem(label: titleLabel(key), value: display))
                }
            }
        }
    }

    static func appendNested(
        _ dict: [String: Any],
        section: String,
        prefix: String,
        append: (String, DeviceDetailItem) -> Void
    ) {
        for key in dict.keys.sorted() {
            guard !metadataKeys.contains(key) else { continue }
            let label = prefix.isEmpty ? titleLabel(key) : "\(prefix) / \(titleLabel(key))"
            let value = dict[key]
            if let nested = value as? [String: Any] {
                appendNested(nested, section: section, prefix: label, append: append)
            } else {
                let display = displayValue(value)
                if !display.isEmpty {
                    append(section, DeviceDetailItem(label: label, value: display))
                }
            }
        }
    }

    static func appendRows(
        _ rows: [[String: Any]],
        defaultSection: String,
        append: (String, DeviceDetailItem) -> Void
    ) {
        for row in rows {
            let section = firstString(row, ["section", "category", "group", "type"]) ?? defaultSection
            let label = firstString(row, ["resource", "name", "label", "field", "key", "title"])
                ?? fallbackLabel(row)
            let value = firstString(row, ["value", "status", "result", "state", "last_action", "date"])
                ?? fallbackValue(row)
            let note = firstString(row, ["detail", "details", "message", "updated", "timestamp"]) ?? ""
            let labelText = label ?? ""
            let valueText = value ?? ""

            if !labelText.isEmpty || !valueText.isEmpty {
                append(
                    section,
                    DeviceDetailItem(
                        label: labelText.isEmpty ? "Value" : labelText,
                        value: valueText.isEmpty ? "N/A" : valueText,
                        note: note
                    )
                )
            } else if let data = row["data"] as? [String: Any] {
                appendNested(data, section: section, prefix: "", append: append)
            }
        }
    }

    static func fallbackLabel(_ row: [String: Any]) -> String? {
        for key in row.keys.sorted() where !metadataKeys.contains(key) {
            if displayValue(row[key]).isEmpty { continue }
            return titleLabel(key)
        }
        return nil
    }

    static func fallbackValue(_ row: [String: Any]) -> String? {
        for key in row.keys.sorted() where !metadataKeys.contains(key) {
            let value = displayValue(row[key])
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func firstString(_ row: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            let value = displayValue(row[key])
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func displayValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return cleaned(value)
        case let value as Bool:
            return value ? "true" : "false"
        case let value as NSNumber:
            return value.stringValue
        case let value as [Any]:
            return value.isEmpty ? "" : "\(value.count) items"
        case let value as [String: Any]:
            return value.isEmpty ? "" : "\(value.count) fields"
        default:
            return ""
        }
    }

    static func titleLabel(_ value: String) -> String {
        cleaned(value)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var metadataKeys: Set<String> {
        ["section", "category", "group", "type", "data"]
    }
}

private func firstNonEmpty(_ lhs: String, _ rhs: String) -> String {
    lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rhs : lhs
}

private func firstNonEmpty(_ lhs: String?, _ rhs: String?) -> String? {
    let trimmed = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? rhs : lhs
}

private func minKnown(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case (.some(let a), .some(let b)): min(a, b)
    case (.some(let a), .none): a
    case (.none, .some(let b)): b
    case (.none, .none): nil
    }
}

private func newestDateLabel(_ lhs: String, _ rhs: String) -> String {
    firstNonEmpty(lhs, rhs)
}

private func valueLooksGood(_ value: String) -> Bool {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: " ")
    guard !text.isEmpty else { return false }
    if text.contains("not ") || text.contains("disabled") || text.contains("unencrypted") {
        return false
    }
    return text.contains("enabled")
        || text.contains("encrypted")
        || text.contains("escrowed")
        || ["true", "yes", "1", "managed"].contains(text)
}

// MARK: - Token status

/// Read-only snapshot of a jamf-cli auth token for one profile.
/// Populated by `CLIBridge.tokenStatus(for:)` using `jamf-cli pro auth token --output json`.
///
/// JSON shape (jamf-cli v1.9+):
///   { "token": "eyJ...", "expires_at": "2026-05-04T13:38:38Z" }
/// `expires_at` is omitted when the profile uses a static token file (bearer-token auth).
///
/// - Note: Instances decoded from persisted storage carry `raw == ""` and re-derive
///   `isValid` from the stored `Bool`. Re-probe via `CLIBridge.tokenStatus(for:)`
///   before making any auth decisions — decoded instances are for display only.
struct TokenStatus: Sendable, Codable {
    let profile: String
    /// Parsed from `expires_at`; nil when jamf-cli omits it (token-file auth).
    let expiresAt: Date?
    /// True when jamf-cli returned a token without error (exit 0).
    let isValid: Bool
    /// Raw stdout for debugging. Excluded from Codable round-trip — debug-only field.
    let raw: String

    /// True when the token has a known expiry and that expiry is in the past.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    enum CodingKeys: String, CodingKey {
        case profile, expiresAt, isValid
        // raw excluded intentionally — debug-only field
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(String.self, forKey: .profile)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        isValid = try c.decode(Bool.self, forKey: .isValid)
        raw = ""  // not persisted; callers use make() which supplies raw at construction time
    }

    private init(profile: String, expiresAt: Date?, isValid: Bool, raw: String) {
        self.profile = profile
        self.expiresAt = expiresAt
        self.isValid = isValid
        self.raw = raw
    }

    /// Factory for constructing a `TokenStatus`. Prefer this over direct memberwise init.
    static func make(profile: String, token: String?, expiresAt: Date?, raw: String) -> TokenStatus {
        guard !profile.isEmpty else {
            return TokenStatus(profile: "", expiresAt: nil, isValid: false, raw: raw)
        }
        return TokenStatus(
            profile: profile,
            expiresAt: expiresAt,
            isValid: !(token ?? "").isEmpty,
            raw: raw
        )
    }
}

// MARK: - Trend metric

struct TrendSeries: Identifiable, Sendable {
    enum Metric: String, CaseIterable, Identifiable, Sendable {
        // .edrAgent keeps the legacy "crowdstrike" raw value so persisted
        // score-card selections and the summary.json field name stay valid.
        // The user-visible name is config-driven (security_agents → first
        // entry's name); the generic fallback is "EDR Agent Installed".
        case stability, activeDevices, compliance, fileVault, osCurrent
        case edrAgent = "crowdstrike"
        case stale, patch
        /// v3.5 weighted security score (0–100). Populated from
        /// LegacyHistoryImporter and from future Swift ReportEngine runs that
        /// emit the field in summary.json.
        case securityScore
        /// Per-baseline mSCP compliance band trend. Shows stacked-area chart
        /// of device counts by compliance band (Pass/Low/Medium/High) over time.
        /// Only appears in TrendsView metric picker when mscpBands history exists.
        case mscpBandTrend
        var id: String { rawValue }
        var displayLabel: String {
            switch self {
            case .stability:     return "Stability Index"
            case .activeDevices: return "Active Devices"
            case .compliance:    return "Compliance Benchmark"
            case .fileVault:     return "FileVault Encryption"
            case .osCurrent:     return "On Current macOS"
            case .edrAgent:      return "EDR Agent Installed"
            case .stale:         return "Stale Devices (30d+)"
            case .patch:         return "Patch Compliance"
            case .securityScore: return "Security Score (Weighted)"
            case .mscpBandTrend: return "mSCP Compliance Bands"
            }
        }

        /// Returns the tenant-specific label when one is configured; otherwise
        /// the metric's static `displayLabel`. `.compliance` follows
        /// `compliance.baseline_label`; `.edrAgent` follows the first
        /// `security_agents` entry's name (e.g. "CrowdStrike Falcon Installed").
        func displayLabel(benchmarkLabel: String?, edrAgentName: String? = nil) -> String {
            if case .compliance = self, let b = benchmarkLabel, !b.isEmpty { return b }
            if case .edrAgent = self, let e = edrAgentName, !e.isEmpty { return "\(e) Installed" }
            return displayLabel
        }
        var unit: String {
            switch self {
            case .stale, .activeDevices, .mscpBandTrend: return ""
            default: return "%"
            }
        }
        var minY: Double {
            switch self {
            case .activeDevices, .mscpBandTrend: return 0
            case .stability:     return 40
            case .compliance:    return 40
            case .fileVault:     return 60
            case .osCurrent:     return 30
            case .edrAgent:      return 70
            case .stale:         return 0
            case .patch:         return 40
            case .securityScore: return 60
            }
        }
        var maxY: Double {
            switch self {
            case .activeDevices: return 1000
            case .stale:         return 60
            case .mscpBandTrend: return 500  // Per-band device count max
            default:             return 100
            }
        }
        var colorHex: UInt32 {
            switch self {
            case .stability:     return 0xE8B614
            case .activeDevices: return 0x8E8E93
            case .compliance:    return 0xC9970A
            case .fileVault:     return 0x30D158
            case .osCurrent:     return 0x0A84FF
            case .edrAgent:      return 0x3A8A8A
            case .stale:         return 0xFF9F0A
            case .patch:         return 0xBF5AF2
            case .securityScore: return 0xFF453A
            case .mscpBandTrend: return 0xC9970A  // Same as compliance (gold)
            }
        }
    }

    /// Composite fleet-stability score: compliance 0.4 + patch 0.4 +
    /// stale-device pressure 0.2, with drop-missing-and-renormalize weighting
    /// (the same approach as `SecurityScoreCalculator`). Tenants without a
    /// compliance source — the common jamf-cli-only case — still get a
    /// comparable index from patch + stale instead of a permanent "—".
    ///
    /// Returns nil only when both compliance and patch are unavailable;
    /// stale pressure alone is not a meaningful stability signal.
    static func stabilityIndex(
        compliancePct: Double?,
        patchPct: Double?,
        staleCount: Int?,
        totalDevices: Int
    ) -> Double? {
        guard compliancePct != nil || patchPct != nil else { return nil }

        var components: [(value: Double, weight: Double)] = []
        // Unknown is not fresh: an unmeasured fleet must not contribute a
        // perfect stale score — the component drops and the rest renormalize.
        if let staleCount, totalDevices > 0 {
            let stalePct = (Double(staleCount) / Double(totalDevices)) * 100
            components.append((100 - stalePct, 0.2))
        }
        if let compliancePct { components.append((compliancePct, 0.4)) }
        if let patchPct { components.append((patchPct, 0.4)) }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let raw = components.reduce(0) { $0 + $1.value * ($1.weight / totalWeight) }
        return min(max(raw, 0), 100)
    }

    /// Human-readable description of which components feed the stability
    /// index, for the metric detail page. Nil when the index itself is nil.
    ///
    /// When `compliancePct` is present and `complianceIsProxy` is true, appends
    /// a note that the compliance component is a 4-control proxy rather than a
    /// real mSCP failure-count source, so operators understand the index is
    /// partially estimated.
    static func stabilityBasis(
        compliancePct: Double?,
        patchPct: Double?,
        complianceIsProxy: Bool? = nil,
        staleMeasured: Bool = true
    ) -> String? {
        let proxyNote: String = compliancePct != nil && complianceIsProxy == true
            ? " Compliance component is a 4-control proxy — configure a Compliance EA for true mSCP data."
            : ""
        let staleNote = staleMeasured
            ? "" : " Stale-device pressure not measured (no device-compliance snapshot)."
        switch (compliancePct != nil, patchPct != nil) {
        case (true, true):
            return "Composite of compliance, patch posture, and stale-device pressure.\(proxyNote)\(staleNote)"
        case (false, true):
            return "Composite of patch posture and stale-device pressure (compliance not collected).\(staleNote)"
        case (true, false):
            return "Composite of compliance and stale-device pressure (patch data not collected).\(proxyNote)\(staleNote)"
        case (false, false):
            return nil
        }
    }

    var id: String { metric.rawValue }
    let metric: Metric
    let values: [Double]
}

extension DailySummary {
    var stabilityIndex: Double? {
        TrendSeries.stabilityIndex(
            compliancePct: compliancePct,
            patchPct: patchPct,
            staleCount: staleCount,
            totalDevices: totalDevices
        )
    }
}

// MARK: - Trend range

enum TrendRange: String, CaseIterable, Identifiable, Sendable {
    case w4 = "W4", w12 = "W12", w26 = "W26", w52 = "W52", all = "All"
    var id: String { rawValue }
}

// MARK: - Sheet grouping for custom template selection

/// Groups report sheets into logical categories for the custom template picker.
struct CustomSheetGroup: Sendable {
    let name: String
    let sheets: [SheetID]

    /// All sheet groups organized by functional area.
    /// Order matches the sidebar grouping in the main app for consistency.
    static let allGroups: [CustomSheetGroup] = [
        CustomSheetGroup(name: "Executive", sheets: [
            .executiveSummary,
            .cover,
            .fleetOverview,
            .auditSummary,
        ]),
        CustomSheetGroup(name: "Posture", sheets: [
            .securityPosture,
            .compliancePosture,
            .deviceCompliance,
            .mscpCompliance,
            .complianceTrend,
        ]),
        CustomSheetGroup(name: "Operations", sheets: [
            .patchCompliance,
            .patchFailures,
            .patchSummaryDashboard,
            .updateStatus,
            .updateFailures,
            .policyHealth,
            .profileStatus,
            .mobileConfigProfiles,
            .eaCoverage,
            .eaDefinitions,
            .ddmStatus,
            .blueprintStatus,
        ]),
        CustomSheetGroup(name: "Fleet", sheets: [
            .inventorySummary,
            .hardwareModels,
            .mobileFleetSummary,
            .mobileInventory,
            .mobileSupervisionStatus,
            .checkinHealth,
            .activeDevices,
            .groupHygiene,
            .smartGroups,
            .environmentStats,
        ]),
        CustomSheetGroup(name: "Security", sheets: [
            .deviceSecurityState,
            .protectOverview,
            .protectAlerts,
            .protectComputers,
            .protectInsights,
            .protectPlans,
            .protectThreatOverview,
        ]),
        CustomSheetGroup(name: "System", sheets: [
            .osCurrency,
            .appStatus,
            .softwareInstalls,
            .packageLifecycle,
            .complianceDevices,
            .complianceRules,
        ]),
    ]
}
