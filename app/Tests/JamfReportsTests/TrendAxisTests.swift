import XCTest
@testable import JamfReports

/// The Trends X axis: one label per tick, and no two ticks with the same label.
final class TrendAxisTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The format pinned to English and UTC so the labels do not follow the machine running
    /// the test.
    private func pinned(_ format: Date.FormatStyle) -> Date.FormatStyle {
        var pinned = format
        pinned.locale = Locale(identifier: "en_US")
        pinned.calendar = calendar
        pinned.timeZone = calendar.timeZone
        return pinned
    }

    /// The labels a month-stepped axis draws over the `weeks` ending at `end`: a tick on the
    /// first of every `count`th month inside the window.
    private func monthLabels(range: TrendRange, weeks: Int, endingOn end: Date) -> [String] {
        guard let step = TrendAxis.step(for: range), step.component == .month,
              let format = TrendAxis.dateFormat(for: range) else { return [] }
        let start = calendar.date(byAdding: .day, value: -7 * weeks, to: end)!
        var tick = calendar.date(
            from: calendar.dateComponents([.year, .month], from: start))!
        if tick < start { tick = calendar.date(byAdding: .month, value: 1, to: tick)! }
        let styled = pinned(format)
        var labels: [String] = []
        while tick <= end {
            labels.append(tick.formatted(styled))
            tick = calendar.date(byAdding: .month, value: step.count, to: tick)!
        }
        return labels
    }

    func testTheLongRangesStepByMonthAndTheShortOnesByDay() {
        XCTAssertEqual(TrendAxis.step(for: .w4)?.component, .day)
        XCTAssertEqual(TrendAxis.step(for: .w4)?.count, 7)
        XCTAssertEqual(TrendAxis.step(for: .w12)?.component, .day)
        XCTAssertEqual(TrendAxis.step(for: .w12)?.count, 14)
        XCTAssertEqual(TrendAxis.step(for: .w26)?.component, .month)
        XCTAssertEqual(TrendAxis.step(for: .w26)?.count, 1)
        XCTAssertEqual(TrendAxis.step(for: .w52)?.component, .month)
        XCTAssertEqual(TrendAxis.step(for: .w52)?.count, 2)
    }

    /// All leaves both to Charts: a fixed year-only label printed "2026" at every tick.
    func testAllLeavesTheStepAndTheLabelToCharts() {
        XCTAssertNil(TrendAxis.step(for: .all))
        XCTAssertNil(TrendAxis.dateFormat(for: .all))
    }

    /// The W26 axis of the production screenshot: 28-day steps from the window's start put
    /// two ticks in June.
    func testW26OverFiveMonthsLabelsEachMonthOnce() {
        XCTAssertEqual(
            monthLabels(range: .w26, weeks: 26, endingOn: date(2026, 10, 5)),
            ["May 2026", "Jun 2026", "Jul 2026", "Aug 2026", "Sep 2026", "Oct 2026"])
    }

    /// "Jun 26" reads as the 26th of June.
    func testMonthLabelsNameTheYearInFull() throws {
        for range in [TrendRange.w26, .w52] {
            let format = try XCTUnwrap(TrendAxis.dateFormat(for: range))
            XCTAssertEqual(date(2026, 6, 1).formatted(pinned(format)), "Jun 2026", "\(range)")
        }
    }

    func testNoTwoTicksShareALabelWhateverDayTheWindowEnds() {
        for (range, weeks) in [(TrendRange.w26, 26), (.w52, 52)] {
            for offset in 0..<420 {
                let end = calendar.date(byAdding: .day, value: offset, to: date(2025, 9, 1))!
                let labels = monthLabels(range: range, weeks: weeks, endingOn: end)
                XCTAssertEqual(Set(labels).count, labels.count, "\(range) ending \(end)")
                XCTAssertTrue((3...13).contains(labels.count), "\(range) ending \(end)")
            }
        }
    }

    func testDayLabelsNameTheMonthAndDay() throws {
        let format = try XCTUnwrap(TrendAxis.dateFormat(for: .w12))
        XCTAssertEqual(date(2026, 4, 1).formatted(pinned(format)), "Apr 1")
    }
}
