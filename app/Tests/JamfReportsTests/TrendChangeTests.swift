import XCTest
@testable import JamfReports

/// The Trends hero's and pills' change: percentage points for a share or score, a whole
/// number for a count, coloured by the metric's polarity and only when it rounds to something.
final class TrendChangeTests: XCTestCase {

    private func change(
        _ metric: TrendSeries.Metric, _ first: Double, _ last: Double
    ) -> TrendChange {
        TrendChange(metric: metric, first: first, last: last)
    }

    /// Live: the Stability Index moved 2 points and read "↓ 2% (-3.7%)".
    func testShareChangeIsInPercentagePointsWithNoSecondPercentage() {
        let drop = change(.stability, 54.0, 52.0)
        XCTAssertEqual(drop.direction, .down)
        XCTAssertEqual(drop.size, "2.0 pp")
        XCTAssertEqual(drop.heroText(relativeChange: nil), "2.0 pp")
        XCTAssertEqual(drop.pillText, "-2.0 pp")
        XCTAssertEqual(change(.patch, 58.0, 60.5).pillText, "+2.5 pp")
    }

    /// Live: FileVault -0.3 pp read "↓ 0% (-0.3%)" in red. It is a 0.3 pp drop, worse for a
    /// share where higher is better; a 0.04 pp one rounds to nothing and has no colour.
    func testSmallShareChangeShowsItsDecimalAndOnlyZeroIsFlat() {
        let small = change(.fileVault, 92.3, 92.0)
        XCTAssertEqual(small.size, "0.3 pp")
        XCTAssertEqual(small.verdict, .worse)

        let none = change(.fileVault, 92.0, 92.04)
        XCTAssertEqual(none.direction, .flat)
        XCTAssertEqual(none.verdict, .neutral)
        XCTAssertEqual(none.heroText(relativeChange: nil), "No change")
        XCTAssertEqual(none.pillText, "±0")
        XCTAssertEqual(none.symbol, "minus")
    }

    func testVerdictFollowsThePolarityOfTheMetric() {
        XCTAssertEqual(change(.fileVault, 90, 92).verdict, .better)
        XCTAssertEqual(change(.fileVault, 92, 90).verdict, .worse)
        XCTAssertEqual(change(.stale, 20, 11).verdict, .better, "fewer stale devices")
        XCTAssertEqual(change(.stale, 11, 20).verdict, .worse)
        XCTAssertEqual(change(.activeDevices, 80, 99).verdict, .neutral, "no good direction")
        XCTAssertEqual(change(.managedDevices, 99, 80).verdict, .neutral)
    }

    func testCountChangeIsWholeDevicesWithItsRelativeChange() {
        let fewer = change(.stale, 20, 11)
        XCTAssertEqual(fewer.size, "9")
        XCTAssertEqual(fewer.symbol, "arrow.down")
        XCTAssertEqual(fewer.heroText(relativeChange: -45.0), "9 (-45.0%)")
        XCTAssertEqual(fewer.heroText(relativeChange: nil), "9")
        XCTAssertEqual(fewer.pillText, "-9")
        XCTAssertEqual(change(.stale, 11.2, 11.4).direction, .flat, "a count rounds to whole")
    }

    // MARK: - Hero and pill entry points

    func testSnapshotCountIsPlural() {
        XCTAssertEqual(TrendsView.snapshotCountText(1), "1 snapshot")
        XCTAssertEqual(TrendsView.snapshotCountText(45), "45 snapshots")
    }

    func testNoPointsHasNoChange() {
        XCTAssertNil(TrendsView.trendChange(metric: .patch, series: []))
        XCTAssertEqual(TrendsView.trendChange(metric: .patch, series: [70, 72])?.size, "2.0 pp")
    }

    // MARK: - Legend

    func testSnapshotCadenceLabelNamesTheActualCadence() {
        func dates(every days: Double, count: Int) -> [Date] {
            (0..<count).map { Date(timeIntervalSince1970: Double($0) * days * 86_400) }
        }
        func label(_ days: Double, _ count: Int) -> String {
            TrendsView.snapshotCadenceLabel(dates(every: days, count: count))
        }
        XCTAssertEqual(label(1, 10), "Daily snapshot")
        XCTAssertEqual(label(7, 10), "Weekly snapshot")
        XCTAssertEqual(label(30, 4), "Snapshot")
        XCTAssertEqual(label(1, 1), "Snapshot")
        XCTAssertEqual(TrendsView.snapshotCadenceLabel([]), "Snapshot")
    }

    /// A weekday-only collect schedule leaves weekend gaps; the lower median is still a day.
    func testSnapshotCadenceIgnoresWeekendGaps() {
        let days = [0.0, 1, 2, 3, 4, 7, 8, 9, 10, 11, 14, 15]
        let dates = days.map { Date(timeIntervalSince1970: $0 * 86_400) }
        XCTAssertEqual(TrendsView.snapshotCadenceLabel(dates), "Daily snapshot")
    }
}
