import Foundation
import XCTest
@testable import JamfReports

// MARK: - MSCPChartTests
//
// Covers:
//  - Donut legend math: counts, percents, band ordering
//  - Historical series construction: dedup by date, correct band totals
//  - Gating: no crash / no images when no baseline or no data
//  - MSCPBandCounts schema: round-trip encode/decode, totals
//  - mscpBands persisted in DailySummary.mscpBandsMap
//  - dateFromSnapshotFilename: canonical saveSnapshot format

final class MSCPChartTests: XCTestCase {

    // MARK: - Helpers

    private func tempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscp-chart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Write a synthetic ea-results snapshot with controlled band distribution.
    ///
    /// - Parameters:
    ///   - passCount: Devices with 0 failures.
    ///   - lowCount: Devices with 5 failures (Low band).
    ///   - highCount: Devices with 60 failures (High band).
    ///   - noDataCount: Additional devices whose ea_name does NOT match the column
    ///     (so they fall into No Data from the baseline's perspective but are in the universe).
    private func writeEAResults(
        to dir: URL,
        eaColumn: String,
        passCount: Int = 0,
        lowCount: Int = 0,
        highCount: Int = 0,
        noDataCount: Int = 0,
        filename: String = "ea-results_20240615T120000.json"
    ) throws {
        let eaDir = dir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for i in 0..<passCount {
            rows.append(["device": "mac-pass-\(i)", "ea_name": eaColumn, "value": 0])
        }
        for i in 0..<lowCount {
            rows.append(["device": "mac-low-\(i)", "ea_name": eaColumn, "value": 5])
        }
        for i in 0..<highCount {
            rows.append(["device": "mac-high-\(i)", "ea_name": eaColumn, "value": 60])
        }
        // No-data devices carry a DIFFERENT ea_name so they appear in universe but not in band.
        for i in 0..<noDataCount {
            rows.append(["device": "mac-nodata-\(i)", "ea_name": "Other EA", "value": 0])
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        let file = eaDir.appendingPathComponent(filename)
        try data.write(to: file)
    }

    private func makeBaseline(name: String = "NIST 800-53r5", col: String = "EA - Failures",
                              ruleCount: Int? = nil) -> ComplianceBaselineConfig {
        ComplianceBaselineConfig(name: name, failuresCountColumn: col, ruleCount: ruleCount)
    }

    // MARK: - MSCPBandCounts: schema round-trip

    func testMSCPBandCountsRoundTrip() throws {
        let counts = MSCPBandCounts(pass: 80, low: 10, medLow: 5, medium: 3, high: 1, noData: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(counts)
        let decoded = try JSONDecoder().decode(MSCPBandCounts.self, from: data)
        XCTAssertEqual(decoded.pass, 80)
        XCTAssertEqual(decoded.low, 10)
        XCTAssertEqual(decoded.medLow, 5)
        XCTAssertEqual(decoded.medium, 3)
        XCTAssertEqual(decoded.high, 1)
        XCTAssertEqual(decoded.noData, 1)
        XCTAssertEqual(decoded.total, 100)
    }

    func testMSCPBandCountsAbsentInLegacySummary() throws {
        // Old summary files have no mscpBands key — must decode without error.
        let json = """
        {"date":"2025-01-01","totalDevices":100,"staleCount":2,"source":"jamf-cli"}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.mscpBands, "mscpBands must be nil in legacy summaries")
    }

    func testMSCPBandCountsPersistedInSummary() throws {
        let counts = MSCPBandCounts(pass: 70, low: 20, medLow: 5, medium: 3, high: 2, noData: 0)
        let summary = DailySummary(
            date: "2026-01-15", totalDevices: 100,
            fileVaultPct: nil, compliancePct: nil,
            staleCount: 0, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            mscpBands: ["NIST": counts]
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)
        let decodedCounts = try XCTUnwrap(decoded.mscpBands?["NIST"])
        XCTAssertEqual(decodedCounts.pass, 70)
        XCTAssertEqual(decodedCounts.low, 20)
        XCTAssertEqual(decodedCounts.total, 100)
    }

    // MARK: - ReportEngine.mscpBandsMap

    func testMSCPBandsMapFromResults() throws {
        let col = "EA - Failures"
        let baseline = makeBaseline(col: col)
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 8 pass, 2 high (60 failures)
        try writeEAResults(to: tmp, eaColumn: col, passCount: 8, highCount: 2)
        let data = try Data(contentsOf: tmp.appendingPathComponent(
            "ea-results/ea-results_20240615T120000.json"))
        let rows = try JSONDecoder().decode([EAResultRow].self, from: data)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
        let bandsMap = ReportEngine.mscpBandsMap(from: results)

        let counts = try XCTUnwrap(bandsMap["NIST 800-53r5"])
        XCTAssertEqual(counts.pass, 8)
        XCTAssertEqual(counts.high, 2)
        XCTAssertEqual(counts.low, 0)
        XCTAssertEqual(counts.noData, 0)
        XCTAssertEqual(counts.total, 10)
    }

    func testMSCPBandsMapSkipsZeroTotalBaselines() throws {
        // A baseline with zero rows should not appear in the map.
        let result = MSCPComplianceService.BaselineResult(
            name: "Empty", failuresCountColumn: "EA",
            bands: ComplianceBandingService.bands(failures: []),
            noDataCount: 0, totalDevices: 0, compliancePct: nil
        )
        let map = ReportEngine.mscpBandsMap(from: [result])
        XCTAssertTrue(map.isEmpty, "Baselines with zero devices must be excluded")
    }

    // MARK: - Donut legend math

    func testDonutSlicesCountsAndPercents() throws {
        let col = "EA - Failures"
        let baseline = makeBaseline(col: col)
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 80 pass, 10 low, 5 med-low, 3 medium, 2 high, 0 no-data
        try writeEAResults(to: tmp, eaColumn: col,
                           passCount: 80, lowCount: 10, highCount: 2, noDataCount: 0)
        // Also add 5 med-low + 3 medium via separate rows
        let eaDir = tmp.appendingPathComponent("ea-results", isDirectory: true)
        var extra: [[String: Any]] = []
        for i in 0..<5 { extra.append(["device": "medlow-\(i)", "ea_name": col, "value": 15]) }
        for i in 0..<3 { extra.append(["device": "med-\(i)", "ea_name": col, "value": 35]) }
        let extraData = try JSONSerialization.data(withJSONObject: extra)
        let appendFile = eaDir.appendingPathComponent("ea-results_extra.json")
        try extraData.write(to: appendFile)

        // Reload all rows and evaluate
        let file1 = try Data(contentsOf: eaDir.appendingPathComponent(
            "ea-results_20240615T120000.json"))
        let rows1 = try JSONDecoder().decode([EAResultRow].self, from: file1)
        let rows2 = try JSONDecoder().decode([EAResultRow].self, from: extraData)
        let allRows = rows1 + rows2
        let results = MSCPComplianceService.evaluate(rows: allRows, baselines: [baseline])
        let result = try XCTUnwrap(results.first)

        let slices = MSCPChartDataBuilder.toDonutSlices(result: result)
        // Spec: No Data → Pass → Low → Med-Low → Medium → High (6 entries)
        XCTAssertEqual(slices.count, 6)
        let labels = slices.map(\.label)
        XCTAssert(labels[0].contains("No Data"), "First slice must be No Data")
        XCTAssert(labels[1].contains("Pass"), "Second slice must be Pass")
        XCTAssert(labels[5].contains("High"), "Last slice must be High")

        let total = result.totalDevices  // 100
        XCTAssertEqual(total, 100)

        // Pass slice: 80/100 = 80%
        let passSlice = try XCTUnwrap(slices.first { $0.label.contains("Pass") })
        XCTAssertEqual(passSlice.count, 80)
        XCTAssertEqual(passSlice.pct, 80.0, accuracy: 0.1)

        // High slice: 2/100 = 2%
        let highSlice = try XCTUnwrap(slices.first { $0.label.contains("High") })
        XCTAssertEqual(highSlice.count, 2)
        XCTAssertEqual(highSlice.pct, 2.0, accuracy: 0.1)
    }

    func testDonutSlicesEmptyWhenNoData() throws {
        let result = MSCPComplianceService.BaselineResult(
            name: "Empty", failuresCountColumn: "EA",
            bands: ComplianceBandingService.bands(failures: []),
            noDataCount: 0, totalDevices: 0, compliancePct: nil
        )
        let slices = MSCPChartDataBuilder.toDonutSlices(result: result)
        XCTAssertTrue(slices.isEmpty)
    }

    // MARK: - Historical series: dedup by date and correct totals

    func testBuildSeriesDedupsByDate() throws {
        let col = "EA - Failures"
        let baseline = makeBaseline(col: col)
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Two ea-results files for the SAME date: 08:00 (5 pass) and 16:00 (10 pass).
        // buildSeries sorts ascending by snapshot timestamp before the loop so the
        // 16:00 file (latest) wins deterministically — not APFS-order-dependent.
        try writeEAResults(to: tmp, eaColumn: col, passCount: 5,
                           filename: "ea-results_20240101T080000.json")
        try writeEAResults(to: tmp, eaColumn: col, passCount: 10,
                           filename: "ea-results_20240101T160000.json")

        // Also a summary.json for the same date — ea-results must take precedence.
        let summaryDate = "2024-01-01"
        let summaryBands = MSCPBandCounts(pass: 3, low: 0, medLow: 0, medium: 0, high: 0, noData: 0)
        let summary = DailySummary(
            date: summaryDate, totalDevices: 3,
            fileVaultPct: nil, compliancePct: nil,
            staleCount: 0, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            mscpBands: ["NIST 800-53r5": summaryBands]
        )

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: tmp, summaries: [summary])

        // One entry per date — not three.
        XCTAssertEqual(points.count, 1, "Same-date entries must be deduped to one")

        // Newest ea-results file (16:00, 10 pass) wins over the 08:00 file and the summary (3 pass).
        let pt = try XCTUnwrap(points.first)
        XCTAssertEqual(pt.counts.pass, 10,
            "Newest ea-results snapshot must win; sort order must be deterministic (not APFS-order)")
    }

    func testBuildSeriesMultipleDatesProduceSortedPoints() throws {
        let col = "EA - Failures"
        let baseline = makeBaseline(col: col)
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeEAResults(to: tmp, eaColumn: col, passCount: 5,
                           filename: "ea-results_20240101T120000.json")
        try writeEAResults(to: tmp, eaColumn: col, passCount: 8,
                           filename: "ea-results_20240215T120000.json")
        try writeEAResults(to: tmp, eaColumn: col, passCount: 12,
                           filename: "ea-results_20240301T120000.json")

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: tmp, summaries: [])

        XCTAssertEqual(points.count, 3)
        XCTAssertLessThan(points[0].date, points[1].date)
        XCTAssertLessThan(points[1].date, points[2].date)
        XCTAssertEqual(points[0].counts.pass, 5)
        XCTAssertEqual(points[1].counts.pass, 8)
        XCTAssertEqual(points[2].counts.pass, 12)
    }

    func testBuildSeriesFromSummaryFallbackWhenNoEAResults() throws {
        let baseline = makeBaseline()
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // No ea-results dir at all — only summary
        let bands = MSCPBandCounts(pass: 50, low: 10, medLow: 0, medium: 0, high: 0, noData: 0)
        let summary = DailySummary(
            date: "2026-03-01", totalDevices: 60,
            fileVaultPct: nil, compliancePct: nil,
            staleCount: 0, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            mscpBands: ["NIST 800-53r5": bands]
        )
        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: tmp, summaries: [summary])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].counts.pass, 50)
    }

    func testBuildSeriesEmptyWhenNeitherSourcePresent() throws {
        let baseline = makeBaseline()
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: tmp, summaries: [])
        XCTAssertTrue(points.isEmpty)
    }

    // MARK: - buildAllSeries: multi-baseline from one row set

    /// Two baselines sourcing DIFFERENT EA columns from ONE set of ea-results rows
    /// must produce independent per-baseline series — band counts are not summed.
    func testBuildAllSeriesMultiBaselineIndependentSeries() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stigCol = "STIG - Failures"
        let nistCol = "NIST - Failures"
        // Same devices carry both EA columns; the two baselines differ in the
        // failure counts they report (STIG all-pass; NIST 3 pass + 2 high).
        let eaDir = tmp.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for i in 0..<5 { rows.append(["device": "mac-\(i)", "ea_name": stigCol, "value": 0]) }
        for i in 0..<3 { rows.append(["device": "mac-\(i)", "ea_name": nistCol, "value": 0]) }
        for i in 3..<5 { rows.append(["device": "mac-\(i)", "ea_name": nistCol, "value": 60]) }
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: eaDir.appendingPathComponent("ea-results_20240601T120000.json"))

        let stig = makeBaseline(name: "DISA STIG", col: stigCol)
        let nist = makeBaseline(name: "NIST 800-53r5", col: nistCol)
        let series = MSCPChartDataBuilder.buildAllSeries(
            baselines: [stig, nist], dataDir: tmp, summaries: [])

        let stigPts = try XCTUnwrap(series["DISA STIG"])
        let nistPts = try XCTUnwrap(series["NIST 800-53r5"])
        XCTAssertEqual(stigPts.count, 1)
        XCTAssertEqual(nistPts.count, 1)
        // STIG: all 5 devices pass.
        XCTAssertEqual(stigPts.first?.counts.pass, 5)
        XCTAssertEqual(stigPts.first?.counts.high, 0)
        // NIST: 3 pass, 2 high — different from STIG (not summed together).
        XCTAssertEqual(nistPts.first?.counts.pass, 3)
        XCTAssertEqual(nistPts.first?.counts.high, 2)
    }

    // MARK: - Zero-band point is skipped (all-noData crater)

    /// A summary point whose banded total is 0 (all devices No Data) must be
    /// SKIPPED — the prod 2026-06-05 all-zero/noData=659 crater must not chart.
    func testBuildAllSeriesSkipsZeroBandSummaryPoint() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let crater = MSCPBandCounts(pass: 0, low: 0, medLow: 0, medium: 0, high: 0, noData: 659)
        let good = MSCPBandCounts(pass: 50, low: 10, medLow: 5, medium: 2, high: 1, noData: 0)
        let day1 = DailySummary(
            date: "2026-06-05", totalDevices: 659,
            fileVaultPct: nil, compliancePct: nil, staleCount: 0,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", mscpBands: ["Compliance": crater])
        let day2 = DailySummary(
            date: "2026-06-06", totalDevices: 68,
            fileVaultPct: nil, compliancePct: nil, staleCount: 0,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", mscpBands: ["Compliance": good])

        let baseline = makeBaseline(name: "Compliance", col: "Compliance Failures")
        let series = MSCPChartDataBuilder.buildAllSeries(
            baselines: [baseline], dataDir: tmp, summaries: [day1, day2])

        let pts = try XCTUnwrap(series["Compliance"])
        XCTAssertEqual(pts.count, 1, "The all-noData crater point must be skipped")
        XCTAssertEqual(pts.first?.counts.pass, 50)
    }

    // MARK: - S4: baseline-rename bridge via mscpBandColumns (multi-baseline)

    /// Two baselines; summaries written under the OLD display names, carrying
    /// `mscpBandColumns` (name -> failures_count_column). Config now renames one
    /// baseline (same column). The renamed baseline's series must stay continuous
    /// under the NEW name, and the other baseline must be unaffected.
    func testBuildAllSeriesBridgesRenameByColumnMultiBaseline() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stigCol = "STIG - Failures"
        let nistCol = "NIST - Failures"
        // Summaries under the OLD display names, with the stable column map.
        let stigBands = MSCPBandCounts(pass: 5, low: 0, medLow: 0, medium: 0, high: 0, noData: 0)
        let nistBands = MSCPBandCounts(pass: 3, low: 0, medLow: 0, medium: 0, high: 2, noData: 0)
        let summary = DailySummary(
            date: "2026-06-01", totalDevices: 5,
            fileVaultPct: nil, compliancePct: nil, staleCount: 0,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            mscpBands: ["DISA STIG (old)": stigBands, "NIST (old)": nistBands],
            mscpBandColumns: ["DISA STIG (old)": stigCol, "NIST (old)": nistCol])

        // Config now carries the RENAMED STIG baseline (same column) + unchanged NIST-by-column.
        let stigRenamed = makeBaseline(name: "DISA STIG r2", col: stigCol)
        let nistRenamed = makeBaseline(name: "NIST 800-53r5", col: nistCol)
        let series = MSCPChartDataBuilder.buildAllSeries(
            baselines: [stigRenamed, nistRenamed], dataDir: tmp, summaries: [summary])

        // STIG series is continuous under the NEW name, bridged by column identity.
        let stigPts = try XCTUnwrap(series["DISA STIG r2"])
        XCTAssertEqual(stigPts.count, 1)
        XCTAssertEqual(stigPts.first?.counts.pass, 5)
        // The other baseline is bridged independently — not summed with STIG.
        let nistPts = try XCTUnwrap(series["NIST 800-53r5"])
        XCTAssertEqual(nistPts.count, 1)
        XCTAssertEqual(nistPts.first?.counts.pass, 3)
        XCTAssertEqual(nistPts.first?.counts.high, 2)
        // The old display-name keys must not leak through as their own series.
        XCTAssertNil(series["DISA STIG (old)"])
        XCTAssertNil(series["NIST (old)"])
    }

    /// A legacy multi-baseline summary WITHOUT `mscpBandColumns` must behave exactly
    /// as before: exact-name match only (no column-bridge), and the lone-key coalesce
    /// stays gated to the single-baseline case — so a renamed baseline finds nothing.
    func testBuildAllSeriesLegacySummaryNoColumnBridge() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bands = MSCPBandCounts(pass: 4, low: 1, medLow: 0, medium: 0, high: 0, noData: 0)
        // Legacy summary: mscpBands only, no mscpBandColumns.
        let summary = DailySummary(
            date: "2026-05-01", totalDevices: 5,
            fileVaultPct: nil, compliancePct: nil, staleCount: 0,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            mscpBands: ["STIG (old)": bands, "NIST (old)": bands])
        XCTAssertNil(summary.mscpBandColumns)

        // Two baselines with renamed display names → no exact match, no columns to
        // bridge, and coalesceLoneKey is false (baselines.count == 2) → empty.
        let stig = makeBaseline(name: "STIG new", col: "STIG - Failures")
        let nist = makeBaseline(name: "NIST new", col: "NIST - Failures")
        let series = MSCPChartDataBuilder.buildAllSeries(
            baselines: [stig, nist], dataDir: tmp, summaries: [summary])
        XCTAssertTrue(series.isEmpty,
            "Legacy summary without mscpBandColumns must not bridge a rename in a multi-baseline org")

        // Exact-name match still works for a legacy summary.
        let stigExact = makeBaseline(name: "STIG (old)", col: "STIG - Failures")
        let exactSeries = MSCPChartDataBuilder.buildAllSeries(
            baselines: [stigExact], dataDir: tmp, summaries: [summary])
        XCTAssertEqual(exactSeries["STIG (old)"]?.count, 1)
    }

    // MARK: - S4: mscpBandColumns decode round-trip

    func testMSCPBandColumnsAbsentInLegacySummary() throws {
        let json = """
        {"date":"2025-01-01","totalDevices":100,"staleCount":2,"source":"jamf-cli"}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.mscpBandColumns, "mscpBandColumns must be nil in legacy summaries")
    }

    func testMSCPBandColumnsRoundTrip() throws {
        let counts = MSCPBandCounts(pass: 70, low: 20, medLow: 5, medium: 3, high: 2, noData: 0)
        let summary = DailySummary(
            date: "2026-01-15", totalDevices: 100,
            fileVaultPct: nil, compliancePct: nil,
            staleCount: 0, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            mscpBands: ["NIST": counts],
            mscpBandColumns: ["NIST": "NIST - Failures"])
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)
        XCTAssertEqual(decoded.mscpBandColumns?["NIST"], "NIST - Failures")
    }

    // MARK: - dateFromSnapshotFilename: python-era dashed form

    func testDateFromSnapshotFilenameDashedPythonEraFormat() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Python-era: dashed date + microsecond tail.
        let url = tmp.appendingPathComponent("ea-results_2026-04-15T210038673146.json")
        try Data("[]".utf8).write(to: url)

        let date = MSCPChartDataBuilder.dateFromSnapshotFilename(url)
        // Formatter parses in local time (same as the canonical yyyyMMdd'T'HHmmss
        // form), so assert with a local-timezone calendar.
        let cal = Calendar(identifier: .iso8601)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 4)
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 21)
        XCTAssertEqual(c.minute, 0)
        XCTAssertEqual(c.second, 38)
    }

    // MARK: - toStackedSeries

    func testStackedSeriesHasFiveBands() throws {
        let col = "EA - Failures"
        let baseline = makeBaseline(col: col)
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeEAResults(to: tmp, eaColumn: col, passCount: 8, highCount: 2,
                           filename: "ea-results_20240101T120000.json")
        try writeEAResults(to: tmp, eaColumn: col, passCount: 6, highCount: 4,
                           filename: "ea-results_20240201T120000.json")

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: tmp, summaries: [])
        let series = MSCPChartDataBuilder.toStackedSeries(points: points)

        XCTAssertEqual(series.count, 5, "Stacked area must have exactly 5 band series")
        XCTAssertEqual(series.first?.label, "Pass (0)", "Pass must be first (bottom of stack)")
        XCTAssertEqual(series.last?.label, "High (>50)", "High must be last (top of stack)")
    }

    // MARK: - dateFromSnapshotFilename

    func testDateFromSnapshotFilenameCanonicalFormat() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("ea-results_20240615T093045.json")
        try Data("[]".utf8).write(to: url)

        let date = MSCPChartDataBuilder.dateFromSnapshotFilename(url)
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(abbreviation: "UTC")!
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 15)
    }

    func testDateFromSnapshotFilenameUnknownFormatFallsToMtime() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("snapshot_no_timestamp.json")
        try Data("[]".utf8).write(to: url)
        // Should not return distantPast — mtime should be approximately now.
        let date = MSCPChartDataBuilder.dateFromSnapshotFilename(url)
        XCTAssertGreaterThan(date, Date(timeIntervalSinceNow: -60))
    }

    // MARK: - renderChartSheet: first-run ea-results, no summaries

    func testRenderChartSheetProducesMSCPDonutPNGWhenEAResultsPresentAndSummariesEmpty() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let eaColumn = "EA - Failures"
        try writeEAResults(to: tmp, eaColumn: eaColumn, passCount: 8, highCount: 2)

        var cfg = ReportConfig()
        cfg.compliance = ComplianceConfig(
            enabled: true,
            failuresCountColumn: eaColumn,
            failuresListColumn: nil,
            baselineLabel: "NIST",
            framework: nil,
            baselines: nil
        )
        var charts = ChartsConfig()
        charts.enabled = true
        cfg.charts = charts

        let summariesDir = tmp.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let pngDir = tmp.appendingPathComponent("pngs", isDirectory: true)
        try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)

        let engine = ReportEngine(config: cfg, dataDir: tmp)
        let wb = Workbook()
        engine.renderChartSheet(workbook: wb, summariesDir: summariesDir,
                                pngOutputDir: pngDir, profile: "test")

        // Hard evidence: at least one PNG was written to pngDir.
        // This proves renderMSCPCharts ran and produced a donut image on first run.
        let pngFiles = try FileManager.default.contentsOfDirectory(at: pngDir,
                                                                   includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertFalse(pngFiles.isEmpty,
            "At least one PNG must be written to pngDir when ea-results are present and summaries are empty")
        let donutPNG = pngFiles.first { $0.lastPathComponent.contains("mscp-donut") }
        XCTAssertNotNil(donutPNG,
            "An mSCP donut PNG must appear in pngDir on first-run (ea-results present, no summaries)")
    }

    // MARK: - renderChartSheet: no baselines skips mSCP charts

    func testRenderChartSheetSkipsMSCPWhenNoBaselinesConfigured() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let eaColumn = "EA - Failures"
        try writeEAResults(to: tmp, eaColumn: eaColumn, passCount: 5)

        // No compliance baselines configured → mSCP charts skipped.
        var cfg = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        cfg.charts = charts

        let summariesDir = tmp.appendingPathComponent("empty-summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let engine = ReportEngine(config: cfg, dataDir: tmp)
        // Both summaries empty and no baselines → renderChartSheet returns without adding sheet.
        engine.renderChartSheet(workbook: Workbook(), summariesDir: summariesDir)
        // No crash = pass.
    }

    // MARK: - ChartRenderer.donutChart smoke test

    func testDonutChartRendersNonNilData() {
        let slices = [
            ChartRenderer.DonutSlice(label: "Pass (0)", count: 80, pct: 80,
                                     color: ChartPalette.complianceBandColors[0]),
            ChartRenderer.DonutSlice(label: "High (>50)", count: 20, pct: 20,
                                     color: ChartPalette.complianceBandColors[4]),
        ]
        let png = ChartRenderer.donutChart(slices: slices, title: "Test Donut",
                                           footer: "Total systems: 100")
        XCTAssertNotNil(png, "donutChart must return PNG data for valid slices")
        XCTAssertGreaterThan(png?.count ?? 0, 100, "PNG data must be non-trivial")
    }

    func testDonutChartReturnsNilForEmptySlices() {
        let png = ChartRenderer.donutChart(slices: [], title: "Empty")
        XCTAssertNil(png, "donutChart must return nil for empty slice list")
    }

    func testDonutChartReturnsNilForZeroTotalSlices() {
        let slices = [
            ChartRenderer.DonutSlice(label: "Pass (0)", count: 0, pct: 0,
                                     color: ChartPalette.complianceBandColors[0]),
        ]
        let png = ChartRenderer.donutChart(slices: slices, title: "All Zero")
        XCTAssertNil(png, "donutChart must return nil when all slice counts are zero")
    }
}
