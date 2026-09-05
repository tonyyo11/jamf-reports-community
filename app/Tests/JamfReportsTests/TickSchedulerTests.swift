import XCTest
@testable import JamfReports

final class TickSchedulerTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func schedule(
        _ name: String, cadence: String, mode: Schedule.RunMode, enabled: Bool = true
    ) -> Schedule {
        Schedule(
            name: name, profile: "alpha", schedule: cadence, cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: enabled,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.alpha.\(name)"
        )
    }

    func testCalendarIntervalsCoverEveryCadenceForm() throws {
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Daily 06:20"),
                       [["Hour": 6, "Minute": 20]])
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Mon 07:00"),
                       [["Weekday": 1, "Hour": 7, "Minute": 0]])
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Weekdays 09:00").count, 5)
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Day 15 06:20"),
                       [["Day": 15, "Hour": 6, "Minute": 20]])
        XCTAssertThrowsError(try LaunchAgentWriter.calendarIntervals(for: "whenever"))
    }

    func testDueAtOrAfterFireWhenNeverStarted() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let due = TickScheduler.due(
            schedules: [s], lastStarted: [:], runNowLabels: [], now: date(2026, 9, 7, 6, 21))
        XCTAssertEqual(due.map(\.name), ["collect"])
    }

    func testNotDueWhenLastStartAlreadyCoversTheLatestFire() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // 06:19 today: the latest fire is YESTERDAY 06:20, already covered.
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 9, 6, 6, 21)], runNowLabels: [],
            now: date(2026, 9, 7, 6, 19)).isEmpty)
        // Started after this morning's fire → nothing to do.
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 9, 7, 6, 22)], runNowLabels: [],
            now: date(2026, 9, 7, 6, 25)).isEmpty)
    }

    func testMissedFireFiresOnceNotPerMissedDay() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // Last started a week ago; six fires were missed. One run, then quiet.
        let first = TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 8, 31, 6, 21)], runNowLabels: [],
            now: date(2026, 9, 7, 14, 0))
        XCTAssertEqual(first.count, 1)
        let second = TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 9, 7, 14, 0)], runNowLabels: [],
            now: date(2026, 9, 7, 14, 5))
        XCTAssertTrue(second.isEmpty)
    }

    func testNonCatchUpModesRunOnlyWithinFifteenMinutesOfTheFire() {
        let backup = schedule("backup", cadence: "Mon 07:00", mode: .backup)
        let generate = schedule("gen", cadence: "Daily 06:20", mode: .jamfCLIOnly)
        // 2026-09-07 is a Monday.
        XCTAssertEqual(TickScheduler.due(
            schedules: [backup, generate], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 7, 10)).map(\.name), ["backup"])
        XCTAssertTrue(TickScheduler.due(
            schedules: [backup, generate], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 7, 16)).isEmpty)
    }

    /// A long collect blocks every wake behind it. Measuring the non-catch-up
    /// window from the wake that finally gets in would silently drop the fires
    /// that came due while it ran — so it is measured from the first refusal.
    func testBlockedAnchorKeepsANonCatchUpFireAliveAcrossALongRun() {
        let backup = schedule("backup", cadence: "Mon 07:00", mode: .backup)  // 09-07 is a Monday
        let now = date(2026, 9, 7, 7, 40)
        XCTAssertEqual(TickScheduler.due(
            schedules: [backup], lastStarted: [:], runNowLabels: [], now: now,
            nonCatchUpAnchor: date(2026, 9, 7, 6, 58)).map(\.name), ["backup"])
        // Same wake with no blocked stamp: 40 minutes late, correctly skipped.
        XCTAssertTrue(TickScheduler.due(
            schedules: [backup], lastStarted: [:], runNowLabels: [], now: now,
            nonCatchUpAnchor: now).isEmpty)
    }

    func testDisabledNeverDueAndRunNowAlwaysDue() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly, enabled: false)
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], lastStarted: [:], runNowLabels: [], now: date(2026, 9, 7, 6, 21)
        ).isEmpty)
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], lastStarted: [:], runNowLabels: [s.launchAgentLabel!],
            now: date(2026, 9, 7, 3, 0)).map(\.name), ["collect"])
    }

    func testUnparseableCadenceIsSkippedNotFatal() {
        let bad = schedule("bad", cadence: "whenever", mode: .snapshotOnly)
        let good = schedule("good", cadence: "Daily 06:20", mode: .snapshotOnly)
        XCTAssertEqual(TickScheduler.due(
            schedules: [bad, good], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 6, 21)).map(\.name), ["good"])
    }

    func testInputOrderIsPreserved() {
        let a = schedule("a", cadence: "Daily 06:00", mode: .snapshotOnly)
        let b = schedule("b", cadence: "Daily 06:10", mode: .snapshotOnly)
        XCTAssertEqual(TickScheduler.due(
            schedules: [b, a], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 6, 30)).map(\.name), ["b", "a"])
    }

    func testTickStateRoundTripsAndLoadsEmptyWhenMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-state-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(TickState.load(url: url).lastStarted, [:])
        var state = TickState()
        state.lastStarted["x"] = date(2026, 9, 7, 6, 21)
        try state.save(url: url)
        XCTAssertEqual(TickState.load(url: url).lastStarted["x"], date(2026, 9, 7, 6, 21))
    }
}
