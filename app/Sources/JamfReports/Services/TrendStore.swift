import Foundation
import Observation

struct TrendPoint: Identifiable, Sendable, Equatable {
    let date: Date
    let value: Double

    var id: Date { date }
}

@Observable final class TrendStore {
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

    /// Cached band-history per baseline from ea-results snapshots (primary) and
    /// summary.json mscpBands (fallback). Rebuilt once per load/reload; never
    /// re-scanned during view rendering. Keyed by baseline name.
    private var cachedBandSeries: [String: [MSCPChartDataBuilder.BandPoint]] = [:]

    /// Ordered baseline names for the mSCP band trend picker. Config order
    /// (resolvedBaselines) when loaded from disk, or the sorted set of summary
    /// mscpBands keys in the no-config fallback path.
    private(set) var mscpBaselineNames: [String] = []

    /// The baseline whose series `mscpStackedSeries()` and `.mscpBandTrend`
    /// derivation read. Defaults to the first name; user-settable via
    /// `selectMSCPBaseline`. Nil only when no baseline has band history.
    var selectedMSCPBaseline: String?

    /// True while an off-main snapshot scan is in flight. Views show a loading
    /// placeholder only when this is set AND there is no cached data yet — a
    /// re-entry keeps the existing data on screen and refreshes silently.
    private(set) var isLoading = false

    /// Immutable result of the off-main disk scan, applied back on the main actor.
    struct TrendSnapshot: Sendable {
        var summaries: [DailySummary]
        var latestSnapshotDate: Date?
        var hasEverFetchedLive: Bool
        var bandSeries: [String: [MSCPChartDataBuilder.BandPoint]]
        var baselineNames: [String]
    }

    init(summaries: [DailySummary] = [], range: TrendRange = .w4) {
        allSummaries = summaries
        currentRange = range
        hasEverFetchedLive = summaries.contains(where: { $0.source == "jamf-cli" })
        filterSummaries(range: range)
        // In-memory init: build band points from summaries only. The inaccessible
        // dataDir degrades gracefully to summaries-only inside buildAllSeries.
        let built = Self.computeBandPoints(profile: nil, summaries: summaries)
        cachedBandSeries = built.series
        mscpBaselineNames = built.names
        selectedMSCPBaseline = built.names.first
    }

    /// Select the baseline whose band series the mSCP trend surfaces render.
    /// No-op if the name is not one of `mscpBaselineNames`.
    func selectMSCPBaseline(_ name: String) {
        guard mscpBaselineNames.contains(name) else { return }
        selectedMSCPBaseline = name
    }

    /// The band series for the currently-selected baseline (or the first).
    private var selectedBandPoints: [MSCPChartDataBuilder.BandPoint] {
        let name = selectedMSCPBaseline ?? mscpBaselineNames.first
        guard let name else { return [] }
        return cachedBandSeries[name] ?? []
    }

    // MARK: - Off-main snapshot loading

    /// Read summaries + band history from disk. Pure and `nonisolated` so callers
    /// run it OFF the main actor (`Task.detached`) — the summaries decode and the
    /// ea-results scan are exactly what froze the UI when this ran synchronously
    /// from `.onAppear`.
    nonisolated static func computeSnapshot(profile: String) -> TrendSnapshot {
        let summaries = readSummaries(profile: profile)
        let built = computeBandPoints(profile: profile, summaries: summaries)
        return TrendSnapshot(
            summaries: summaries,
            latestSnapshotDate: readLatestSnapshotMTime(profile: profile),
            hasEverFetchedLive: summaries.contains { $0.source == "jamf-cli" },
            bandSeries: built.series,
            baselineNames: built.names
        )
    }

    /// Monotonic load-request generation. Each `beginLoading` supersedes every
    /// in-flight scan; `apply` discards snapshots from superseded generations so
    /// a slow scan of profile A can never overwrite a newer load of profile B
    /// (cross-profile stale-writer race — mislabeled tenant data).
    private var loadGeneration = 0

    /// Mark a load in flight (main actor). Views call this before the detached
    /// scan and pass the returned generation token to `apply`.
    func beginLoading() -> Int {
        isLoading = true
        loadGeneration += 1
        return loadGeneration
    }

    /// Publish an off-main snapshot to the observable state. Fast (no I/O); must
    /// run on the main actor — the views call it from a `.task`. Clears `isLoading`.
    /// Snapshots from a superseded generation are dropped (see `loadGeneration`).
    func apply(_ snapshot: TrendSnapshot, profile: String, range: TrendRange, generation: Int) {
        guard generation == loadGeneration else { return }
        allSummaries = snapshot.summaries
        latestSnapshotDate = snapshot.latestSnapshotDate
        hasEverFetchedLive = snapshot.hasEverFetchedLive
        cachedBandSeries = snapshot.bandSeries
        mscpBaselineNames = snapshot.baselineNames
        // Preserve a still-valid selection across reloads; else default to first.
        let keepSelection = selectedMSCPBaseline.map(snapshot.baselineNames.contains) ?? false
        if !keepSelection { selectedMSCPBaseline = snapshot.baselineNames.first }
        currentProfile = profile
        currentRange = range
        filterSummaries(range: range)
        isLoading = false
    }

    /// Re-filter for a new range without re-reading disk (range-picker changes).
    func setRange(_ range: TrendRange) {
        currentRange = range
        filterSummaries(range: range)
    }

    /// Clear displayed data when switching to a DIFFERENT profile, so the loading
    /// overlay shows for the new profile rather than the previous tenant's data
    /// during the scan. A same-profile reload (tab re-entry) is a no-op — data
    /// stays on screen and refreshes silently. No-op on first load (nil profile).
    func clearForProfileSwitch(to profile: String) {
        guard let current = currentProfile, current != profile else { return }
        allSummaries = []
        filteredSummaries = []
        cachedBandSeries = [:]
        mscpBaselineNames = []
        selectedMSCPBaseline = nil
        latestSnapshotDate = nil
        hasEverFetchedLive = false
        currentProfile = nil
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
    /// (or the workspace fallback if config is unavailable). `nonisolated static`
    /// so it runs off the main actor inside `computeSnapshot`.
    nonisolated static func readSummaries(profile: String) -> [DailySummary] {
        // Validate at the boundary — string-interpolating an unvalidated profile
        // into a path component is a traversal vector.
        guard let summariesDir = (try? WorkspacePaths.summariesDir(for: profile))
            ?? fallbackSummariesDir(for: profile) else {
            return []
        }
        return SummaryJSONParser.parseDirectory(summariesDir)
    }

    nonisolated static func fallbackSummariesDir(for profile: String) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        return workspace.appendingPathComponent("snapshots/summaries", isDirectory: true)
    }

    /// Scan the summaries directory for the newest `summary_*.json` mtime.
    /// We read the filesystem timestamp rather than parsing each file's
    /// embedded date because the user-visible "stale" signal is when the
    /// last *run* happened, which `contentModificationDate` captures
    /// directly (even if the summary's logical date string lags).
    nonisolated static func readLatestSnapshotMTime(profile: String) -> Date? {
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
        case .stale:         return summary.staleCount.map(Double.init)
        case .patch:         return summary.patchPct
        case .securityScore: return summary.securityScore
        case .mscpBandTrend:
            // Derive from the SELECTED baseline's points: find the point whose
            // date matches this summary's date (string-matched), then sum the 5
            // bands. Falls back to that baseline's summary.mscpBands entry.
            let dayKey = summary.date
            if let pt = selectedBandPoints.first(where: {
                SummaryJSONParser.dateFormatter.string(from: $0.date) == dayKey
            }) {
                let total = pt.counts.pass + pt.counts.low + pt.counts.medLow
                    + pt.counts.medium + pt.counts.high
                return total > 0 ? Double(total) : nil
            }
            // Summary-only fallback: read the selected/first baseline's entry
            // rather than reducing across all baselines (frameworks differ).
            guard let bands = summary.mscpBands, !bands.isEmpty else { return nil }
            let key = selectedMSCPBaseline ?? mscpBaselineNames.first
            let counts = key.flatMap { bands[$0] } ?? (bands.count == 1 ? bands.values.first : nil)
            guard let counts else { return nil }
            let withData = counts.total - counts.noData
            return withData > 0 ? Double(withData) : nil
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
        cachedBandSeries.values.contains { !$0.isEmpty }
    }

    /// X-axis domain for the mSCP band stacked-area chart.
    ///
    /// Prefers `chartDomain` (summary-driven) so the axis matches the rest of
    /// the Trends screen. Falls back to a domain derived from the selected
    /// baseline's band points when summaries are absent (e.g. deleted collect) but
    /// ea-results-only band data exists. Returns `nil` only when both sources
    /// are empty, in which case the band chart shows the unavailable empty-state.
    var bandChartDomain: ClosedRange<Date>? {
        if let domain = chartDomain { return domain }
        let pts = selectedBandPoints
        guard let first = pts.first?.date, let last = pts.last?.date else { return nil }
        return first <= last ? first...last : last...first
    }

    /// The baseline name whose mSCP band trend is currently surfaced
    /// (selected, or the first when unset).
    var primaryMSCPBaseline: String? {
        selectedMSCPBaseline ?? mscpBaselineNames.first
    }

    /// Build mSCP stacked-area chart series for the SELECTED baseline,
    /// range-filtered to match `filteredSummaries`.
    ///
    /// Returns 5 series (Pass, Low, Med-Low, Medium, High) with device counts.
    /// Used by TrendsView when metric == .mscpBandTrend.
    func mscpStackedSeries() -> [ChartSeries] {
        let points = selectedBandPoints
        guard !points.isEmpty else { return [] }

        // Determine the date range from filteredSummaries so the stackplot
        // respects the user-selected trend range.
        let rangeStart = filteredSummaries.first?.parsedDate
        let rangeEnd   = filteredSummaries.last?.parsedDate

        let inRange: [MSCPChartDataBuilder.BandPoint]
        if let start = rangeStart, let end = rangeEnd {
            inRange = points.filter { $0.date >= start && $0.date <= end }
        } else {
            inRange = points
        }

        return MSCPChartDataBuilder.toStackedSeries(points: inRange)
    }

    /// Dates (for the SELECTED baseline, range-filtered same as
    /// `mscpStackedSeries()`) whose band point was recovered from a truncated
    /// ea-results file. `TrendsView` annotates these on the band chart so a
    /// salvaged (partial-fleet) day is never mistaken for real fleet change.
    var salvagedBandDates: Set<Date> {
        let points = selectedBandPoints
        guard !points.isEmpty else { return [] }

        let rangeStart = filteredSummaries.first?.parsedDate
        let rangeEnd   = filteredSummaries.last?.parsedDate

        let inRange: [MSCPChartDataBuilder.BandPoint]
        if let start = rangeStart, let end = rangeEnd {
            inRange = points.filter { $0.date >= start && $0.date <= end }
        } else {
            inRange = points
        }

        return MSCPChartDataBuilder.salvagedDates(in: inRange)
    }

    // MARK: - Band-point cache

    /// Build per-baseline band-history from ea-results snapshots (primary) and
    /// summary.json mscpBands (fallback). `nonisolated static` so it runs off the
    /// main actor inside `computeSnapshot` — the ea-results directory scan is the
    /// expensive part that froze the UI.
    ///
    /// When `profile` is nil (in-memory init path) there is no config.yaml or
    /// dataDir to read, so `buildAllSeries` runs with a non-existent dir and
    /// degrades to summaries-only.
    ///
    /// - Returns: `series` keyed by baseline name, and `names` in display order
    ///   (config order when a config exists, else sorted summary keys). `names`
    ///   is filtered to baselines that actually produced points, so the picker
    ///   never lists an empty series.
    nonisolated static func computeBandPoints(
        profile: String?, summaries: [DailySummary]
    ) -> (series: [String: [MSCPChartDataBuilder.BandPoint]], names: [String]) {
        // 1. Resolve the baseline list to use (config order preferred).
        let baselines: [ComplianceBaselineConfig]
        if let profile,
           let workspaceURL = ProfileService.workspaceURL(for: profile),
           let config = try? ConfigLoader.load(
               from: workspaceURL.appendingPathComponent("config.yaml")),
           let resolved = config.compliance?.resolvedBaselines, !resolved.isEmpty {
            baselines = resolved
        } else {
            baselines = fallbackBaselines(from: summaries)
        }
        guard !baselines.isEmpty else { return ([:], []) }

        // 2. Resolve the data directory. Uses a non-existent temp URL when the
        //    profile is nil or dataDir lookup fails; buildAllSeries degrades to
        //    summaries-only gracefully.
        let dataDir: URL
        if let profile, let dir = try? WorkspacePaths.dataDir(for: profile) {
            dataDir = dir
        } else if let profile, let workspace = ProfileService.workspaceURL(for: profile) {
            dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        } else {
            dataDir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        }

        let series = MSCPChartDataBuilder.buildAllSeries(
            baselines: baselines, dataDir: dataDir, summaries: summaries)
        // Preserve config order, but only keep baselines that produced points.
        let names = baselines.map(\.name).filter { !(series[$0]?.isEmpty ?? true) }
        return (series, names)
    }

    /// Synthesize baseline configs from ALL distinct mscpBands keys across
    /// summaries (sorted), used as a fallback when no config.yaml is readable
    /// (pre-config workspace / in-memory test path). `failuresCountColumn` is
    /// unused when ea-results is absent, so the key stands in for the column.
    nonisolated static func fallbackBaselines(
        from summaries: [DailySummary]
    ) -> [ComplianceBaselineConfig] {
        var seen = Set<String>()
        var names: [String] = []
        for summary in summaries {
            guard let bands = summary.mscpBands else { continue }
            for name in bands.keys where !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }
        return names.sorted().map {
            ComplianceBaselineConfig(name: $0, failuresCountColumn: $0, ruleCount: nil)
        }
    }
}
