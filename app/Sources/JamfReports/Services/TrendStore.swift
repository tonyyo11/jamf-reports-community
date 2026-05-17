import Foundation
import Observation

struct TrendPoint: Identifiable, Sendable, Equatable {
    let date: Date
    let value: Double

    var id: Date { date }
}

@Observable final class TrendStore: CacheSourceProviding {
    private var allSummaries: [DailySummary] = []
    private(set) var filteredSummaries: [DailySummary] = []
    private(set) var currentProfile: String?
    private(set) var currentRange: TrendRange = .w4
    /// Most-recent summary file mtime for the active profile, captured at
    /// load/reload time. Drives `cacheSource` so `StaleDataBanner` can
    /// surface freshness without re-reading the filesystem on every render.
    /// Nil when no summary files exist on disk.
    private(set) var latestSnapshotDate: Date?
    /// True when at least one summary file with `source == "jamf-cli"`
    /// (i.e., produced by a real live run, not a demo/legacy import) exists
    /// for the active profile. Distinguishes `.stale` from `.neverFetchedLive`.
    private(set) var hasEverFetchedLive: Bool = false

    init(summaries: [DailySummary] = [], range: TrendRange = .w4) {
        allSummaries = summaries
        currentRange = range
        hasEverFetchedLive = summaries.contains(where: { $0.source == "jamf-cli" })
        filterSummaries(range: range)
    }

    func load(profile: String, range: TrendRange) {
        if profile != currentProfile {
            allSummaries = readSummaries(profile: profile)
            latestSnapshotDate = readLatestSnapshotMTime(profile: profile)
            hasEverFetchedLive = allSummaries.contains(where: { $0.source == "jamf-cli" })
            currentProfile = profile
        }

        currentRange = range
        filterSummaries(range: range)
    }

    /// Force a re-scan of the on-disk summaries directory for the active
    /// profile. The cheap `load(profile:range:)` short-circuits when the
    /// profile is unchanged; callers that just generated a new summary use
    /// `reload()` to invalidate that cache.
    func reload() {
        guard let profile = currentProfile else { return }
        allSummaries = readSummaries(profile: profile)
        latestSnapshotDate = readLatestSnapshotMTime(profile: profile)
        hasEverFetchedLive = allSummaries.contains(where: { $0.source == "jamf-cli" })
        filterSummaries(range: currentRange)
    }

    /// Freshness signal for `StaleDataBanner` consumers. `.neverFetchedLive`
    /// when no jamf-cli-sourced summary file exists; `.fresh` when the newest
    /// summary mtime is within the 36-hour window (daily-schedule cadence
    /// plus a half-day slack); `.stale(at:)` otherwise.
    ///
    /// 36h was picked over 24h so a once-daily LaunchAgent that drifts a
    /// few hours late (or runs at an odd hour on Sunday after weekend
    /// shutdown) does not trip the banner on the next weekday morning.
    var cacheSource: CacheSource {
        guard hasEverFetchedLive else { return .neverFetchedLive }
        return CacheSource.from(snapshotDate: latestSnapshotDate, withinHours: 36)
    }

    /// Read summaries from the configured `charts.historical_csv_dir/summaries`
    /// (or the workspace fallback if config is unavailable).
    private func readSummaries(profile: String) -> [DailySummary] {
        // Validate at the boundary — string-interpolating an unvalidated profile
        // into a path component is a traversal vector.
        guard let summariesDir = (try? WorkspacePaths.summariesDir(for: profile))
            ?? fallbackSummariesDir(for: profile) else {
            return []
        }
        return SummaryJSONParser.parseDirectory(summariesDir)
    }

    private func fallbackSummariesDir(for profile: String) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        return workspace.appendingPathComponent("snapshots/summaries", isDirectory: true)
    }

    /// Scan the summaries directory for the newest `summary_*.json` mtime.
    /// We read the filesystem timestamp rather than parsing each file's
    /// embedded date because the user-visible "stale" signal is when the
    /// last *run* happened, which `contentModificationDate` captures
    /// directly (even if the summary's logical date string lags).
    private func readLatestSnapshotMTime(profile: String) -> Date? {
        guard let summariesDir = (try? WorkspacePaths.summariesDir(for: profile))
            ?? fallbackSummariesDir(for: profile) else {
            return nil
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: summariesDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("summary_") && $0.pathExtension == "json" }
            .compactMap { url -> Date? in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            .max()
    }

    private func filterSummaries(range: TrendRange) {
        guard !allSummaries.isEmpty else {
            filteredSummaries = []
            return
        }

        // newest first to find the anchor date
        let sorted = allSummaries.sorted { $0.date > $1.date }
        let latestDate = sorted.first?.parsedDate ?? Date()
        let calendar = Calendar(identifier: .iso8601)

        let startDate: Date? = {
            switch range {
            case .w4:  return calendar.date(byAdding: .weekOfYear, value: -4, to: latestDate)
            case .w12: return calendar.date(byAdding: .weekOfYear, value: -12, to: latestDate)
            case .w26: return calendar.date(byAdding: .weekOfYear, value: -26, to: latestDate)
            case .w52: return calendar.date(byAdding: .weekOfYear, value: -52, to: latestDate)
            case .all: return nil
            }
        }()

        if let startDate = startDate {
            filteredSummaries = allSummaries
                .filter { $0.parsedDate >= startDate }
                .sorted { $0.date < $1.date }
        } else {
            filteredSummaries = allSummaries.sorted { $0.date < $1.date }
        }
    }

    /// The time domain for the X-axis, spanning from the calculated start
    /// of the range to the newest snapshot.
    var chartDomain: ClosedRange<Date>? {
        guard !allSummaries.isEmpty else { return nil }
        let sorted = allSummaries.sorted { $0.date > $1.date }
        let latestDate = sorted.first?.parsedDate ?? Date()
        let calendar = Calendar(identifier: .iso8601)

        let startDate: Date = {
            switch currentRange {
            case .w4:  return calendar.date(byAdding: .weekOfYear, value: -4, to: latestDate) ?? latestDate
            case .w12: return calendar.date(byAdding: .weekOfYear, value: -12, to: latestDate) ?? latestDate
            case .w26: return calendar.date(byAdding: .weekOfYear, value: -26, to: latestDate) ?? latestDate
            case .w52: return calendar.date(byAdding: .weekOfYear, value: -52, to: latestDate) ?? latestDate
            case .all: return allSummaries.map(\.parsedDate).min() ?? latestDate
            }
        }()

        return startDate...latestDate
    }

    /// Date/value pairs for `metric`. Optional metrics (compliance,
    /// crowdstrike, stability) are omitted when nil while keeping each value
    /// attached to its original snapshot date.
    func points(metric: TrendSeries.Metric) -> [TrendPoint] {
        filteredSummaries.compactMap { summary -> TrendPoint? in
            guard let value = value(for: metric, in: summary) else { return nil }
            return TrendPoint(date: summary.parsedDate, value: value)
        }
    }

    /// Series values for `metric`. Kept for existing summary-only callers;
    /// `points(metric:)` should be used when dates are rendered with values.
    func values(metric: TrendSeries.Metric) -> [Double] {
        points(metric: metric).map(\.value)
    }

    private func value(for metric: TrendSeries.Metric, in summary: DailySummary) -> Double? {
        switch metric {
        case .stability:     return summary.stabilityIndex
        case .activeDevices: return Double(summary.totalDevices)
        case .compliance:    return summary.compliancePct
        case .fileVault:     return summary.fileVaultPct
        case .osCurrent:     return summary.osCurrentPct
        case .crowdstrike:   return summary.crowdstrikePct
        case .stale:         return Double(summary.staleCount)
        case .patch:         return summary.patchPct
        case .securityScore: return summary.securityScore
        }
    }

    func dates() -> [Date] {
        filteredSummaries.map { $0.parsedDate }
    }

    var isEmpty: Bool {
        allSummaries.isEmpty
    }
}
