import XCTest
@testable import JamfReports

/// Pins the Trends hero's no-data text: a metric with no points in range shows a dash for its
/// value, its min/max/avg and its pill's change, never a "0%" that reads as measured.
final class TrendsViewNoDataTests: XCTestCase {

    func testMissingValueIsADash() {
        XCTAssertEqual(TrendsView.metricValueText(nil, unit: "%"), "—")
        XCTAssertEqual(TrendsView.metricValueText(nil, unit: ""), "—")
    }

    func testMeasuredZeroStillReadsZero() {
        XCTAssertEqual(TrendsView.metricValueText(0, unit: "%"), "0%")
    }

    func testValueIsRoundedWithItsUnit() {
        XCTAssertEqual(TrendsView.metricValueText(70.6, unit: "%"), "71%")
        XCTAssertEqual(TrendsView.metricValueText(524, unit: ""), "524")
    }

    func testNoValuesHaveNoStats() {
        XCTAssertNil(TrendsView.valueStats([]))
    }

    func testStatsOfValues() throws {
        let stats = try XCTUnwrap(TrendsView.valueStats([60, 90, 75]))
        XCTAssertEqual(stats.min, 60)
        XCTAssertEqual(stats.max, 90)
        XCTAssertEqual(stats.avg, 75, accuracy: 0.0001)
    }

    func testPillWithNoPointsShowsADash() {
        XCTAssertEqual(TrendsView.pillDeltaText(metric: .patch, series: []), "—")
    }

    /// A share's change is in percentage points with one decimal; a count's is a whole number.
    func testPillChangeKeepsItsSignAndFlatForm() {
        XCTAssertEqual(TrendsView.pillDeltaText(metric: .patch, series: [70, 72.4]), "+2.4 pp")
        XCTAssertEqual(TrendsView.pillDeltaText(metric: .patch, series: [90, 87]), "-3.0 pp")
        XCTAssertEqual(TrendsView.pillDeltaText(metric: .stale, series: [40, 30]), "-10")
        XCTAssertEqual(TrendsView.pillDeltaText(metric: .fileVault, series: [50, 50.04]), "±0")
        XCTAssertEqual(TrendsView.pillDeltaText(metric: .fileVault, series: [50]), "±0")
    }

    func testPillWithNoPointsTellsVoiceOverSo() {
        XCTAssertEqual(
            TrendsView.metricPillAccessibilityLabel(
                label: "Patch Compliance", metric: .patch, series: []
            ),
            "Patch Compliance, no snapshots in range"
        )
    }

    func testPillAccessibilityLabelNamesDirectionFromThePolarity() {
        func label(_ metric: TrendSeries.Metric, _ series: [Double]) -> String {
            TrendsView.metricPillAccessibilityLabel(label: "X", metric: metric, series: series)
        }
        XCTAssertEqual(label(.fileVault, [70, 72.4]), "X, improving, +2.4 pp change")
        XCTAssertEqual(label(.fileVault, [72.4, 70]), "X, declining, -2.4 pp change")
        XCTAssertEqual(label(.stale, [20, 11]), "X, improving, -9 change")
        XCTAssertEqual(label(.stale, [11, 20]), "X, declining, +9 change")
        XCTAssertEqual(label(.activeDevices, [80, 99]), "X, up, +19 change")
        XCTAssertEqual(label(.activeDevices, [99, 80]), "X, down, -19 change")
        XCTAssertEqual(label(.fileVault, [70]), "X, unchanged")
    }
}
