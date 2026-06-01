import XCTest
@testable import JamfReports

/// Tests for compliance benchmark label override behavior.
///
/// Covers:
/// - `TrendSeries.Metric.displayLabel` generic default
/// - `TrendSeries.Metric.displayLabel(benchmarkLabel:)` override scoping
/// - `WorkspaceStore.complianceBenchmarkLabel` preference ordering
@MainActor
final class ComplianceBenchmarkLabelTests: XCTestCase {

    // MARK: - Metric.displayLabel generic default

    func testComplianceMetricDefaultLabelIsGeneric() {
        XCTAssertEqual(TrendSeries.Metric.compliance.displayLabel, "Compliance Benchmark")
    }

    func testOtherMetricsAreUnchanged() {
        XCTAssertEqual(TrendSeries.Metric.fileVault.displayLabel, "FileVault Encryption")
        XCTAssertEqual(TrendSeries.Metric.osCurrent.displayLabel, "On Current macOS")
        XCTAssertEqual(TrendSeries.Metric.patch.displayLabel, "Patch Compliance")
        XCTAssertEqual(TrendSeries.Metric.stability.displayLabel, "Stability Index")
    }

    // MARK: - Metric.displayLabel(benchmarkLabel:) override

    func testBenchmarkLabelOverridesComplianceMetric() {
        XCTAssertEqual(
            TrendSeries.Metric.compliance.displayLabel(benchmarkLabel: "DISA STIG"),
            "DISA STIG"
        )
    }

    func testBenchmarkLabelDoesNotAffectOtherMetrics() {
        XCTAssertEqual(
            TrendSeries.Metric.fileVault.displayLabel(benchmarkLabel: "DISA STIG"),
            "FileVault Encryption",
            "Non-compliance metrics must not be overridden by benchmarkLabel"
        )
        XCTAssertEqual(
            TrendSeries.Metric.patch.displayLabel(benchmarkLabel: "DISA STIG"),
            "Patch Compliance"
        )
    }

    func testNilBenchmarkLabelReturnsFallback() {
        XCTAssertEqual(
            TrendSeries.Metric.compliance.displayLabel(benchmarkLabel: nil),
            "Compliance Benchmark"
        )
    }

    func testEmptyBenchmarkLabelReturnsFallback() {
        XCTAssertEqual(
            TrendSeries.Metric.compliance.displayLabel(benchmarkLabel: ""),
            "Compliance Benchmark"
        )
    }

    func testWhitespace0nlyBenchmarkLabelPassesThrough() {
        // The method only checks !isEmpty; trimming is WorkspaceStore's responsibility.
        // WorkspaceStore.complianceBenchmarkLabel never returns a whitespace-only string.
        XCTAssertEqual(
            TrendSeries.Metric.compliance.displayLabel(benchmarkLabel: "   "),
            "   "
        )
    }

    // MARK: - WorkspaceStore.complianceBenchmarkLabel

    func testStoreBaselineLabelTakesPriority() {
        let store = WorkspaceStore(demoMode: false)
        store.configState.baselineLabel = "NIST 800-53r5 Moderate"
        store.configState.complianceBenchmarks = ["CIS Benchmark"]
        XCTAssertEqual(store.complianceBenchmarkLabel, "NIST 800-53r5 Moderate")
    }

    func testStoreFallsBackToBenchmarksTitleWhenBaselinesLabelEmpty() {
        let store = WorkspaceStore(demoMode: false)
        store.configState.baselineLabel = ""
        store.configState.complianceBenchmarks = ["CIS Benchmark", "DISA STIG"]
        XCTAssertEqual(store.complianceBenchmarkLabel, "CIS Benchmark")
    }

    func testStoreReturnsNilWhenBothEmpty() {
        let store = WorkspaceStore(demoMode: false)
        store.configState.baselineLabel = ""
        store.configState.complianceBenchmarks = []
        XCTAssertNil(store.complianceBenchmarkLabel)
    }

    func testStoreTrimsWhitespaceFromBaselineLabel() {
        let store = WorkspaceStore(demoMode: false)
        store.configState.baselineLabel = "  NIST 800-53r5  "
        XCTAssertEqual(store.complianceBenchmarkLabel, "NIST 800-53r5")
    }
}
