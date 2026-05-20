import Foundation
import XCTest
@testable import JamfReports

// MARK: - ChartWiringTests
// Tests for ReportEngine.renderChartSheet and the config-driven chart branches.
// Verifies each branch executes without error; full sheet-name introspection
// would require exposing Workbook internals, so we rely on no-throw behavior.

final class ChartWiringTests: XCTestCase {

    // MARK: - Helpers

    private func makeSummary(
        date: String,
        totalDevices: Int = 100,
        fileVaultPct: Double = 90.0,
        patchPct: Double = 80.0,
        staleCount: Int = 5,
        osCurrentPct: Double = 70.0,
        compliancePct: Double? = nil
    ) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct,
            compliancePct: compliancePct,
            staleCount: staleCount,
            osCurrentPct: osCurrentPct,
            crowdstrikePct: nil,
            patchPct: patchPct,
            source: "jamf-cli"
        )
    }

    private func writeSummary(_ summary: DailySummary, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(summary)
        let file = dir.appendingPathComponent("summary_\(summary.date).json")
        try data.write(to: file)
    }

    private func tempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-charts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Empty summaries dir produces no crash

    func testRenderChartSheetEmptyDirDoesNotCrash() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = ReportConfig()
        let engine = ReportEngine(config: config, dataDir: tmp)
        // Should complete without crashing or throwing.
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - Single summary produces chart path without error

    func testRenderChartSheetSingleSummary() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01"), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - Two summaries triggers line chart (time series path)

    func testRenderChartSheetTwoSummaries() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01"), to: tmp)
        try writeSummary(makeSummary(date: "2026-02-01"), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - deviceStateTrend.enabled=true branch

    func testDeviceStateTrendEnabledBranch() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01", staleCount: 10), to: tmp)
        try writeSummary(makeSummary(date: "2026-02-01", staleCount: 8), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        var dss = DeviceStateTrendConfig()
        dss.enabled = true
        charts.deviceStateTrend = dss
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - perMajorCharts=true branch (no inventory-summary needed)

    func testPerMajorChartsBranchFallback() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01", osCurrentPct: 75.0), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        var osAdopt = OSAdoptionConfig()
        osAdopt.perMajorCharts = true
        charts.osAdoption = osAdopt
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        // Falls back to summary.osCurrentPct when no inventory-summary snapshot exists.
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - complianceTrend.bands with matching compliance pct

    func testComplianceBandsBranchWithMatchingData() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSummary(makeSummary(date: "2026-01-01", compliancePct: 0), to: tmp)
        try writeSummary(makeSummary(date: "2026-02-01", compliancePct: 0), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        charts.complianceTrend = ComplianceTrendConfig(
            enabled: true,
            bands: [ComplianceBandConfig(label: "Pass", minFailures: 0, maxFailures: 0,
                                          color: "#4472C4")]
        )
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }

    // MARK: - complianceTrend.bands skipped when summaries have no compliancePct

    func testComplianceBandsSkippedWhenNoCompliancePct() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // compliancePct is nil in these summaries (jamf-cli source, no CSV)
        try writeSummary(makeSummary(date: "2026-01-01", compliancePct: nil), to: tmp)

        var config = ReportConfig()
        var charts = ChartsConfig()
        charts.enabled = true
        charts.complianceTrend = ComplianceTrendConfig(
            enabled: true,
            bands: [ComplianceBandConfig(label: "Pass", minFailures: 0, maxFailures: 0,
                                          color: "#4472C4")]
        )
        config.charts = charts

        let engine = ReportEngine(config: config, dataDir: tmp)
        // Should not crash — compliance band section is silently skipped.
        engine.renderChartSheet(workbook: Workbook(), summariesDir: tmp)
    }
}
