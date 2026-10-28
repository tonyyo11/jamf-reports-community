import Foundation
import Synchronization

/// The `mobile` figures for days summarized without them (mobile spec 4.3), rebuilt from the
/// newest `mobile-devices-list` snapshot stamped that same local day, the way
/// `resolvingAgentCoverage` rebuilds agent history: read-time only, the newest
/// `mobileBackfillMaxDays` such days, each file decoded once per session. Same day only: a
/// share from a snapshot days older would read as that day's figure. OS currency is never
/// backfilled (the cached feed is today's, and an old version list judged against it would read
/// as behind), and neither are update errors.
extension TrendStore {
    nonisolated static let mobileBackfillMaxDays = 21

    /// `resolvingMobile(_:dataDir:staleDays:)` for `profile`, with its data folder and
    /// `thresholds.stale_device_days`. Off the main actor.
    nonisolated static func resolvingMobile(
        _ summaries: [DailySummary], profile: String
    ) -> [DailySummary] {
        guard summaries.contains(where: { $0.mobile == nil }),
              let workspace = ProfileService.workspaceURL(for: profile) else { return summaries }
        let dataDir = (try? WorkspacePaths.dataDir(for: profile))
            ?? workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let config = try? ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        return resolvingMobile(
            summaries, dataDir: dataDir, staleDays: config?.thresholds?.resolvedStaleDays ?? 30)
    }

    /// `summaries` with `mobile` filled where it is missing and a same-day snapshot supplies it,
    /// each judged as of its own stamp. Order is unchanged.
    nonisolated static func resolvingMobile(
        _ summaries: [DailySummary], dataDir: URL, staleDays: Int
    ) -> [DailySummary] {
        let days = Set(summaries.filter { $0.mobile == nil }.map(\.date))
        guard !days.isEmpty else { return summaries }
        var newestByDay: [String: (url: URL, date: Date)] = [:]
        for snapshot in datedSnapshots(of: MobileFleetService.deviceKind, in: dataDir) {
            let day = SummaryJSONParser.dateFormatter.string(from: snapshot.date)
            if days.contains(day) { newestByDay[day] = snapshot }  // oldest first: newest wins
        }
        var figures: [String: MobileSummary] = [:]
        for day in newestByDay.keys.sorted(by: >).prefix(mobileBackfillMaxDays) {
            guard let snapshot = newestByDay[day] else { continue }
            let key = "\(snapshot.url.path)|\(staleDays)"
            figures[day] = MobileBackfillCache.shared.figures(for: key) {
                BoundedFile.readLogged(snapshot.url).flatMap {
                    MobileSummary.fromMobileDevicesList(
                        $0, latestByMajor: [:], staleDays: staleDays, now: snapshot.date)
                }
            }
        }
        guard !figures.isEmpty else { return summaries }
        return summaries.map { summary in
            guard summary.mobile == nil, let found = figures[summary.date] else { return summary }
            return summary.withBackfilledMobile(found)
        }
    }
}

/// Per-session memory of each dated snapshot's figures; a nil entry records a file that could
/// not be used, which is not retried either.
private final class MobileBackfillCache: Sendable {
    static let shared = MobileBackfillCache()
    private let entries = Mutex<[String: MobileSummary?]>([:])

    func figures(for key: String, compute: () -> MobileSummary?) -> MobileSummary? {
        if let hit = entries.withLock({ $0[key] }) { return hit }
        let value = compute()
        entries.withLock { $0[key] = value }
        return value
    }
}
