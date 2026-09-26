import XCTest
@testable import JamfReports

/// Pins `TrendsView.lineSegmentIndices`: the hero line breaks at a gap well past the
/// history's own cadence, and nowhere else.
final class TrendsViewLineSegmentTests: XCTestCase {

    private func days(_ offsets: [Int]) -> [Date] {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        return offsets.map { start.addingTimeInterval(Double($0) * 86_400) }
    }

    func testEmptyAndSinglePointAreOneSegment() {
        XCTAssertEqual(TrendsView.lineSegmentIndices([]), [])
        XCTAssertEqual(TrendsView.lineSegmentIndices(days([0])), [0])
    }

    func testRegularDailyHistoryIsOneSegment() {
        XCTAssertEqual(
            TrendsView.lineSegmentIndices(days(Array(0...9))),
            Array(repeating: 0, count: 10)
        )
    }

    func testTwoWeekGapInDailyHistoryBreaksTheLine() {
        // The shot-41 shape: daily points, then nothing from Sep 5 to Sep 19.
        let dates = days([0, 1, 2, 3, 4, 5, 6, 7, 21, 22, 23])
        XCTAssertEqual(TrendsView.lineSegmentIndices(dates), [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1])
    }

    func testWeekendGapInWeekdayHistoryStaysJoined() {
        // Mon–Fri collects: a three-day weekend gap is under the four-day minimum.
        let dates = days([0, 1, 2, 3, 4, 7, 8, 9, 10, 11])
        XCTAssertEqual(TrendsView.lineSegmentIndices(dates), Array(repeating: 0, count: 10))
    }

    func testOneMissedWeekInWeeklyHistoryStaysJoined() {
        // Weekly cadence: a 14-day gap is two intervals, under the 2.5x factor.
        let dates = days([0, 7, 14, 28, 35])
        XCTAssertEqual(TrendsView.lineSegmentIndices(dates), [0, 0, 0, 0, 0])
    }

    func testLongGapInWeeklyHistoryBreaksTheLine() {
        let dates = days([0, 7, 14, 42, 49])
        XCTAssertEqual(TrendsView.lineSegmentIndices(dates), [0, 0, 0, 1, 1])
    }

    func testGapIsNotTakenAsTheCadenceWhenHalfTheIntervalsAreIt() {
        // A daily history clipped by the range start: intervals of 1 and 14 days.
        XCTAssertEqual(TrendsView.lineSegmentIndices(days([4, 5, 19])), [0, 0, 1])
    }

    func testEachGapStartsANewSegment() {
        let dates = days([0, 1, 2, 10, 11, 12, 30, 31])
        XCTAssertEqual(TrendsView.lineSegmentIndices(dates), [0, 0, 0, 1, 1, 1, 2, 2])
    }
}
