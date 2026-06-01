import Foundation
import XCTest
import Charts
@testable import JamfReports

// Tests for chart accessibility wiring.
//
// Container labels: TrendsView and FleetOverviewView expose `nonisolated static`
// label helpers (`metricTrendChartLabel`, `complianceTrendChartLabel`,
// `multilineComparisonChartLabel`, `stabilityChartLabel`) that the views apply
// via `.accessibilityLabel(...)` on their Chart containers. These tests assert
// the production helpers directly.
//
// AXChartDescriptor wiring: TrendsView uses `.accessibilityChartDescriptor`
// with TrendLineChartDescriptor / StackedBarChartDescriptor / MultiLineChartDescriptor;
// OS distribution charts use SectorChartDescriptor. These tests assert the
// production descriptor types from AccessibilityDescriptors.swift produce
// valid, non-empty output for representative inputs.
final class ChartsA11yTests: XCTestCase {

    // MARK: - Container label strings (production helpers)

    func testMetricTrendLabelFormat() {
        // TrendsView hero chart applies `.accessibilityLabel(Self.metricTrendChartLabel(...))`.
        let cases: [(String, String)] = [
            ("FileVault", "FileVault trend over time"),
            ("OS Currency", "OS Currency trend over time"),
            ("Compliance", "Compliance trend over time"),
        ]
        for (label, expected) in cases {
            XCTAssertEqual(
                TrendsView.metricTrendChartLabel(label),
                expected,
                "Metric chart container label must follow '<metric> trend over time' pattern"
            )
        }
    }

    func testComplianceTrendLabelIsFixed() {
        // The compliance stacked-bar chart uses a fixed production label.
        XCTAssertEqual(TrendsView.complianceTrendChartLabel, "Compliance trend")
    }

    func testMultilineComparisonLabel() {
        // The multi-metric comparison chart names all metrics it contains.
        // "NIST" was removed — the label now uses the generic "Compliance" token.
        let label = TrendsView.multilineComparisonChartLabel.lowercased()
        XCTAssertTrue(label.contains("filevault"), "Must mention FileVault")
        XCTAssertTrue(label.contains("compliance"), "Must mention Compliance")
        XCTAssertTrue(label.contains("macos"), "Must mention macOS")
    }

    func testStabilityChartLabel() {
        // FleetOverviewView stability chart container label.
        XCTAssertEqual(FleetOverviewView.stabilityChartLabel, "Fleet stability trend over time")
    }

    // MARK: - AXChartDescriptor wiring assertions

    /// TrendLineChartDescriptor must produce a descriptor with the correct title,
    /// one series, and as many data points as input dates.
    func testTrendLineChartDescriptorWiring() {
        let dates: [Date] = [
            Date(timeIntervalSince1970: 1_740_000_000),
            Date(timeIntervalSince1970: 1_740_604_800),
            Date(timeIntervalSince1970: 1_741_209_600),
        ]
        let values: [Double] = [82.0, 85.5, 88.0]
        let descriptor = TrendLineChartDescriptor(
            title: "FileVault Encryption Trend",
            seriesName: "FileVault",
            dates: dates,
            values: values,
            unit: "%"
        )
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.title, "FileVault Encryption Trend",
                       "Descriptor title must match the supplied title")
        XCTAssertEqual(ax.series.count, 1, "TrendLine must produce exactly one series")
        XCTAssertEqual(ax.series[0].dataPoints.count, 3,
                       "Series must contain one point per input date")
        XCTAssertFalse(ax.summary?.isEmpty ?? true,
                       "Descriptor must include a non-empty summary string")
    }

    /// SectorChartDescriptor must produce a descriptor whose series has the correct
    /// slice count and whose summary mentions all category labels.
    func testSectorChartDescriptorWiring() {
        let slices: [SectorChartDescriptor.Slice] = [
            .init(label: "macOS 15 Tahoe", value: 320),
            .init(label: "macOS 14 Sonoma", value: 150),
            .init(label: "macOS 13 Ventura", value: 54),
        ]
        let descriptor = SectorChartDescriptor(
            title: "OS Distribution",
            unit: " devices",
            slices: slices
        )
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.title, "OS Distribution")
        XCTAssertEqual(ax.series[0].dataPoints.count, 3,
                       "Sector descriptor must have one data point per slice")
        guard let summary = ax.summary else {
            XCTFail("SectorChartDescriptor must produce a non-nil summary")
            return
        }
        XCTAssertTrue(summary.contains("Tahoe"), "Summary must mention Tahoe slice")
        XCTAssertTrue(summary.contains("Sonoma"), "Summary must mention Sonoma slice")
    }

    /// BarDistributionChartDescriptor must produce a descriptor with isContinuous=false
    /// and the correct bar count.
    func testBarDistributionChartDescriptorWiring() {
        let bars: [BarDistributionChartDescriptor.Bar] = [
            .init(label: "Pass", value: 420),
            .init(label: "Low", value: 64),
            .init(label: "Medium", value: 28),
            .init(label: "High", value: 12),
        ]
        let descriptor = BarDistributionChartDescriptor(
            title: "Compliance Distribution",
            unit: " devices",
            bars: bars
        )
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.series[0].dataPoints.count, 4)
        XCTAssertFalse(ax.series[0].isContinuous,
                       "Bar chart series must be non-continuous (categorical)")
        XCTAssertTrue(ax.summary?.contains("Pass") ?? false,
                      "Summary must mention the Pass bar")
    }

    /// StackedBarChartDescriptor must produce one series per band and each series
    /// must have as many data points as the date labels array.
    func testStackedBarChartDescriptorWiring() {
        let dateLabels = ["2026-03-01", "2026-03-08", "2026-03-15"]
        let bands: [StackedBarChartDescriptor.Band] = [
            .init(name: "Pass",   dateLabels: dateLabels, values: [350, 360, 380]),
            .init(name: "Low",    dateLabels: dateLabels, values: [80, 75, 70]),
            .init(name: "Medium", dateLabels: dateLabels, values: [50, 48, 42]),
        ]
        let descriptor = StackedBarChartDescriptor(
            title: "Compliance Over Time",
            dateLabels: dateLabels,
            bands: bands
        )
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.series.count, 3, "Must produce one series per band")
        XCTAssertEqual(ax.series[0].name, "Pass")
        XCTAssertEqual(ax.series[0].dataPoints.count, 3,
                       "Each series must have one point per date label")
    }

    /// MultiLineChartDescriptor must produce one series per supplied metric series.
    func testMultiLineChartDescriptorWiring() {
        let dates: [Date] = [
            Date(timeIntervalSince1970: 1_740_000_000),
            Date(timeIntervalSince1970: 1_740_604_800),
        ]
        let seriesList: [MultiLineChartDescriptor.Series] = [
            .init(name: "FileVault",   dates: dates, values: [90.0, 92.0]),
            .init(name: "Compliance", dates: dates, values: [75.0, 78.0]),
            .init(name: "macOS Currency",  dates: dates, values: [60.0, 65.0]),
        ]
        let descriptor = MultiLineChartDescriptor(
            title: "Security Posture Compared",
            seriesList: seriesList
        )
        let ax = descriptor.makeChartDescriptor()
        XCTAssertEqual(ax.title, "Security Posture Compared")
        XCTAssertEqual(ax.series.count, 3, "Must produce one series per metric")
    }
}
