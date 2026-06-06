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
    }

    // MARK: - Public API

    /// Build an ordered band series for `baselineName` by merging dated ea-results
    /// snapshots and summary.json files.
    ///
    /// - Parameters:
    ///   - baselineName: The baseline label to chart (must match a configured baseline name).
    ///   - baseline: The baseline config entry supplying `failuresCountColumn`.
    ///   - dataDir: Workspace data directory containing `ea-results/` subdirectory.
    ///   - summaries: Pre-parsed `DailySummary` objects from the summaries directory.
    ///     Already sorted by date is preferred but not required.
    /// - Returns: Array of `BandPoint` sorted ascending by date, deduped (one entry per day).
    ///   Empty when no data is found from either source.
    static func buildSeries(
        baseline: ComplianceBaselineConfig,
        dataDir: URL,
        summaries: [DailySummary]
    ) -> [BandPoint] {
        var byDate: [String: BandPoint] = [:]

        // --- Source 1: summary.json mscpBands (baseline → cheap, available first) ---
        for summary in summaries {
            guard let counts = summary.mscpBands?[baseline.name] else { continue }
            let date = SummaryJSONParser.dateFormatter.date(from: summary.date) ?? .distantPast
            guard date != .distantPast else { continue }
            let key = summary.date
            if byDate[key] == nil {
                byDate[key] = BandPoint(date: date, counts: counts)
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
            return sorted(byDate)
        }

        // Sort ascending by snapshot date so last-writer-wins is deterministic:
        // the newest file for a given date overwrites earlier ones in byDate.
        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { dateFromSnapshotFilename($0) < dateFromSnapshotFilename($1) }
        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url),
                  let rows = try? JSONDecoder().decode([EAResultRow].self, from: data)
            else { continue }
            let snapshotDate = dateFromSnapshotFilename(url, fm: fm)
            let dayKey = SummaryJSONParser.dateFormatter.string(from: snapshotDate)

            let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
            guard let result = results.first, result.totalDevices > 0 else { continue }
            let counts = bandCountsFromResult(result)
            // ea-results takes precedence over summary.json for the same date.
            byDate[dayKey] = BandPoint(date: snapshotDate, counts: counts)
        }

        return sorted(byDate)
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
    /// `saveSnapshot` writes `<kind>_yyyyMMddTHHmmss.json`. Falls back to the
    /// file modification time when the filename doesn't match the pattern.
    static func dateFromSnapshotFilename(_ url: URL, fm: FileManager = .default) -> Date {
        let stem = url.deletingPathExtension().lastPathComponent
        // Canonical saveSnapshot format: ea-results_20240615T120000
        if let range = stem.range(of: #"(\d{8})T(\d{6})$"#, options: .regularExpression) {
            let match = String(stem[range])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .iso8601)
            if let date = formatter.date(from: match) { return date }
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }
}
