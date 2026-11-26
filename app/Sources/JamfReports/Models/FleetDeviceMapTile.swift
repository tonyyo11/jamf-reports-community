import Foundation

/// One Fleet Overview "last seen" tile from the daily summary's `lastSeenBuckets` (mobile spec
/// M6); the other maps are drawn per platform (`PlatformOverview`). A half the summary lacks
/// draws no tile, and a bucket nobody is in draws no row (absent, never 0).
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
            tile(L("Macs last seen"), summary.lastSeenBuckets?.computers.map(lastSeen)),
            tile(L("Mobile devices last seen"), summary.lastSeenBuckets?.mobile.map(lastSeen)),
        ].compactMap { $0 }
    }

    private static func tile(_ title: String, _ rows: [Row]?) -> FleetDeviceMapTile? {
        guard let rows, !rows.isEmpty else { return nil }
        return FleetDeviceMapTile(title: title, rows: rows)
    }

    private static func lastSeen(_ counts: LastSeenBuckets.Counts) -> [Row] {
        [(L("Under a day"), counts.underOneDay), (L("1 to 6 days"), counts.underSevenDays),
         (L("7 days or more"), counts.sevenDaysOrMore), (L("Never"), counts.never)]
            .compactMap { label, count in count.map { Row(label: label, count: $0) } }
    }
}
