import Foundation

/// One Fleet Overview tile drawn from the daily summary's device maps (mobile spec M6): Mac
/// models, operating systems, mobile device types and last seen. A map the summary lacks draws
/// no tile, and a bucket nobody is in draws no row (absent, never 0). Map keys are data and are
/// shown as written; only "Other" and the bucket names are the app's words.
struct FleetDeviceMapTile: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let label: String
        let count: Int
    }

    let title: String
    let rows: [Row]

    static func tiles(_ summary: DailySummary?) -> [FleetDeviceMapTile] {
        guard let summary else { return [] }
        return [
            tile(L("Mac models"), summary.modelFamilyCounts.map(byCount)),
            tile(L("Operating systems"), summary.osMajorCounts.map(byPlatformAndMajor)),
            tile(L("Mobile device types"), summary.mobileFormFactorCounts.map(byCount)),
            tile(L("Macs last seen"), summary.lastSeenBuckets?.computers.map(lastSeen)),
            tile(L("Mobile devices last seen"), summary.lastSeenBuckets?.mobile.map(lastSeen)),
        ].compactMap { $0 }
    }

    private static func tile(_ title: String, _ rows: [Row]?) -> FleetDeviceMapTile? {
        guard let rows, !rows.isEmpty else { return nil }
        return FleetDeviceMapTile(title: title, rows: rows)
    }

    private static let otherKey = "Other"

    private static func label(_ key: String) -> String { key == otherKey ? L("Other") : key }

    /// Most devices first, then by name; "Other" last whatever its count.
    private static func byCount(_ map: [String: Int]) -> [Row] {
        map.sorted {
            if ($0.key == otherKey) != ($1.key == otherKey) { return $1.key == otherKey }
            return $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map { Row(label: label($0.key), count: $0.value) }
    }

    /// macOS first, then the other platforms by name; within one, the newest major first,
    /// compared as a number so "macOS 9" follows "macOS 10".
    private static func byPlatformAndMajor(_ map: [String: Int]) -> [Row] {
        func split(_ key: String) -> (platform: String, major: Int) {
            let parts = key.split(separator: " ")
            guard parts.count > 1, let major = parts.last.flatMap({ Int($0) }) else {
                return (key, -1)
            }
            return (parts.dropLast().joined(separator: " "), major)
        }
        return map.sorted {
            let a = split($0.key), b = split($1.key)
            if a.platform != b.platform {
                if a.platform == "macOS" || b.platform == "macOS" { return a.platform == "macOS" }
                return a.platform < b.platform
            }
            return a.major != b.major ? a.major > b.major : $0.key < $1.key
        }.map { Row(label: label($0.key), count: $0.value) }
    }

    private static func lastSeen(_ counts: LastSeenBuckets.Counts) -> [Row] {
        [(L("Under a day"), counts.underOneDay), (L("1 to 6 days"), counts.underSevenDays),
         (L("7 days or more"), counts.sevenDaysOrMore), (L("Never"), counts.never)]
            .compactMap { label, count in count.map { Row(label: label, count: $0) } }
    }
}
