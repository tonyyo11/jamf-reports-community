import Foundation

/// Stale device bucketing service for the v3.5 "Offline Outreach Report" workflow.
/// Buckets devices by days-since-checkin tiers and surfaces manager/email/department
/// for outreach workflows. One-click email list generation for each tier.
struct StaleDeviceService: Sendable {

    enum Tier: String, CaseIterable, Sendable {
        case recent   // 0-30 days
        case offline  // 31-90 days
        case inactive // 91-180 days
        case dormant  // 180+ days

        var label: String {
            switch self {
            case .recent:  return "Recent"
            case .offline: return "Offline"
            case .inactive: return "Inactive"
            case .dormant:  return "Dormant"
            }
        }

        var colorHex: UInt32 {
            switch self {
            case .recent:  return 0x30D158  // green - Theme.Colors.ok
            case .offline: return 0xE8B614  // gold - Theme.Colors.goldBright
            case .inactive: return 0xFF9F0A  // warn - Theme.Colors.warn
            case .dormant:  return 0xFF453A  // danger - Theme.Colors.danger
            }
        }

        func contains(_ days: Int) -> Bool {
            switch self {
            case .recent:  return days <= 30
            case .offline: return days >= 31 && days <= 90
            case .inactive: return days >= 91 && days <= 180
            case .dormant:  return days > 180
            }
        }

        static func tier(for days: Int?) -> Tier {
            guard let days else { return .recent }
            for tier in Self.allCases {
                if tier.contains(days) { return tier }
            }
            return .recent
        }
    }

    struct Snapshot: Sendable {
        let totalDevices: Int
        let tierCounts: [Tier: Int]
        let devicesByTier: [Tier: [DeviceInventoryRecord]]
        let sourceFile: URL?
        /// Most-recent device check-in date. Fed to `PageHeader.lastModified`
        /// for human display only — not used for freshness. See `dataCollectedDate`.
        let snapshotDate: Date?
        /// Mtime of the newest source file (JSON/CSV) loaded by
        /// `DeviceInventoryService`. Used for `cacheSource` freshness; distinct
        /// from `snapshotDate` (which reflects device activity, not collection time).
        let dataCollectedDate: Date?

        /// Freshness signal for `StaleDataBanner`. Uses the 36-hour window shared
        /// with other dashboard services (aligns with the standard daily cadence).
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: dataCollectedDate, withinHours: 36)
        }

        static let empty: Snapshot = {
            var tierCounts: [Tier: Int] = [:]
            var devicesByTier: [Tier: [DeviceInventoryRecord]] = [:]
            for tier in Tier.allCases {
                tierCounts[tier] = 0
                devicesByTier[tier] = []
            }
            return Snapshot(
                totalDevices: 0,
                tierCounts: tierCounts,
                devicesByTier: devicesByTier,
                sourceFile: nil,
                snapshotDate: nil,
                dataCollectedDate: nil
            )
        }()
    }

    /// Load devices for the profile and build stale device tiers.
    /// Returns `.empty` when no device data is available.
    static func snapshot(profile: String, demoMode: Bool) -> Snapshot {
        let deviceSnapshot = DeviceInventoryService.load(profile: profile, demoMode: demoMode)
        return snapshot(from: deviceSnapshot.devices, dataCollectedDate: deviceSnapshot.generatedDate)
    }

    /// Pure function test seam: build snapshot from device records.
    /// `dataCollectedDate` should be the source-file mtime from `DeviceInventoryService`
    /// so that `cacheSource` reflects collection time, not device activity time.
    static func snapshot(from records: [DeviceInventoryRecord], dataCollectedDate: Date? = nil) -> Snapshot {
        guard !records.isEmpty else {
            // Preserve dataCollectedDate so cacheSource reflects collection time
            // even when no devices have been inventoried yet.
            guard let collected = dataCollectedDate else { return .empty }
            let base = Snapshot.empty
            return Snapshot(
                totalDevices: base.totalDevices,
                tierCounts: base.tierCounts,
                devicesByTier: base.devicesByTier,
                sourceFile: nil,
                snapshotDate: nil,
                dataCollectedDate: collected
            )
        }

        var tierCounts: [Tier: Int] = [:]
        var devicesByTier: [Tier: [DeviceInventoryRecord]] = [:]

        // Initialize all tiers
        for tier in Tier.allCases {
            tierCounts[tier] = 0
            devicesByTier[tier] = []
        }

        // Bucket devices by tier
        for record in records {
            let tier = Tier.tier(for: record.daysSinceContact)
            tierCounts[tier, default: 0] += 1
            devicesByTier[tier, default: []].append(record)
        }

        // Sort devices within each tier: most-stale first (descending by daysSinceContact)
        for tier in Tier.allCases {
            devicesByTier[tier]?.sort { lhs, rhs in
                let lhsDays = lhs.daysSinceContact ?? 0
                let rhsDays = rhs.daysSinceContact ?? 0
                return lhsDays > rhsDays
            }
        }

        // Find most recent lastContact date for snapshotDate
        let contactDates = records.compactMap { record -> Date? in
            guard !record.lastContact.isEmpty else { return nil }
            return parseDate(record.lastContact)
        }
        let mostRecentContact = contactDates.max()

        return Snapshot(
            totalDevices: records.count,
            tierCounts: tierCounts,
            devicesByTier: devicesByTier,
            sourceFile: nil,
            snapshotDate: mostRecentContact,
            dataCollectedDate: dataCollectedDate
        )
    }

    // MARK: - CSV export

    /// Column header for the standalone outreach CSV.
    static let outreachCSVHeader = "Device Name,Serial,Username,Email,Last Check-in,Stale Tier"

    /// Render all stale-tier records as a standalone CSV across every tier.
    /// Rows are ordered by tier (offline → inactive → dormant → recent) then by
    /// most-stale first within each tier — matching the on-screen table order.
    ///
    /// Every cell is formula-injection-neutralized (leading `=`, `+`, `-`, `@`
    /// get a tab prefix) and RFC 4180–quoted when needed, matching the contract
    /// of `PatchStatusService.complianceCSV`.
    static func outreachCSV(_ snapshot: Snapshot) -> String {
        var lines = [outreachCSVHeader]
        for tier in [Tier.offline, .inactive, .dormant, .recent] {
            for device in snapshot.devicesByTier[tier] ?? [] {
                let cells = [
                    device.name,
                    device.serial,
                    device.user,
                    device.email,
                    device.lastContact,
                    tier.label,
                ]
                lines.append(cells.map(csvField).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escape a value for CSV output. Neutralizes spreadsheet formula injection
    /// (leading `=`, `+`, `-`, `@` get a tab prefix) and applies RFC 4180
    /// quoting — matches `PatchStatusService.csvField` exactly.
    static func csvField(_ value: String) -> String {
        var field = value
        if let first = field.first, "=+-@".contains(first) {
            field = "\t" + field
        }
        guard field.contains(where: { ",\"\n\r".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Helpers

    private static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy HH:mm", "MM/dd/yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}