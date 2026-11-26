import Foundation

extension DemoData {
    /// The demo workspace's cross-platform overview. Only the newest demo summary carries an
    /// OS map, so each earlier week gets one derived from it: per platform, 6% of the newest
    /// major's devices per week back (60% at most) are still on the major before it. Those
    /// earlier days hold the map alone; nothing else reads them.
    static func platformOverview(for workspace: String) -> PlatformOverview {
        let summaries = fleetSummaries(for: workspace)
        guard let newest = summaries.last, let map = newest.osMajorCounts else { return .empty }
        // The workspace's own earlier dates: a later demo workspace's history ends sooner.
        let earlier = summaries.dropLast().map(\.date).reversed().enumerated()
            .map { weeksBack, date in
                DailySummary(
                    date: date, totalDevices: newest.totalDevices, fileVaultPct: nil,
                    compliancePct: nil, staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil,
                    patchPct: nil, osMajorCounts: rolledBack(map, weeks: weeksBack + 1))
            }
        return .build(earlier.reversed() + [newest])
    }

    private static func rolledBack(_ map: [String: Int], weeks: Int) -> [String: Int] {
        var result = map
        let byPlatform = Dictionary(grouping: map.keys.compactMap { key in
            PlatformOverview.parts(key).map { (key, $0.platform, $0.major) }
        }, by: \.1)
        for (_, keys) in byPlatform {
            let ordered = keys.sorted { $0.2 > $1.2 }
            guard ordered.count > 1, let count = map[ordered[0].0] else { continue }
            let moved = Int((Double(count) * min(0.06 * Double(weeks), 0.6)).rounded())
            result[ordered[0].0] = count - moved
            result[ordered[1].0, default: 0] += moved
        }
        return result
    }
}
