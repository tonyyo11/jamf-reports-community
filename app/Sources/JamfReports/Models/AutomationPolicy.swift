import Foundation

/// Global automation policy for the v2.2.0 managed-agent layer
/// ("set policy, not cron jobs").
///
/// Serialized to a single `@AppStorage` JSON string (`storageKey`). Every field
/// has a safe default, and decoding is lenient (a missing key keeps that field's
/// default) so adding a field in a later build never wipes a user's saved
/// policy.
///
/// `isManaged` is the master switch and defaults **off**: until the operator
/// opts in (Phase 5 Automation UI / Phase 6 migration), `ManagedAutomation`
/// installs nothing and removes nothing, so existing hand-built schedules are
/// untouched.
struct AutomationPolicy: Codable, Sendable, Equatable {

    /// Report cadence applied uniformly to all profiles.
    enum ReportsCadence: String, Codable, Sendable, CaseIterable {
        case off, daily, weekly, monthly
    }

    /// Master switch. When false, `ManagedAutomation.reconcile` tears down any
    /// managed agents and installs none.
    var isManaged: Bool
    /// Daily light freshness collect (tiers refresh+inventory) for all profiles.
    /// This is what writes a daily `summary_<date>.json` per profile → a daily
    /// trend point.
    var freshnessEnabled: Bool
    /// Weekly heavy scan — only the two `--scan-failures` fan-outs
    /// (update-device-failures + patch-device-failures), the per-device-heavy
    /// queries kept off the daily path.
    var scanEnabled: Bool
    /// Weekday the weekly scan runs (0=Sunday … 6=Saturday).
    var scanWeekday: Int
    /// Report cadence for all profiles.
    var reportsCadence: ReportsCadence
    /// Weekday for weekly reports (0=Sunday … 6=Saturday).
    var reportsWeekday: Int
    /// Day of month (1…28) for monthly reports.
    var reportsDayOfMonth: Int
    /// Optional weekly configuration backup (`jamf-cli pro backup`).
    var backupsEnabled: Bool
    /// Weekday for the weekly backup (0=Sunday … 6=Saturday).
    var backupsWeekday: Int
    /// Shared base run time "HH:mm". Managed agents are staggered off this so
    /// on-prem Jamf Pro is not hit by all of them at once.
    var runTime: String
    /// Profiles excluded from all managed automation (run-time exclusion —
    /// discovered set minus these).
    var excludedProfiles: [String]
    /// Report grouping (v2.2.0 Phase 4). Each group's profiles roll up into ONE
    /// consolidated fleet report; profiles in no group get a per-profile report.
    /// Empty (default) → every profile reports on its own, preserving prior
    /// behaviour. A single org can combine prod/dev/sandbox into one "fleet"
    /// group; an MSP makes one group per customer.
    var reportGroups: [ReportGroup]

    static let storageKey = "automationPolicy"

    init(
        isManaged: Bool = false,
        freshnessEnabled: Bool = true,
        scanEnabled: Bool = true,
        scanWeekday: Int = 1,
        reportsCadence: ReportsCadence = .weekly,
        reportsWeekday: Int = 1,
        reportsDayOfMonth: Int = 1,
        backupsEnabled: Bool = false,
        backupsWeekday: Int = 0,
        runTime: String = "06:00",
        excludedProfiles: [String] = [],
        reportGroups: [ReportGroup] = []
    ) {
        self.isManaged = isManaged
        self.freshnessEnabled = freshnessEnabled
        self.scanEnabled = scanEnabled
        self.scanWeekday = scanWeekday
        self.reportsCadence = reportsCadence
        self.reportsWeekday = reportsWeekday
        self.reportsDayOfMonth = reportsDayOfMonth
        self.backupsEnabled = backupsEnabled
        self.backupsWeekday = backupsWeekday
        self.runTime = runTime
        self.excludedProfiles = excludedProfiles
        self.reportGroups = reportGroups
    }

    // Lenient decoding: a key absent from older saved JSON falls back to the
    // default for that field instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutomationPolicy()
        isManaged = try c.decodeIfPresent(Bool.self, forKey: .isManaged) ?? d.isManaged
        freshnessEnabled = try c.decodeIfPresent(Bool.self, forKey: .freshnessEnabled) ?? d.freshnessEnabled
        scanEnabled = try c.decodeIfPresent(Bool.self, forKey: .scanEnabled) ?? d.scanEnabled
        scanWeekday = try c.decodeIfPresent(Int.self, forKey: .scanWeekday) ?? d.scanWeekday
        reportsCadence = try c.decodeIfPresent(ReportsCadence.self, forKey: .reportsCadence) ?? d.reportsCadence
        reportsWeekday = try c.decodeIfPresent(Int.self, forKey: .reportsWeekday) ?? d.reportsWeekday
        reportsDayOfMonth = try c.decodeIfPresent(Int.self, forKey: .reportsDayOfMonth) ?? d.reportsDayOfMonth
        backupsEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupsEnabled) ?? d.backupsEnabled
        backupsWeekday = try c.decodeIfPresent(Int.self, forKey: .backupsWeekday) ?? d.backupsWeekday
        runTime = try c.decodeIfPresent(String.self, forKey: .runTime) ?? d.runTime
        excludedProfiles = try c.decodeIfPresent([String].self, forKey: .excludedProfiles) ?? d.excludedProfiles
        reportGroups = try c.decodeIfPresent([ReportGroup].self, forKey: .reportGroups) ?? d.reportGroups
    }

    /// Parse a stored `@AppStorage` JSON string. Any decode failure (corrupt or
    /// empty value) returns the all-defaults policy.
    static func parse(_ raw: String) -> AutomationPolicy {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AutomationPolicy.self, from: data) else {
            return AutomationPolicy()
        }
        return decoded
    }

    /// Encode to a JSON string for `@AppStorage`. Returns "" on the (practically
    /// impossible) encode failure, which `parse` reads back as defaults.
    func serialize() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Read the current policy straight from `UserDefaults` — for non-View
    /// callers (e.g. the launch reconcile) that can't use `@AppStorage`.
    static func current(defaults: UserDefaults = .standard) -> AutomationPolicy {
        guard let raw = defaults.string(forKey: storageKey) else { return AutomationPolicy() }
        return parse(raw)
    }
}

/// A named set of profiles that roll up into one consolidated fleet report.
struct ReportGroup: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var profiles: [String]

    init(name: String, profiles: [String]) {
        self.name = name
        self.profiles = profiles
    }
}

