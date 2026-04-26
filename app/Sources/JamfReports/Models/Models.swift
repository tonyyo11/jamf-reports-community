import Foundation

// MARK: - Workspace / org

struct Org: Sendable {
    let name: String
    let short: String
    let jamfURL: String
    let profile: String
    let apiClient: String
    let workspaceRoot: String
}

// MARK: - jamf-cli profile

struct JamfCLIProfile: Identifiable, Sendable {
    enum Status: String, Sendable { case ok, idle, error }
    var id: String { name }
    let name: String
    let url: String
    let schedules: Int
    let status: Status
}

// MARK: - Schedules

struct Schedule: Identifiable, Sendable {
    enum RunMode: String, Sendable, CaseIterable, Identifiable {
        case snapshotOnly  = "snapshot-only"
        case jamfCLIOnly   = "jamf-cli-only"
        case jamfCLIFull   = "jamf-cli-full"
        case csvAssisted   = "csv-assisted"
        var id: String { rawValue }
    }
    enum LastStatus: String, Sendable { case ok, warn, fail }

    var id: String { "\(profile)/\(name)" }
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

    var launchAgentLabel: String {
        let slug = name.lowercased().replacing(/\s+/, with: "-")
        return "com.tonyyo.jrc.\(profile).\(slug)"
    }
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

struct Report: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let size: String
    let date: String
    let source: String
    let sheets: Int
    let devices: Int
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
            name, serial, osVersion, model, user, email, department, building, site,
            ipAddress, assetTag, managedState, source,
        ]
        .joined(separator: " ")
        .lowercased()
    }

    mutating func merge(_ other: DeviceInventoryRecord) {
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
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        if text.contains("not enabled") || text.contains("disabled") || text.contains("not collected") {
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
    var isDemo: Bool

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

private func firstNonEmpty(_ lhs: String, _ rhs: String) -> String {
    lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rhs : lhs
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
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return false }
    if text.contains("not enabled")
        || text.contains("disabled")
        || text.contains("unencrypted")
        || text.contains("not escrowed") {
        return false
    }
    return text.contains("enabled")
        || text.contains("encrypted")
        || text.contains("escrowed")
        || ["true", "yes", "1", "managed"].contains(text)
}

// MARK: - Trend metric

struct TrendSeries: Identifiable, Sendable {
    enum Metric: String, CaseIterable, Identifiable, Sendable {
        case compliance, fileVault, osCurrent, crowdstrike, stale, patch
        var id: String { rawValue }
        var displayLabel: String {
            switch self {
            case .compliance:  "NIST 800-53r5 Moderate"
            case .fileVault:   "FileVault Encryption"
            case .osCurrent:   "On Current macOS"
            case .crowdstrike: "CrowdStrike Installed"
            case .stale:       "Stale Devices (30d+)"
            case .patch:       "Patch Compliance"
            }
        }
        var unit: String { self == .stale ? "" : "%" }
        var minY: Double {
            switch self {
            case .compliance:  40
            case .fileVault:   60
            case .osCurrent:   30
            case .crowdstrike: 70
            case .stale:       0
            case .patch:       40
            }
        }
        var maxY: Double { self == .stale ? 60 : 100 }
        var colorHex: UInt32 {
            switch self {
            case .compliance:  0xC9970A
            case .fileVault:   0x30D158
            case .osCurrent:   0x0A84FF
            case .crowdstrike: 0x3A8A8A
            case .stale:       0xFF9F0A
            case .patch:       0xBF5AF2
            }
        }
    }

    var id: String { metric.rawValue }
    let metric: Metric
    let values: [Double]
}

// MARK: - Trend range

enum TrendRange: String, CaseIterable, Identifiable, Sendable {
    case w4 = "4w", w12 = "12w", w26 = "26w", w52 = "52w", all = "All"
    var id: String { rawValue }
}
