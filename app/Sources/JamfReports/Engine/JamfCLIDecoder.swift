import Foundation

// MARK: - Security report
// `jamf-cli pro report security --output json`
// Returns an array of typed section envelopes.

/// Top-level item from `pro report security --output json`.
enum SecurityReportItem: Decodable, Sendable {
    case summary(SecuritySummary)
    case osVersion(SecurityOSVersion)
    case device(SecurityDevice)
    case unknown

    private enum CodingKeys: String, CodingKey { case section }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let section = try container.decodeIfPresent(String.self, forKey: .section) ?? ""
        switch section {
        case "summary":
            self = .summary(try SecuritySummary(from: decoder))
        case "os_version":
            self = .osVersion(try SecurityOSVersion(from: decoder))
        case "device":
            self = .device(try SecurityDevice(from: decoder))
        default:
            self = .unknown
        }
    }
}

/// `section == "summary"` data block from the security report.
struct SecuritySummary: Decodable, Sendable {
    let section: String
    let data: SecuritySummaryData
}

struct SecuritySummaryData: Decodable, Sendable {
    let totalDevices: Int?
    let fileVaultEncrypted: Int?
    let fileVaultEncryptedPct: String?
    let gatekeeperEnabled: Int?
    let sipEnabled: Int?
    let firewallEnabled: Int?

    private enum CodingKeys: String, CodingKey {
        case totalDevices = "total_devices"
        case fileVaultEncrypted = "filevault_encrypted"
        case fileVaultEncryptedPct = "filevault_encrypted_pct"
        case gatekeeperEnabled = "gatekeeper_enabled"
        case sipEnabled = "sip_enabled"
        case firewallEnabled = "firewall_enabled"
    }
}

/// `section == "os_version"` row from the security report.
struct SecurityOSVersion: Decodable, Sendable {
    let section: String
    let osVersion: String
    let count: Int
    let pct: String

    private enum CodingKeys: String, CodingKey {
        case section
        case osVersion = "os_version"
        case count, pct
    }
}

/// `section == "device"` row from the security report.
struct SecurityDevice: Decodable, Sendable {
    let section: String
    let name: String?
    let serial: String?
    let data: [String: AnyCodable]?
}

// MARK: - Policy status
// `jamf-cli pro report policy-status --output json`

struct PolicyStatusReport: Decodable, Sendable {
    let summary: PolicyStatusSummary
    let configFindings: [PolicyFinding]

    private enum CodingKeys: String, CodingKey {
        case summary
        case configFindings = "config_findings"
    }
}

struct PolicyStatusSummary: Decodable, Sendable {
    let totalPolicies: Int
    let enabled: Int
    let disabled: Int
    let configFindings: Int
    let warnings: Int
    let info: Int

    private enum CodingKeys: String, CodingKey {
        case totalPolicies = "total_policies"
        case enabled, disabled
        case configFindings = "config_findings"
        case warnings, info
    }
}

struct PolicyFinding: Decodable, Sendable {
    let severity: String
    let policy: String
    let policyId: String
    let check: String
    let detail: String

    private enum CodingKeys: String, CodingKey {
        case severity, policy
        case policyId = "policy_id"
        case check, detail
    }
}

// MARK: - Patch status
// `jamf-cli pro report patch-status --output json`

struct PatchStatusRow: Decodable, Sendable {
    let title: String
    let id: String
    /// Devices on the latest version (v1.14+ shape).
    let onLatest: Int
    /// Devices on other versions.
    let onOther: Int
    let total: Int
    let latest: String
    let compliancePct: String

    private enum CodingKeys: String, CodingKey {
        case title, id
        case onLatest = "on_latest"
        case onOther = "on_other"
        case total, latest
        case compliancePct = "compliance_pct"
    }
}

// MARK: - Patch scan failures
// `jamf-cli pro report patch-status --scan-failures --output json`

struct PatchFailureRow: Decodable, Sendable {
    let policy: String
    let policyId: String
    let device: String
    let deviceId: String
    let statusDate: String
    let attempt: Int
    let lastAction: String
    let serial: String
    let osVersion: String
    let username: String

    private enum CodingKeys: String, CodingKey {
        case policy
        case policyId = "policy_id"
        case device
        case deviceId = "device_id"
        case statusDate = "status_date"
        case attempt
        case lastAction = "last_action"
        case serial
        case osVersion = "os_version"
        case username
    }
}

// MARK: - Update status
// `jamf-cli pro report update-status --output json`

struct UpdateStatusReport: Decodable, Sendable {
    let total: Int
    let statusSummary: [UpdateStatusCount]
    let planTotal: Int?
    let planStateSummary: [UpdateStateCount]?

    private enum CodingKeys: String, CodingKey {
        case total
        case statusSummary = "status_summary"
        case planTotal = "plan_total"
        case planStateSummary = "plan_state_summary"
    }
}

struct UpdateStatusCount: Decodable, Sendable {
    let status: String
    let count: Int
}

struct UpdateStateCount: Decodable, Sendable {
    let state: String
    let count: Int
}

// MARK: - Update failures
// `jamf-cli pro report update-status --scan-failures --output json`

struct UpdateFailuresReport: Decodable, Sendable {
    let total: Int
    let statusSummary: [UpdateStatusCount]
    let errorDevices: [UpdateErrorDevice]
    let planTotal: Int?
    let planStateSummary: [UpdateStateCount]?
    let failedPlans: [UpdateFailedPlan]

    private enum CodingKeys: String, CodingKey {
        case total
        case statusSummary = "status_summary"
        case errorDevices = "error_devices"
        case planTotal = "plan_total"
        case planStateSummary = "plan_state_summary"
        case failedPlans = "failed_plans"
    }
}

struct UpdateErrorDevice: Decodable, Sendable {
    let name: String
    let serial: String
    let deviceType: String
    let osVersion: String
    let username: String
    let status: String
    let productKey: String
    let updated: String

    private enum CodingKeys: String, CodingKey {
        case name, serial
        case deviceType = "device_type"
        case osVersion = "os_version"
        case username, status
        case productKey = "product_key"
        case updated
    }
}

struct UpdateFailedPlan: Decodable, Sendable {
    let name: String
    let serial: String
    let deviceType: String
    let osVersion: String
    let username: String
    let state: String
    let action: String
    let version: String
    let error: String
    let lastEvent: String

    private enum CodingKeys: String, CodingKey {
        case name, serial
        case deviceType = "device_type"
        case osVersion = "os_version"
        case username, state, action, version, error
        case lastEvent = "last_event"
    }
}

// MARK: - Overview row
// `jamf-cli pro overview --output json`

struct OverviewRow: Decodable, Sendable {
    let section: String
    let resource: String
    let value: AnyCodable?
    let status: String?
}

// MARK: - Inventory summary
// `jamf-cli pro report inventory-summary --output json`

struct InventorySummaryRow: Decodable, Sendable {
    let osVersion: String
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case osVersion = "os_version"
        case count
    }
}

// MARK: - Device compliance
// `jamf-cli pro report device-compliance --output json`

struct DeviceComplianceRow: Decodable, Sendable {
    let name: String?
    let serial: String?
    let managed: Bool?
    let stale: Bool?
    let daysSinceCheckin: Int?

    private enum CodingKeys: String, CodingKey {
        case name, serial, managed, stale
        case daysSinceCheckin = "days_since_checkin"
    }
}

// MARK: - EA results
// `jamf-cli pro report ea-results --all --output json`

struct EAResultRow: Decodable, Sendable {
    let computerId: String?
    let computerName: String?
    let serial: String?
    let eaId: String?
    let eaName: String?
    let value: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case computerId = "computer_id"
        case computerName = "computer_name"
        case serial
        case eaId = "ea_id"
        case eaName = "ea_name"
        case value
    }
}

// MARK: - Computer extension attributes list
// `jamf-cli pro computer-extension-attributes list --output json`

/// A single extension attribute definition returned by
/// `jamf-cli pro computer-extension-attributes list --output json`.
///
/// `dataType` values: "STRING" | "INTEGER" | "DATE" | "BOOLEAN"
/// `inputType` values: "TEXT" | "POPUP" | "SCRIPT"
struct ExtensionAttribute: Decodable, Sendable, Identifiable {
    let id: String?
    let name: String?
    /// Jamf data type: "STRING", "INTEGER", "DATE", "BOOLEAN".
    let dataType: String?
    let description: String?
    /// Input type: "TEXT", "POPUP", "SCRIPT".
    let inputType: String?
    let enabled: Bool?

    // jamf-cli emits camelCase for this endpoint.
    private enum CodingKeys: String, CodingKey {
        case id, name, dataType, description, inputType, enabled
    }

    /// Maps Jamf `dataType` to a `custom_eas` type string for config.yaml.
    var inferredEAType: String {
        switch (dataType ?? "").uppercased() {
        case "BOOLEAN":  return "boolean"
        case "DATE":     return "date"
        case "INTEGER":  return "percentage"
        default:         return "text"
        }
    }
}

/// Alias retained for any call sites that referenced the old name.
typealias ExtensionAttributeDefinition = ExtensionAttribute

// MARK: - Software installs
// `jamf-cli pro report software-installs --output json`

struct SoftwareInstallRow: Decodable, Sendable {
    let name: String
    let version: String?
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case name, version, count
    }
}

// MARK: - App status
// `jamf-cli pro report app-status --output json`

struct AppStatusRow: Decodable, Sendable {
    let name: String
    let version: String?
    let installed: Int?
    let managed: Int?
    let total: Int?
    let errors: Int?
}

// MARK: - Smart groups
// `jamf-cli pro smart-computer-groups list --output json`

struct SmartGroupRow: Decodable, Sendable {
    let id: AnyCodable?
    let name: String?
    let membershipCount: AnyCodable?
    let smart: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case membershipCount
        case smart
    }
}

// MARK: - Profile status (classic macOS profiles)
// `jamf-cli pro classic-macos-profiles list --output json`

struct ProfileStatusRow: Decodable, Sendable {
    let id: AnyCodable?
    let name: String?
    let category: String?
    let site: String?
    let managementStatus: String?
    let errorCount: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case id, name, category, site
        case managementStatus = "management_status"
        case errorCount = "error_count"
    }
}

// MARK: - Checkin health
// `jamf-cli pro report checkin-status --output json`

struct CheckinStatusRow: Decodable, Sendable {
    let name: String?
    let serial: String?
    let daysSinceCheckin: Int?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case name, serial
        case daysSinceCheckin = "days_since_checkin"
        case status
    }
}

// MARK: - Hardware models
// `jamf-cli pro report hardware-models --output json`

struct HardwareModelRow: Decodable, Sendable {
    let model: String
    let count: Int
    let pct: String?
}

// MARK: - Audit
// `jamf-cli pro audit --output json`

struct AuditItem: Decodable, Sendable {
    let section: String?
    let check: String?
    let severity: String?
    let status: String?
    let detail: String?
    let recommendation: String?
    let resource: String?
    let value: AnyCodable?
}

// MARK: - Group hygiene (group-tools analyze)

struct GroupAnalysisRow: Decodable, Sendable {
    let groupName: AnyCodable?
    let groupType: AnyCodable?
    let membershipCount: AnyCodable?
    let smart: Bool?
    let unused: Bool?

    private enum CodingKeys: String, CodingKey {
        case groupName, groupType, membershipCount, smart, unused
    }
}

// MARK: - Mobile device (inventory-details)
// `jamf-cli pro mobile-device-inventory-details list --output json`

struct MobileDeviceInventoryItem: Decodable, Sendable {
    let mobileDeviceId: String?
    let deviceType: String?
    let general: MobileDeviceGeneral?
    let userAndLocation: MobileDeviceUserLocation?

    private enum CodingKeys: String, CodingKey {
        case mobileDeviceId, deviceType, general, userAndLocation
    }
}

struct MobileDeviceGeneral: Decodable, Sendable {
    let displayName: String?
    let serialNumber: String?
    let osVersion: String?
    let managed: Bool?
    let supervised: Bool?
    let lastInventoryUpdateDate: String?
    let deviceOwnershipType: String?
    let activationLockEnabled: Bool?
    let passcodeCompliant: Bool?
    let dataProtectionEnabled: Bool?
    let jailbreakDetected: String?
}

struct MobileDeviceUserLocation: Decodable, Sendable {
    let username: String?
    let emailAddress: String?
    let department: String?
    let building: String?
}

// MARK: - Mobile device list (simple)
// `jamf-cli pro mobile-devices list --output json`

struct MobileDeviceListRow: Decodable, Sendable {
    let id: String?
    let name: String?
    let model: String?
    let serialNumber: String?
    let username: String?
    let type: String?
}

// MARK: - Classic iOS/mobile config profiles
// `jamf-cli pro classic-mobile-config-profiles list --output json`

struct MobileConfigProfileRow: Decodable, Sendable {
    let id: AnyCodable?
    let name: String?
    let category: String?
    let site: String?
    let description: String?
}

// MARK: - Groups
// `jamf-cli pro groups list --output json`

struct GroupRow: Decodable, Sendable {
    let groupPlatformId: String?
    let groupJamfProId: String?
    let groupName: String?
    let groupType: String?
    let membershipCount: Int?
    let smart: Bool?
}

// MARK: - Packages
// `jamf-cli pro packages list --output json`

struct PackageRow: Decodable, Sendable {
    let id: String?
    let packageName: String?
    let fileName: String?
    let notes: String?
    let size: AnyCodable?
}

// MARK: - Environment stats
// `jamf-cli pro report env-stats --output json`

struct EnvStatsReport: Decodable, Sendable {
    let policies: Int?
    let configProfiles: Int?
    let scripts: Int?
    let packages: Int?
    let smartGroupsComputer: Int?
    let smartGroupsMobile: Int?
    let extensionAttributes: Int?
    let categories: Int?

    private enum CodingKeys: String, CodingKey {
        case policies
        case configProfiles = "config_profiles"
        case scripts, packages
        case smartGroupsComputer = "smart_groups_computer"
        case smartGroupsMobile = "smart_groups_mobile"
        case extensionAttributes = "extension_attributes"
        case categories
    }
}

// MARK: - Platform compliance devices
// `jamf-cli pro report compliance-devices --output json`

struct ComplianceDeviceRow: Decodable, Sendable {
    let device: String?
    let deviceId: String?
    let rulesFailed: Int?
    let rulesPassed: Int?
    let compliance: String?

    private enum CodingKeys: String, CodingKey {
        case device
        case deviceId = "deviceId"
        case rulesFailed = "rulesFailed"
        case rulesPassed = "rulesPassed"
        case compliance
    }
}

// MARK: - Platform compliance rules
// `jamf-cli pro report compliance-rules --output json`

struct ComplianceRuleRow: Decodable, Sendable {
    let rule: String?
    let passed: Int?
    let failed: Int?
    let unknown: Int?
    let devices: Int?
    let passRate: String?

    private enum CodingKeys: String, CodingKey {
        case rule, passed, failed, unknown, devices
        case passRate = "passRate"
    }
}

// MARK: - DDM status
// `jamf-cli pro report ddm-status --output json`

struct DDMStatusRow: Decodable, Sendable {
    let source: String?
    let type: String?
    let declarations: Int?
    let devices: Int?
    let successful: Int?
    let unsuccessful: Int?
}

// MARK: - Blueprint status
// `jamf-cli pro report blueprint-status --output json`

struct BlueprintStatusRow: Decodable, Sendable {
    let name: String?
    let state: String?
    let scope: Int?
    let steps: Int?
    let failed: Int?
    let pending: Int?
    let succeeded: Int?
}

// MARK: - Protect overview
// `jamf-cli protect overview --output json`

struct ProtectOverviewItem: Decodable, Sendable {
    let value: AnyCodable?
    let extraFields: [String: AnyCodable]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var fields: [String: AnyCodable] = [:]
        for key in container.allKeys {
            fields[key.stringValue] = try container.decodeIfPresent(AnyCodable.self, forKey: key)
        }
        value = fields["value"]
        extraFields = fields
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}

// MARK: - Protect alert
// `jamf-cli protect alerts list --output json`

struct ProtectAlertRow: Decodable, Sendable {
    let uuid: String?
    let created: String?
    let severity: String?
    let status: String?
    let eventType: String?
    let hostName: String?
    let serial: String?

    private enum CodingKeys: String, CodingKey {
        case uuid, created, severity, status, eventType
        case hostName, serial
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        // computer is a nested object; extract hostName/serial from flat fields or sub-object.
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
    }
}

// MARK: - Protect computer
// `jamf-cli protect computers list --output json`

struct ProtectComputerRow: Decodable, Sendable {
    let uuid: String?
    let hostName: String?
    let serial: String?
    let modelName: String?
    let osString: String?
    let planName: String?
    let webProtectionActive: Bool?
    let fullDiskAccess: Bool?
    let connectionStatus: String?
    let lastConnection: String?
    let insightsStatsPass: Int?
    let insightsStatsFail: Int?

    private enum CodingKeys: String, CodingKey {
        case uuid, hostName, serial, modelName, osString
        case webProtectionActive, fullDiskAccess, connectionStatus, lastConnection
        case insightsStatsPass, insightsStatsFail
        case plan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        osString = try c.decodeIfPresent(String.self, forKey: .osString)
        webProtectionActive = try c.decodeIfPresent(Bool.self, forKey: .webProtectionActive)
        fullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .fullDiskAccess)
        connectionStatus = try c.decodeIfPresent(String.self, forKey: .connectionStatus)
        lastConnection = try c.decodeIfPresent(String.self, forKey: .lastConnection)
        insightsStatsPass = try c.decodeIfPresent(Int.self, forKey: .insightsStatsPass)
        insightsStatsFail = try c.decodeIfPresent(Int.self, forKey: .insightsStatsFail)
        // plan is a nested object {id, name}; extract name only.
        if let planObj = try? c.decodeIfPresent([String: AnyCodable].self, forKey: .plan) {
            planName = planObj["name"]?.stringValue
        } else {
            planName = nil
        }
    }
}

// MARK: - Protect insight
// `jamf-cli protect insights list --output json`

struct ProtectInsightRow: Decodable, Sendable {
    let uuid: String?
    let label: String?
    let section: String?
    let description: String?
    let totalPass: Int?
    let totalFail: Int?
    let enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case uuid, label, section, description, totalPass, totalFail, enabled
    }
}

// MARK: - AnyCodable
// Lightweight type-erased Codable for fields whose JSON type varies across
// jamf-cli versions or commands (Int / String / Bool / null coalesce at decode time).

struct AnyCodable: Codable, Sendable, CustomStringConvertible {
    let value: (any Sendable)?

    var description: String { stringValue }

    var stringValue: String {
        switch value {
        case let s as String: return s
        case let n as Int: return "\(n)"
        case let d as Double: return "\(d)"
        case let b as Bool: return b ? "true" : "false"
        default: return ""
        }
    }

    var intValue: Int? {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch value {
        case let b as Bool: return b
        case let n as Int: return n != 0
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    init(_ value: (any Sendable)?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try container.encode(b)
        case let n as Int: try container.encode(n)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        default: try container.encodeNil()
        }
    }
}
