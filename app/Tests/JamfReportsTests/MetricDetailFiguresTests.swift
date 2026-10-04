import XCTest
@testable import JamfReports

/// Visual review 2026-10-04: a metric drill-down for a metric with no values showed 0.0%
/// current, 0.0% previous and "+0.0pp" over 0 summaries, as if the fleet were measured at
/// zero. A value that does not exist is not shown as 0.
final class MetricDetailFiguresTests: XCTestCase {

    func testDrillDownFiguresDoNotInventZeros() {
        func value(_ v: Double) -> String { String(format: "%.1f%%", v) }
        func delta(_ v: Double) -> String { String(format: "%+.1fpp", v) }
        let none = MetricDetailFigures.make(values: [], value: value, delta: delta)
        XCTAssertEqual(none.current, "No data yet")
        XCTAssertEqual(none.previous, "No data yet")
        XCTAssertEqual(none.change, "—")
        XCTAssertFalse(none.hasChange)

        let one = MetricDetailFigures.make(values: [95.6], value: value, delta: delta)
        XCTAssertEqual(one.current, "95.6%")
        XCTAssertEqual(one.previous, "—")
        XCTAssertFalse(one.hasChange)

        let many = MetricDetailFigures.make(values: [90, 95, 96], value: value, delta: delta)
        XCTAssertEqual([many.current, many.previous, many.change], ["96.0%", "95.0%", "+6.0pp"])
        XCTAssertTrue(many.hasChange)
        XCTAssertEqual(MetricDetailFigures.summaryCount(0), "0 summaries")
        XCTAssertEqual(MetricDetailFigures.summaryCount(1), "1 summary")
    }
}
