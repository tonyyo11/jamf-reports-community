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

    /// Cached band-history from both ea-results snapshots (primary) and
    /// summary.json mscpBands (fallback). Rebuilt once per load/reload; never
    /// re-scanned during view rendering.
    private var cachedBandPoints: [MSCPChartDataBuilder.BandPoint] = []

    /// The primary baseline used to build `cachedBandPoints`. Matches the
    /// first resolved baseline from config when loaded from disk, or the
    /// first key found in summary mscpBands when constructed in-memory.
    private var cachedBaseline: ComplianceBaselineConfig?

    init(summaries: [DailySummary] = [], range: TrendRange = .w4) {
        allSummaries = summaries
        currentRange = range
        hasEverFetchedLive = summaries.contains(where: { $0.source == "jamf-cli" })
        filterSummaries(range: range)
        // In-memory init: build band points from summaries only. The inaccessible
        // dataDir degrades gracefully to summaries-only inside buildSeries.
        rebuildBandPoints(profile: nil)
    }

    func load(profile: String, range: TrendRange) {
        if profile != currentProfile {
            allSummaries = readSummaries(profile: profile)
            latestSnapshotDate = readLatestSnapshotMTime(profile: profile)
            hasEverFetchedLive = allSummaries.contains(where: { $0.source == "jamf-cli" })
            currentProfile = profile
            rebuildBandPoints(profile: profile)
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
        rebuildBandPoints(profile: profile)
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
        case .edrAgent:      return summary.crowdstrikePct
        case .stale:         return Double(summary.staleCount)
        case .patch:         return summary.patchPct
        case .securityScore: return summary.securityScore
        case .mscpBandTrend:
            // Derive from cachedBandPoints: find the point whose date matches
            // this summary's date (string-matched), then sum the 5 bands.
            // Falls back to summary.mscpBands when no ea-results point exists.
            let dayKey = summary.date
            if let pt = cachedBandPoints.first(where: {
                SummaryJSONParser.dateFormatter.string(from: $0.date) == dayKey
            }) {
                let total = pt.counts.pass + pt.counts.low + pt.counts.medLow
                    + pt.counts.medium + pt.counts.high
                return total > 0 ? Double(total) : nil
            }
            // Summary-only fallback for in-memory paths where cachedBandPoints
            // was built from summaries and the date keys match exactly.
            guard let bands = summary.mscpBands, !bands.isEmpty else { return nil }
            let totalWithData = bands.values.map { $0.total - $0.noData }.reduce(0, max)
            return totalWithData > 0 ? Double(totalWithData) : nil
        }
    }

    func dates() -> [Date] {
        filteredSummaries.map { $0.parsedDate }
    }

    var isEmpty: Bool {
        allSummaries.isEmpty
    }

    /// True when band-history data is available from either ea-results snapshots
    /// or summary.json mscpBands. The pill for `.mscpBandTrend` is visible only
    /// when this is true.
    var hasMSCPBandHistory: Bool {
        !cachedBandPoints.isEmpty
    }

    /// X-axis domain for the mSCP band stacked-area chart.
    ///
    /// Prefers `chartDomain` (summary-driven) so the axis matches the rest of
    /// the Trends screen. Falls back to a domain derived from `cachedBandPoints`
    /// when summaries are absent (e.g. deleted or interrupted collect) but
    /// ea-results-only band data exists. Returns `nil` only when both sources
    /// are empty, in which case the band chart shows the unavailable empty-state.
    var bandChartDomain: ClosedRange<Date>? {
        if let domain = chartDomain { return domain }
        guard let first = cachedBandPoints.first?.date,
              let last  = cachedBandPoints.last?.date else { return nil }
        return first <= last ? first...last : last...first
    }

    /// Returns the primary baseline name for mSCP band trending.
    var primaryMSCPBaseline: String? {
        cachedBaseline?.name
    }

    /// Build mSCP stacked-area chart series for the primary baseline,
    /// range-filtered to match `filteredSummaries`.
    ///
    /// Returns 5 series (Pass, Low, Med-Low, Medium, High) with device counts.
    /// Used by TrendsView when metric == .mscpBandTrend.
    func mscpStackedSeries() -> [ChartSeries] {
        guard !cachedBandPoints.isEmpty else { return [] }

        // Determine the date range from filteredSummaries so the stackplot
        // respects the user-selected trend range.
        let rangeStart = filteredSummaries.first?.parsedDate
        let rangeEnd   = filteredSummaries.last?.parsedDate

        let inRange: [MSCPChartDataBuilder.BandPoint]
        if let start = rangeStart, let end = rangeEnd {
            inRange = cachedBandPoints.filter { $0.date >= start && $0.date <= end }
        } else {
            inRange = cachedBandPoints
        }

        return MSCPChartDataBuilder.toStackedSeries(points: inRange)
    }

    // MARK: - Band-point cache

    /// Rebuild `cachedBandPoints` from ea-results snapshots (primary) and
    /// summary.json mscpBands (fallback). Called once at load/reload time;
    /// never called during view rendering.
    ///
    /// When `profile` is nil (in-memory init path) there is no config.yaml or
    /// dataDir to read, so `buildSeries` runs with a non-existent dir and
    /// degrades to summaries-only. The existing tests that pass `summaries:`
    /// with mscpBands continue to work through this path.
    private func rebuildBandPoints(profile: String?) {
        // 1. Resolve the baseline to use.
        let baseline: ComplianceBaselineConfig
        let isSingleBaseline: Bool
        if let profile,
           let workspaceURL = ProfileService.workspaceURL(for: profile),
           let config = try? ConfigLoader.load(from: workspaceURL.appendingPathComponent("config.yaml")),
           let resolved = config.compliance?.resolvedBaselines.first {
            baseline = resolved
            isSingleBaseline = (config.compliance?.resolvedBaselines.count ?? 0) <= 1
        } else if let firstSummaryBaseline = firstBaselineFromSummaries() {
            baseline = firstSummaryBaseline
            // No config available; treat as single-baseline so the summary-only
            // coalesce path bridges any name drift in the fallback case.
            isSingleBaseline = true
        } else {
            cachedBandPoints = []
            cachedBaseline = nil
            return
        }
        cachedBaseline = baseline

        // 2. Resolve the data directory. Uses a non-existent temp URL when the
        //    profile is nil or dataDir lookup fails; buildSeries degrades to
        //    summaries-only gracefully.
        let dataDir: URL
        if let profile, let dir = try? WorkspacePaths.dataDir(for: profile) {
            dataDir = dir
        } else if let profile, let workspace = ProfileService.workspaceURL(for: profile) {
            dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        } else {
            // No on-disk path available; buildSeries will use summaries only.
            dataDir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        }

        cachedBandPoints = MSCPChartDataBuilder.buildSeries(
            baseline: baseline,
            dataDir: dataDir,
            summaries: allSummaries,
            singleBaselineWorkspace: isSingleBaseline
        )
    }

    /// Extract a synthetic `ComplianceBaselineConfig` from the first summary
    /// that contains mscpBands. Used as a fallback when no config.yaml is
    /// readable (in-memory test path).
    private func firstBaselineFromSummaries() -> ComplianceBaselineConfig? {
        for summary in allSummaries {
            guard let bands = summary.mscpBands,
                  let name = bands.keys.sorted().first else { continue }
            // failuresCountColumn is unused by buildSeries when ea-results is absent.
            return ComplianceBaselineConfig(name: name, failuresCountColumn: name, ruleCount: nil)
        }
        return nil
    }
}
