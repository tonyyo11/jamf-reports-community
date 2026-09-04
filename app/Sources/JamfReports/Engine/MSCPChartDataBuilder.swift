import Foundation
import CoreGraphics

// MARK: - MSCPChartDataBuilder

/// Builds historical mSCP/STIG compliance band time-series for chart rendering.
///
/// Two data sources, merged by date (newest date wins when both carry data for
/// the same calendar day):
///
/// 1. **Dated ea-results snapshots** (`dataDir/ea-results/<kind>_yyyyMMddTHHmmss.json`):
///    Re-runs `MSCPComplianceService.evaluate` on every snapshot file found on disk,
///    so the chart has history immediately — not only going forward.
/// 2. **DailySummary.mscpBands**: Accrue from summary.json files in the summaries dir.
///    Cheaper reads; used as fallback when an ea-results file is not available for a date.
///
/// The caller is responsible for providing the baseline name to chart and the data-dir /
/// summaries-dir URLs. All I/O is synchronous — call from a background actor or task.
struct MSCPChartDataBuilder: Sendable {

    /// One date's worth of compliance band counts for a single baseline.
    struct BandPoint: Sendable {
        let date: Date
        let counts: MSCPBandCounts
        /// True when this point was recovered from a 16KB-truncated ea-results
        /// file via `EAResultRow.decodeSnapshot`'s salvage path — the banded
        /// counts likely UNDERSTATE the fleet (only a prefix of devices was
        /// recovered) and must never be charted as an ordinary data point.
        /// Points sourced from `DailySummary.mscpBands` (not ea-results) are
        /// always `false` here — if a salvaged day's ea-results file is later
        /// removed by retention, its summary-derived point charts unflagged.
        /// Acceptable: retention defaults to keeping everything.
        let isSalvaged: Bool

        init(date: Date, counts: MSCPBandCounts, isSalvaged: Bool = false) {
            self.date = date
            self.counts = counts
            self.isSalvaged = isSalvaged
        }
    }

    // MARK: - Public API

    /// Build an ordered band series for `baselineName` by merging dated ea-results
    /// snapshots and summary.json files.
    ///
    /// - Parameters:
    ///   - baseline: The baseline config entry supplying `name` and `failuresCountColumn`.
    ///   - dataDir: Workspace data directory containing `ea-results/` subdirectory.
    ///   - summaries: Pre-parsed `DailySummary` objects from the summaries directory.
    ///     Already sorted by date is preferred but not required.
    ///   - singleBaselineWorkspace: When `true` (and a summary carries exactly one
    ///     mscpBands key that does not match `baseline.name`), the lone value is
    ///     coalesced onto `baseline.name`. This bridges a one-time baseline-name
    ///     transition without forking the trend series — safe only when the workspace
    ///     is known to configure a single baseline. Multi-baseline workspaces must
    ///     leave this `false` so old summaries' differently-named keys are not
    ///     mis-coalesced onto the primary baseline.
    /// - Returns: Array of `BandPoint` sorted ascending by date, deduped (one entry per day).
    ///   Empty when no data is found from either source.
    static func buildSeries(
        baseline: ComplianceBaselineConfig,
        dataDir: URL,
        summaries: [DailySummary],
        singleBaselineWorkspace: Bool = false
    ) -> [BandPoint] {
        // Thin wrapper over `buildAllSeries` (single-element list), threading the
        // caller's explicit `singleBaselineWorkspace` flag so a multi-baseline
        // caller passing one baseline keeps its no-coalesce behavior verbatim.
        buildAllSeries(
            baselines: [baseline], dataDir: dataDir, summaries: summaries,
            coalesceLoneKey: singleBaselineWorkspace
        )[baseline.name] ?? []
    }

    /// Build one ordered band series per baseline, keyed by baseline name.
    ///
    /// Decodes each ea-results snapshot exactly ONCE and evaluates the full
    /// baseline list against those rows (`MSCPComplianceService.evaluate` already
    /// returns one result per baseline) — never re-decoding a multi-megabyte file
    /// per baseline. Band counts from different baselines are never summed;
    /// each baseline keeps its own independent series.
    ///
    /// The summary source matches each baseline by EXACT name first; else, if the
    /// summary carries `mscpBandColumns`, by stable `failuresCountColumn` identity
    /// (multi-baseline-safe bridging of a display-name rename); else the
    /// single-baseline lone-key coalesce, which applies when `coalesceLoneKey` is
    /// true (defaults to `baselines.count == 1`) AND a summary carries exactly one
    /// mscpBands key — same semantics as `singleBaselineWorkspace`.
    ///
    /// Points whose banded total (pass+low+medLow+medium+high) == 0 are SKIPPED in
    /// both sources; an all-noData result is not charted as a crater.
    ///
    /// - Returns: `[baselineName: [BandPoint]]`; each series sorted ascending by
    ///   date, deduped to one entry per day. Baselines with no data are omitted.
    static func buildAllSeries(
        baselines: [ComplianceBaselineConfig],
        dataDir: URL,
        summaries: [DailySummary],
        coalesceLoneKey: Bool? = nil
    ) -> [String: [BandPoint]] {
        guard !baselines.isEmpty else { return [:] }
        let coalesceLoneKey = coalesceLoneKey ?? (baselines.count == 1)

        // Per-baseline accumulator keyed by day-string.
        var byBaseline: [String: [String: BandPoint]] = [:]
        for b in baselines { byBaseline[b.name] = [:] }

        // --- Source 1: summary.json mscpBands (cheap, available first) ---
        for summary in summaries {
            guard let bands = summary.mscpBands else { continue }
            let date = SummaryJSONParser.dateFormatter.date(from: summary.date) ?? .distantPast
            guard date != .distantPast else { continue }
            for b in baselines {
                let counts: MSCPBandCounts?
                if let exact = bands[b.name] {
                    counts = exact
                } else if let cols = summary.mscpBandColumns,
                          let key = cols.first(where: { $0.value == b.failuresCountColumn })?.key,
                          let bridged = bands[key] {
                    // Multi-baseline-safe: the summary predates a display-name
                    // rename, but its stable column identity still matches this
                    // baseline's failures_count_column — heal the series across it.
                    counts = bridged
                } else if coalesceLoneKey, bands.count == 1, let sole = bands.values.first {
                    // Single-baseline workspace with a renamed baseline: coalesce
                    // the lone key onto the current name so a config fix doesn't
                    // fork the series.
                    counts = sole
                } else {
                    counts = nil
                }
                guard let counts, bandedTotal(counts) > 0 else { continue }
                if byBaseline[b.name]?[summary.date] == nil {
                    byBaseline[b.name]?[summary.date] = BandPoint(date: date, counts: counts)
                }
            }
        }

        // --- Source 2: ea-results snapshots (preferred — full fidelity backfill) ---
        let eaResultsDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: eaResultsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return sortedByBaseline(byBaseline)
        }

        // Sort ascending by snapshot date so last-writer-wins is deterministic:
        // the newest file for a given date overwrites earlier ones.
        let jsonFiles = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
            .filter { !CloudStorage.isLikelySyncConflict($0.lastPathComponent) }
            .sorted { dateFromSnapshotFilename($0) < dateFromSnapshotFilename($1) }
        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoded = EAResultRow.decodeSnapshot(data)
            guard let rows = decoded.rows else {
                // `.notice` (not `.debug`) so the shape surfaces without verbose
                // logging; `reason` is keys-only (PII-safe).
                AppLogger.platform.notice(
                    "MSCPChartDataBuilder: ea-results \(url.lastPathComponent, privacy: .public) undecodable — \(decoded.reason, privacy: .public)"
                )
                continue
            }
            let snapshotDate = dateFromSnapshotFilename(url, fm: fm)
            let dayKey = SummaryJSONParser.dateFormatter.string(from: snapshotDate)
            let isSalvaged = EAResultRow.isSalvageReason(decoded.reason)

            // ONE decode, ONE evaluate over the full list — one result per baseline.
            let results = MSCPComplianceService.evaluate(rows: rows, baselines: baselines)
            for result in results {
                let counts = bandCountsFromResult(result)
                // Skip all-noData / empty results (a crater point in prod data).
                guard bandedTotal(counts) > 0 else { continue }
                // ea-results takes precedence over summary.json for the same date.
                byBaseline[result.name]?[dayKey] = BandPoint(
                    date: snapshotDate, counts: counts, isSalvaged: isSalvaged)
            }
        }

        return sortedByBaseline(byBaseline)
    }

    // MARK: - ChartSeries conversion

    /// Convert `[BandPoint]` into the five `ChartSeries` entries needed by
    /// `ChartRenderer.stackedAreaChart` (Pass at index 0, High at index 4).
    ///
    /// "No Data" is intentionally excluded from the trend stackplot per the visual spec.
    static func toStackedSeries(points: [BandPoint]) -> [ChartSeries] {
        guard !points.isEmpty else { return [] }
        let colors = ChartPalette.complianceBandColors
        let labels = ["Pass (0)", "Low (1–10)", "Med-Low (11–30)", "Medium (31–50)", "High (>50)"]
        let extractors: [(MSCPBandCounts) -> Double] = [
            { Double($0.pass) },
            { Double($0.low) },
            { Double($0.medLow) },
            { Double($0.medium) },
            { Double($0.high) },
        ]
        return zip(zip(labels, colors), extractors).map { (labelColor, extract) in
            let (label, color) = labelColor
            let pts = points.map { (date: $0.date, value: extract($0.counts)) }
            return ChartSeries(label: label, color: color, points: pts)
        }
    }

    /// Dates whose point was recovered from a truncated ea-results file —
    /// callers use this to annotate the band chart so a salvaged (partial)
    /// day is never mistaken for an ordinary data point.
    static func salvagedDates(in points: [BandPoint]) -> Set<Date> {
        Set(points.filter(\.isSalvaged).map(\.date))
    }

    /// Convert a `BaselineResult` into donut slices.
    ///
    /// Legend order per spec: No Data → Pass → Low → Med-Low → Medium → High.
    /// Slices with zero count are included so the legend is always complete.
    static func toDonutSlices(
        result: MSCPComplianceService.BaselineResult
    ) -> [ChartRenderer.DonutSlice] {
        let total = result.totalDevices
        guard total > 0 else { return [] }
        let colors = ChartPalette.complianceBandColorsWithNoData
        // bands is in Pass→NoData order; we want NoData first for the legend.
        typealias BandColor = (band: ComplianceBandingService.Band, color: CGColor)
        let ordered: [BandColor] = [
            (band: .noData, color: ChartPalette.noDataColor),
            (band: .pass,   color: colors[0]),
            (band: .low,    color: colors[1]),
            (band: .medLow, color: colors[2]),
            (band: .medium, color: colors[3]),
            (band: .high,   color: colors[4]),
        ]
        // Map band enum → count from result.bands array (allCases order).
        let bandCounts = bandCountDict(from: result)
        return ordered.map { (band, color) in
            let count = bandCounts[band] ?? 0
            let pct = Double(count) / Double(total) * 100.0
            let rangeLabel = band == .noData ? band.label : "\(band.label) (\(band.rangeLabel))"
            return ChartRenderer.DonutSlice(
                label: rangeLabel, count: count, pct: pct, color: color
            )
        }
    }

    // MARK: - Internals

    private static func sorted(_ byDate: [String: BandPoint]) -> [BandPoint] {
        byDate.values.sorted { $0.date < $1.date }
    }

    /// Sort each baseline's day-keyed points into an ordered series; drop empties.
    private static func sortedByBaseline(
        _ byBaseline: [String: [String: BandPoint]]
    ) -> [String: [BandPoint]] {
        var out: [String: [BandPoint]] = [:]
        for (name, byDate) in byBaseline where !byDate.isEmpty {
            out[name] = sorted(byDate)
        }
        return out
    }

    /// Banded device total (excludes No Data). Zero → point is a crater; skip it.
    private static func bandedTotal(_ c: MSCPBandCounts) -> Int {
        c.pass + c.low + c.medLow + c.medium + c.high
    }

    /// Extract band counts from `result.bands` (always 6 elements in Band.allCases order).
    private static func bandCountsFromResult(
        _ result: MSCPComplianceService.BaselineResult
    ) -> MSCPBandCounts {
        let b = result.bands
        func c(_ idx: Int) -> Int { idx < b.count ? b[idx].count : 0 }
        return MSCPBandCounts(
            pass: c(0), low: c(1), medLow: c(2),
            medium: c(3), high: c(4), noData: result.noDataCount
        )
    }

    /// Build a `[Band: Int]` lookup from the ordered bands array.
    private static func bandCountDict(
        from result: MSCPComplianceService.BaselineResult
    ) -> [ComplianceBandingService.Band: Int] {
        var d: [ComplianceBandingService.Band: Int] = [.noData: result.noDataCount]
        let bands = ComplianceBandingService.Band.allCases.filter { $0 != .noData }
        for (idx, band) in bands.enumerated() {
            d[band] = idx < result.bands.count ? result.bands[idx].count : 0
        }
        return d
    }

    /// Extract a date from an ea-results snapshot filename.
    ///
    /// Handles the canonical `saveSnapshot` form `<kind>_yyyyMMddTHHmmss.json`
    /// and the python-era dashed form `<kind>_yyyy-MM-ddTHHmmss<microseconds>.json`
    /// (trailing microsecond digits ignored). Falls back to the file modification
    /// time when neither pattern matches.
    static func dateFromSnapshotFilename(_ url: URL, fm: FileManager = .default) -> Date {
        // One parser, shared with FileSystemHelpers' newest* helpers, so the
        // ordering used by the charts can never drift from the ordering used by
        // the dashboards reading the same directory.
        if let stamped = CloudStorage.snapshotTimestamp(of: url) { return stamped }
        // No canonical stamp. Callers filter sync-conflict copies out before
        // they reach here, so this is a legacy or hand-placed file; mtime is the
        // only signal left.
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }
}
