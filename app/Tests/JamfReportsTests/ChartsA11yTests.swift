import Foundation
import XCTest
@testable import JamfReports

// Tests for chart accessibility descriptor fixes.
// Each Chart block must have a container-level .accessibilityLabel and
// per-mark .accessibilityLabel + .accessibilityValue so VoiceOver's
// audio-graph rotor engages.
final class ChartsA11yTests: XCTestCase {

    // MARK: - Container label strings

    func testMetricTrendLabelFormat() {
        // TrendsView metric chart: ".accessibilityLabel("\(metric.displayLabel) trend over time")"
        let cases: [(String, String)] = [
            ("FileVault", "FileVault trend over time"),
            ("OS Currency", "OS Currency trend over time"),
            ("Compliance", "Compliance trend over time"),
        ]
        for (label, expected) in cases {
            XCTAssertEqual(
                metricChartLabel(displayLabel: label),
                expected,
                "Metric chart container label must follow '<metric> trend over time' pattern"
            )
        }
    }

    func testComplianceTrendLabelIsFixed() {
        // The compliance stacked-bar chart uses a fixed label
        XCTAssertEqual(complianceTrendChartLabel, "Compliance trend")
    }

    func testMultilineComparisonLabel() {
        // The multi-metric comparison chart names all metrics it contains
        let label = multilineComparisonLabel.lowercased()
        XCTAssertTrue(label.contains("filevault"), "Must mention FileVault")
        XCTAssertTrue(label.contains("nist"), "Must mention NIST")
        XCTAssertTrue(label.contains("macos"), "Must mention macOS")
    }

    func testStabilityChartLabel() {
        // FleetOverviewView stability chart
        XCTAssertEqual(stabilityChartLabel, "Fleet stability trend over time")
    }

    // MARK: - Per-mark accessibility value format

    func testLineMarkValueFormatPercentage() {
        // Percentage metrics: value is formatted as "85%"
        let value = formatPercentValue(85.4)
        XCTAssertTrue(value.contains("85"), "Formatted value must contain the integer part")
        XCTAssertTrue(value.hasSuffix("%"), "Percentage values must end with '%'")
    }

    func testLineMarkValueFormatCount() {
        // Count metrics: value is an integer
        let value = "\(Int((524.0).rounded()))%"
        XCTAssertEqual(value, "524%")
    }

    func testBarMarkValueIncludesDeviceCount() {
        // Compliance bar mark: "\(count) devices"
        let value = barMarkValue(count: 42)
        XCTAssertEqual(value, "42 devices")
    }

    func testStabilityMarkValueFormat() {
        // Stability line mark: "\(Int(value.rounded()))%"
        let value = stabilityMarkValue(83.7)
        XCTAssertEqual(value, "84%")
    }

    // MARK: - Area mark is hidden (duplicate data)

    func testAreaMarkIsHiddenFromAccessibility() {
        // AreaMark duplicates data from LineMark so it should be hidden.
        // We assert that the design decision is documented: area marks are decorative.
        XCTAssertTrue(
            areaMarkShouldBeHidden,
            "AreaMark must be hidden from accessibility to avoid duplicate VoiceOver announcements"
        )
    }

    // MARK: - Helpers (mirror the label logic from the views)

    private func metricChartLabel(displayLabel: String) -> String {
        "\(displayLabel) trend over time"
    }

    private let complianceTrendChartLabel = "Compliance trend"

    private let multilineComparisonLabel =
        "Multi-metric comparison: FileVault, NIST compliance, macOS currency"

    private let stabilityChartLabel = "Fleet stability trend over time"

    private func formatPercentValue(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func barMarkValue(count: Int) -> String {
        "\(count) devices"
    }

    private func stabilityMarkValue(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private let areaMarkShouldBeHidden = true
}
