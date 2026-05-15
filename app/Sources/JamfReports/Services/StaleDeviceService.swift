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
        let snapshotDate: Date?

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
                snapshotDate: nil
            )
        }()
    }

    /// Load devices for the profile and build stale device tiers.
    /// Returns `.empty` when no device data is available.
    static func snapshot(profile: String, demoMode: Bool) -> Snapshot {
        let deviceSnapshot = DeviceInventoryService.load(profile: profile, demoMode: demoMode)
        return snapshot(from: deviceSnapshot.devices)
    }

    /// Pure function test seam: build snapshot from device records.
    static func snapshot(from records: [DeviceInventoryRecord]) -> Snapshot {
        guard !records.isEmpty else { return .empty }

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
            snapshotDate: mostRecentContact
        )
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