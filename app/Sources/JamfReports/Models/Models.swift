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
