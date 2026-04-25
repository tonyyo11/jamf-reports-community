import Foundation

/// Fictional org "Meridian Health" — ported verbatim from `data.jsx` in the design
/// handoff. Used by SwiftUI previews and the in-app Demo Mode toggle. No real
/// customer data ever reaches this file.
enum DemoData {

    static let org = Org(
        name: "Meridian Health",
        short: "MERIDIAN",
        jamfURL: "https://meridian.jamfcloud.com",
        profile: "meridian-prod",
        apiClient: "jrc-reporting-svc",
        workspaceRoot: "~/Jamf-Reports/meridian-prod"
    )

    // 26 weekly snapshots, ending 2026-04-20.
    static let trendDates: [String] = {
        var dates: [String] = []
        let cal = Calendar(identifier: .iso8601)
        var end = DateComponents(calendar: cal, year: 2026, month: 4, day: 20).date!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for i in stride(from: 25, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -i * 7, to: end)!
            dates.append(formatter.string(from: d))
        }
        return dates
    }()

    /// Reproducible synthetic trend (deterministic — no `Math.random()` jitter so
    /// SwiftUI previews are stable across launches).
    static func trend(start: Double, end: Double, jitter: Double = 6, n: Int = 26) -> [Double] {
        (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            let v = start + (end - start) * t + sin(Double(i) * 1.3) * jitter
            return (v * 10).rounded() / 10
        }
    }

    static let trends: [TrendSeries.Metric: [Double]] = [
        .fileVault:   trend(start: 78,  end: 96, jitter: 2.2),
        .compliance:  trend(start: 54,  end: 81, jitter: 4),
        .stale:       trend(start: 48,  end: 22, jitter: 4),
        .osCurrent:   trend(start: 41,  end: 73, jitter: 5),
        .crowdstrike: trend(start: 82,  end: 94, jitter: 2.8),
        .patch:       trend(start: 62,  end: 84, jitter: 4),
    ]

    static let totalDevicesTrend = trend(start: 486, end: 524, jitter: 3.5)

    static let osDistribution: [OSDistribution] = [
        .init(version: "macOS 15.4 (Sequoia)",   count: 287, pct: 54.8, colorHex: 0xC9970A, current: true),
        .init(version: "macOS 15.3.2",           count:  98, pct: 18.7, colorHex: 0xA87E08, current: true),
        .init(version: "macOS 14.7.4 (Sonoma)",  count:  84, pct: 16.0, colorHex: 0x7D8794, current: false),
        .init(version: "macOS 13.7.6 (Ventura)", count:  38, pct:  7.2, colorHex: 0x5A6068, current: false),
        .init(version: "macOS 12.7.6 (Monterey)",count:  17, pct:  3.2, colorHex: 0x4A4F55, current: false),
    ]

    static let securityAgents: [SecurityAgent] = [
        .init(name: "CrowdStrike Falcon",  installed: 488, pct: 93.1, column: "CrowdStrike Falcon - Status", trend: .up),
        .init(name: "1Password",           installed: 502, pct: 95.8, column: "1Password 8 - Installed", trend: .up),
        .init(name: "Splunk Forwarder",    installed: 451, pct: 86.1, column: "Splunk - Forwarder Status", trend: .flat),
        .init(name: "Beyond Identity",     installed: 423, pct: 80.7, column: "Beyond Identity - Enrolled", trend: .up),
        .init(name: "Tailscale",           installed: 389, pct: 74.2, column: "Tailscale - Connected", trend: .up),
    ]

    static let complianceBands: [ComplianceBand] = [
        .init(label: "Pass",            range: "0",     count: 213, pct: 42.4, colorHex: 0x2A6B6B),
        .init(label: "Low (1–10)",      range: "1–10",  count: 167, pct: 33.3, colorHex: 0x3A8A8A),
        .init(label: "Med-Low (11–30)", range: "11–30", count:  74, pct: 14.7, colorHex: 0xC9970A),
        .init(label: "Medium (31–50)",  range: "31–50", count:  31, pct:  6.2, colorHex: 0xFF9F0A),
        .init(label: "High (>50)",      range: "51+",   count:  17, pct:  3.4, colorHex: 0xFF453A),
    ]

    static let topFailingRules: [FailingRule] = [
        .init(ruleID: "os_sudo_log_enforce",                  fails: 134, baseline: "NIST 800-53r5 Mod"),
        .init(ruleID: "audit_acls_files_configure",           fails: 121, baseline: "NIST 800-53r5 Mod"),
        .init(ruleID: "system_settings_smbd_disable",         fails:  88, baseline: "NIST 800-53r5 Mod"),
        .init(ruleID: "pwpolicy_account_inactivity_enforce",  fails:  74, baseline: "NIST 800-53r5 Mod"),
        .init(ruleID: "audit_failure_halt",                   fails:  52, baseline: "NIST 800-53r5 Mod"),
        .init(ruleID: "system_settings_screensaver_password", fails:  41, baseline: "NIST 800-53r5 Mod"),
        .init(ruleID: "icloud_drive_disable",                 fails:  29, baseline: "NIST 800-53r5 Mod"),
    ]

    static let scheduledRuns: [Schedule] = [
        .init(name: "Weekly Executive Report", profile: "meridian-prod", schedule: "Monday · 07:00",
              cadence: "weekly", mode: .csvAssisted, next: "Apr 27, 07:00", last: "Apr 20, 07:02",
              lastStatus: .ok, artifacts: ["xlsx", "html"], enabled: true),
        .init(name: "Daily Snapshot Collection", profile: "meridian-prod", schedule: "Daily · 06:00",
              cadence: "daily", mode: .snapshotOnly, next: "Apr 26, 06:00", last: "Apr 25, 06:01",
              lastStatus: .ok, artifacts: [], enabled: true),
        .init(name: "Monthly Compliance Brief", profile: "harboredu", schedule: "1st · 06:00",
              cadence: "monthly", mode: .jamfCLIFull, next: "May 1, 06:00", last: "Apr 1, 06:14",
              lastStatus: .ok, artifacts: ["xlsx", "html", "csv"], enabled: true),
        .init(name: "Mobile Inventory (iPad)", profile: "meridian-prod", schedule: "Weekdays · 07:30",
              cadence: "weekdays", mode: .jamfCLIOnly, next: "Apr 27, 07:30", last: "Apr 24, 07:33",
              lastStatus: .warn, artifacts: ["xlsx"], enabled: true),
        .init(name: "Quarterly Audit Pull", profile: "dummy", schedule: "Disabled",
              cadence: "monthly", mode: .jamfCLIFull, next: "—", last: "Jan 1, 06:11",
              lastStatus: .ok, artifacts: ["xlsx", "csv"], enabled: false),
    ]

    static let cliProfiles: [JamfCLIProfile] = [
        .init(name: "meridian-prod", url: "meridian.jamfcloud.com", schedules: 3, status: .ok),
        .init(name: "harboredu",     url: "harbor.jamfcloud.com",   schedules: 1, status: .ok),
        .init(name: "dummy",         url: "sandbox.jamfcloud.com",  schedules: 1, status: .idle),
        .init(name: "prod",          url: "prod-msp.jamfcloud.com", schedules: 0, status: .idle),
    ]

    static let recentReports: [Report] = [
        .init(name: "meridian_jamf_report_2026-04-20_070218.xlsx", size: "1.2 MB", date: "Apr 20, 07:02", source: "Weekly Executive",   sheets: 18, devices: 524),
        .init(name: "meridian_jamf_report_2026-04-13_070141.xlsx", size: "1.2 MB", date: "Apr 13, 07:01", source: "Weekly Executive",   sheets: 18, devices: 519),
        .init(name: "meridian_compliance_2026-04-01_061412.xlsx",  size: "986 KB", date: "Apr 01, 06:14", source: "Monthly Compliance", sheets: 14, devices: 511),
        .init(name: "meridian_jamf_report_2026-04-06_070108.xlsx", size: "1.1 MB", date: "Apr 06, 07:01", source: "Weekly Executive",   sheets: 18, devices: 514),
        .init(name: "meridian_mobile_2026-04-24_073312.xlsx",      size: "412 KB", date: "Apr 24, 07:33", source: "Mobile Inventory",   sheets:  4, devices: 142),
        .init(name: "meridian_jamf_report_2026-03-30_070055.xlsx", size: "1.1 MB", date: "Mar 30, 07:00", source: "Weekly Executive",   sheets: 18, devices: 509),
    ]

    static let sheetCatalog: [SheetGroup] = [
        .init(group: "CSV-driven", items: [
            .init(name: "Device Inventory",    req: "csv", on: true),
            .init(name: "Stale Devices",       req: "csv", on: true),
            .init(name: "Security Controls",   req: "csv", on: true),
            .init(name: "Security Agents",     req: "csv", on: true),
            .init(name: "Compliance",          req: "csv", on: true),
        ]),
        .init(group: "jamf-cli (live)", items: [
            .init(name: "Fleet Overview",      req: "cli", on: true),
            .init(name: "Security Posture",    req: "cli", on: true),
            .init(name: "Inventory Summary",   req: "cli", on: true),
            .init(name: "Device Compliance",   req: "cli", on: true),
            .init(name: "EA Coverage",         req: "cli", on: true),
            .init(name: "EA Definitions",      req: "cli", on: false),
            .init(name: "Software Installs",   req: "cli", on: true),
            .init(name: "Package Lifecycle",   req: "cli", on: false),
            .init(name: "Policy Health",       req: "cli", on: true),
            .init(name: "Profile Status",      req: "cli", on: true),
            .init(name: "App Status",          req: "cli-1.2+", on: true),
            .init(name: "Patch Compliance",    req: "cli", on: true),
            .init(name: "Update Status",       req: "cli-1.2+", on: true),
        ]),
        .init(group: "Charts", items: [
            .init(name: "OS Adoption",         req: "chart", on: true),
            .init(name: "Compliance Trend",    req: "chart", on: true),
            .init(name: "Device State Trend",  req: "chart", on: true),
        ]),
        .init(group: "Platform API (preview)", items: [
            .init(name: "Platform Blueprints",        req: "platform", on: false),
            .init(name: "Platform Compliance Rules",  req: "platform", on: false),
            .init(name: "Platform DDM Status",        req: "platform", on: false),
        ]),
    ]

    static let columnMappings: [ColumnMapping] = [
        .init(key: "computer_name",     label: "Computer Name",      value: "Computer Name", required: true, status: .ok),
        .init(key: "serial_number",     label: "Serial Number",      value: "Serial Number", required: true, status: .ok),
        .init(key: "operating_system",  label: "macOS Version",      value: "Operating System Version", required: false, status: .ok),
        .init(key: "last_checkin",      label: "Last Check-in",      value: "Last Inventory Update",    required: false, status: .ok),
        .init(key: "department",        label: "Department",         value: "Department",               required: false, status: .ok),
        .init(key: "email",             label: "Primary Email",      value: "Email Address",            required: false, status: .ok),
        .init(key: "filevault",         label: "FileVault Status",   value: "FileVault 2 - Status",     required: false, status: .ok),
        .init(key: "sip",               label: "SIP",                value: "System Integrity Protection", required: false, status: .ok),
        .init(key: "firewall",          label: "Firewall",           value: "Firewall Enabled",          required: false, status: .ok),
        .init(key: "gatekeeper",        label: "Gatekeeper",         value: "Gatekeeper",                required: false, status: .ok),
        .init(key: "secure_boot",       label: "Secure Boot Level",  value: "Secure Boot Level",         required: false, status: .ok),
        .init(key: "bootstrap_token",   label: "Bootstrap Token",    value: "Bootstrap Token Escrowed",  required: false, status: .warn),
        .init(key: "disk_percent_full", label: "Disk Usage %",       value: "Boot Drive Percentage Full", required: false, status: .ok),
        .init(key: "manager",           label: "Manager (EA)",       value: "",                          required: false, status: .skip),
    ]

    static let customEAs: [CustomEA] = [
        .init(name: "Disk Usage", column: "Boot Drive Percentage Full", type: .percentage, warn: 80, crit: 90),
        .init(name: "macOS Version", column: "Operating System Version", type: .version, currentVersions: ["15.4", "15.3.2"]),
        .init(name: "Identity Cert Expiration", column: "Identity Certificate - Expiration Date", type: .date, warningDays: 60),
        .init(name: "FileVault Status", column: "FileVault 2 - Status", type: .boolean, trueValue: "Encrypted"),
        .init(name: "Patch Agent Status", column: "Patch Management - Agent Status", type: .text),
    ]

    static let deviceSample: [DeviceRow] = [
        .init(name: "MERIDIAN-JS-MBP", serial: "C02XK9PHJG5J", os: "15.4",   user: "j.silva@meridian.health",       dept: "Engineering", lastSeen: "2 min ago",  fileVault: true,  fails: 0,  model: "MacBook Pro 14\""),
        .init(name: "MERIDIAN-RC-MBA", serial: "FVFXK7H8Q6L4", os: "15.3.2", user: "r.chen@meridian.health",        dept: "Design",      lastSeen: "12 min ago", fileVault: true,  fails: 3,  model: "MacBook Air 13\""),
        .init(name: "MERIDIAN-AT-MBP", serial: "C02ZL3M9KM7H", os: "15.4",   user: "a.thompson@meridian.health",    dept: "Clinical",    lastSeen: "1 hr ago",   fileVault: true,  fails: 0,  model: "MacBook Pro 16\""),
        .init(name: "MERIDIAN-DK-MBA", serial: "FVFYK2N5P8R3", os: "14.7.4", user: "d.kim@meridian.health",         dept: "Finance",     lastSeen: "3 hr ago",   fileVault: true,  fails: 12, model: "MacBook Air 15\""),
        .init(name: "MERIDIAN-MR-MBP", serial: "C02ZM4P7QN9K", os: "15.4",   user: "m.rodriguez@meridian.health",   dept: "IT",          lastSeen: "5 hr ago",   fileVault: true,  fails: 0,  model: "MacBook Pro 14\""),
        .init(name: "MERIDIAN-LV-MBA", serial: "FVFXJ8L2R4M7", os: "13.7.6", user: "l.vasquez@meridian.health",     dept: "Operations",  lastSeen: "8 hr ago",   fileVault: false, fails: 47, model: "MacBook Air 13\""),
        .init(name: "MERIDIAN-PT-MBP", serial: "C02YK1N6P3Q8", os: "15.3.2", user: "p.tanaka@meridian.health",      dept: "Research",    lastSeen: "16 days",    fileVault: true,  fails: 18, model: "MacBook Pro 14\""),
        .init(name: "MERIDIAN-BS-MM",  serial: "FVFZL5M8N2K6", os: "15.4",   user: "b.singh@meridian.health",       dept: "Engineering", lastSeen: "1 hr ago",   fileVault: true,  fails: 0,  model: "Mac mini M4"),
    ]
}
