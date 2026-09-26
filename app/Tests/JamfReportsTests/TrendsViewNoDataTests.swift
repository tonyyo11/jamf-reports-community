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
        XCTAssertEqual(TrendsView.pillDeltaText(series: [], unit: "%"), "—")
    }

    func testPillChangeKeepsItsSignAndFlatForm() {
        XCTAssertEqual(TrendsView.pillDeltaText(series: [70, 72.4], unit: "%"), "+2%")
        XCTAssertEqual(TrendsView.pillDeltaText(series: [40, 30], unit: ""), "-10")
        XCTAssertEqual(TrendsView.pillDeltaText(series: [50, 50.3], unit: "%"), "±0%")
        XCTAssertEqual(TrendsView.pillDeltaText(series: [50], unit: "%"), "±0%")
    }
}
