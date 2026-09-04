import XCTest
@testable import JamfReports

final class ReportPeriodTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func d(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current; f.calendar = cal
        return f.date(from: s)!
    }

    /// A boundary that lands exactly on a snapshot reports that date with no drift.
    func testExactBoundaryHasNoDrift() throws {
        let dates = [d("2026-04-01"), d("2026-05-01"), d("2026-06-30")]
        let p = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: dates, now: d("2026-07-15"), calendar: cal))
        XCTAssertEqual(p.start.resolved, d("2026-04-01"))
        XCTAssertEqual(p.start.driftDays, 0)
        XCTAssertFalse(p.start.isAdrift)
    }

    /// The resolved date is the snapshot's own, and drift beyond three days is
    /// marked so a figure quoted into a document is never silently misdated.
    func testDriftedStartIsReportedAndMarked() throws {
        let dates = [d("2026-04-19"), d("2026-06-30")]
        let p = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: dates, now: d("2026-07-15"), calendar: cal))
        XCTAssertEqual(
            p.start.resolved, d("2026-04-19"), "must report the real date, not the requested one"
        )
        XCTAssertEqual(p.start.driftDays, 18)
        XCTAssertTrue(p.start.isAdrift)
    }

    func testDriftAtExactlyThresholdIsNotMarked() throws {
        let dates = [d("2026-04-04"), d("2026-06-30")]
        let p = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: dates, now: d("2026-07-15"), calendar: cal))
        XCTAssertEqual(p.start.driftDays, 3)
        XCTAssertFalse(p.start.isAdrift, "three days is inside tolerance")
    }

    /// The defect that motivates offering calendar ranges at all: a rolling
    /// window generated mid-July does not start where the quarter started.
    func testRollingAndCalendarResolveToDifferentStarts() throws {
        let dates = (1...200).map { cal.date(byAdding: .day, value: -$0, to: d("2026-07-15"))! }
        let rolling = try XCTUnwrap(ReportPeriod.resolve(
            kind: .rolling(weeks: 12), availableDates: dates, now: d("2026-07-15"), calendar: cal))
        let quarter = try XCTUnwrap(ReportPeriod.resolve(
            kind: .lastFullQuarter, availableDates: dates, now: d("2026-07-15"), calendar: cal))
        XCTAssertNotEqual(rolling.start.resolved, quarter.start.resolved)
        XCTAssertEqual(quarter.requestedStart, d("2026-04-01"))
        XCTAssertEqual(quarter.requestedEnd, d("2026-06-30"))
    }

    /// No snapshot at or before the start: the period begins where data begins.
    func testStartFallsForwardWhenNoEarlierSnapshotExists() throws {
        let dates = [d("2026-05-10"), d("2026-06-30")]
        let p = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: dates, now: d("2026-07-15"), calendar: cal))
        XCTAssertEqual(p.start.resolved, d("2026-05-10"))
        XCTAssertTrue(p.start.isAdrift)
    }

    func testNoSnapshotsInRangeYieldsNil() {
        XCTAssertNil(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: [d("2025-01-01")], now: d("2026-07-15"), calendar: cal))
    }

    func testEmptyAvailableDatesYieldsNil() {
        XCTAssertNil(ReportPeriod.resolve(
            kind: .rolling(weeks: 12), availableDates: [], now: d("2026-07-15"), calendar: cal))
    }

    func testLastFullMonthResolvesToTheWholePriorMonth() throws {
        let dates = [d("2026-06-01"), d("2026-06-30")]
        let p = try XCTUnwrap(ReportPeriod.resolve(
            kind: .lastFullMonth, availableDates: dates, now: d("2026-07-15"), calendar: cal))
        XCTAssertEqual(p.requestedStart, d("2026-06-01"))
        XCTAssertEqual(p.requestedEnd, d("2026-06-30"))
    }
}
