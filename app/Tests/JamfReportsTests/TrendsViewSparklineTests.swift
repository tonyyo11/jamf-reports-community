import XCTest
@testable import JamfReports

/// Pins `TrendsView.sparklineValues`: a pill's line covers the whole selected range, as the
/// pill's change does, not only its last few snapshots.
final class TrendsViewSparklineTests: XCTestCase {

    func testASeriesWithinTheLimitIsDrawnWhole() {
        let series: [Double] = [664, 665, 663, 664]
        XCTAssertEqual(TrendsView.sparklineValues(series), series)
    }

    func testALongSeriesKeepsItsFirstAndLastValues() {
        let series = (0..<61).map(Double.init)
        let line = TrendsView.sparklineValues(series, limit: 24)
        XCTAssertEqual(line.count, 24)
        XCTAssertEqual(line.first, 0)
        XCTAssertEqual(line.last, 60)
    }

    func testAThinnedLineStaysInOrderAcrossTheRange() {
        let series = (0..<100).map(Double.init)
        let line = TrendsView.sparklineValues(series, limit: 10)
        XCTAssertEqual(line, line.sorted())
        XCTAssertEqual(Set(line).count, 10)
    }

    func testAnEarlyChangeStillShowsInTheLine() {
        // The last eight days are flat; the change the pill reports happened before them.
        let series: [Double] = Array(repeating: 600, count: 20) + Array(repeating: 664, count: 8)
        let line = TrendsView.sparklineValues(series)
        XCTAssertEqual(line.first, 600)
        XCTAssertEqual(line.last, 664)
    }
}
