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

    private func tickState(
        started: [String: Date] = [:],
        succeeded: [String: Date] = [:],
        retries: [String: Int] = [:]
    ) -> TickState {
        var state = TickState()
        state.lastStarted = started
        state.lastSucceeded = succeeded
        state.retryCount = retries
        return state
    }

    private func tempStateURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-state-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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
            schedules: [s], state: TickState(), runNowLabels: [], now: date(2026, 9, 7, 6, 21))
        XCTAssertEqual(due.map(\.schedule.name), ["collect"])
        XCTAssertEqual(due.map(\.reason), [.fire])
    }

    func testNotDueWhenLastStartAlreadyCoversTheLatestFire() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // 06:19 today: the latest fire is YESTERDAY 06:20, already covered.
        let yesterday = date(2026, 9, 6, 6, 21)
        let covered = tickState(started: [label: yesterday], succeeded: [label: yesterday])
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], state: covered, runNowLabels: [], now: date(2026, 9, 7, 6, 19)).isEmpty)
        // Started after this morning's fire → nothing to do.
        let today = date(2026, 9, 7, 6, 22)
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], state: tickState(started: [label: today], succeeded: [label: today]),
            runNowLabels: [], now: date(2026, 9, 7, 6, 25)).isEmpty)
    }

    func testMissedFireFiresOnceNotPerMissedDay() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // Last started a week ago; six fires were missed. One run, then quiet.
        let first = TickScheduler.due(
            schedules: [s], state: tickState(started: [label: date(2026, 8, 31, 6, 21)]),
            runNowLabels: [], now: date(2026, 9, 7, 14, 0))
        XCTAssertEqual(first.count, 1)
        let ran = date(2026, 9, 7, 14, 0)
        let second = TickScheduler.due(
            schedules: [s], state: tickState(started: [label: ran], succeeded: [label: ran]),
            runNowLabels: [], now: date(2026, 9, 7, 14, 5))
        XCTAssertTrue(second.isEmpty)
    }

    func testNonCatchUpModesRunOnlyWithinFifteenMinutesOfTheFire() {
        let backup = schedule("backup", cadence: "Mon 07:00", mode: .backup)
        let generate = schedule("gen", cadence: "Daily 06:20", mode: .jamfCLIOnly)
        // 2026-09-07 is a Monday.
        XCTAssertEqual(TickScheduler.due(
            schedules: [backup, generate], state: TickState(), runNowLabels: [],
            now: date(2026, 9, 7, 7, 10)).map(\.schedule.name), ["backup"])
        XCTAssertTrue(TickScheduler.due(
            schedules: [backup, generate], state: TickState(), runNowLabels: [],
            now: date(2026, 9, 7, 7, 16)).isEmpty)
    }

    /// A long collect blocks every wake behind it. Measuring the non-catch-up
    /// window from the wake that finally gets in would silently drop the fires
    /// that came due while it ran — so it is measured from the first refusal.
    func testBlockedAnchorKeepsANonCatchUpFireAliveAcrossALongRun() {
        let backup = schedule("backup", cadence: "Mon 07:00", mode: .backup)  // 09-07 is a Monday
        let now = date(2026, 9, 7, 7, 40)
        XCTAssertEqual(TickScheduler.due(
            schedules: [backup], state: TickState(), runNowLabels: [], now: now,
            nonCatchUpAnchor: date(2026, 9, 7, 6, 58)).map(\.schedule.name), ["backup"])
        // Same wake with no blocked stamp: 40 minutes late, correctly skipped.
        XCTAssertTrue(TickScheduler.due(
            schedules: [backup], state: TickState(), runNowLabels: [], now: now,
            nonCatchUpAnchor: now).isEmpty)
    }

    func testDisabledNeverDueAndRunNowAlwaysDue() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly, enabled: false)
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], state: TickState(), runNowLabels: [], now: date(2026, 9, 7, 6, 21)
        ).isEmpty)
        let runNow = TickScheduler.due(
            schedules: [s], state: TickState(), runNowLabels: [s.launchAgentLabel!],
            now: date(2026, 9, 7, 3, 0))
        XCTAssertEqual(runNow.map(\.schedule.name), ["collect"])
        XCTAssertEqual(runNow.map(\.reason), [.runNow])
    }

    func testUnparseableCadenceIsSkippedNotFatal() {
        let bad = schedule("bad", cadence: "whenever", mode: .snapshotOnly)
        let good = schedule("good", cadence: "Daily 06:20", mode: .snapshotOnly)
        XCTAssertEqual(TickScheduler.due(
            schedules: [bad, good], state: TickState(), runNowLabels: [],
            now: date(2026, 9, 7, 6, 21)).map(\.schedule.name), ["good"])
    }

    func testInputOrderIsPreserved() {
        let a = schedule("a", cadence: "Daily 06:00", mode: .snapshotOnly)
        let b = schedule("b", cadence: "Daily 06:10", mode: .snapshotOnly)
        XCTAssertEqual(TickScheduler.due(
            schedules: [b, a], state: TickState(), runNowLabels: [],
            now: date(2026, 9, 7, 6, 30)).map(\.schedule.name), ["b", "a"])
    }

    // MARK: - Same-day retry

    /// A collect that failed at its 06:00 fire is retried an hour later — not
    /// on the next wake, and not the next day.
    func testFailedRunIsRetriedAfterAnHourNotBefore() {
        let s = schedule("collect", cadence: "Daily 06:00", mode: .snapshotOnly)
        let failed = tickState(started: [s.launchAgentLabel!: date(2026, 9, 7, 6, 0)])
        for minute in [30, 59] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [s], state: failed, runNowLabels: [],
                now: date(2026, 9, 7, 6, minute)).isEmpty, "not due at 06:\(minute)")
        }
        for (hour, minute) in [(7, 0), (7, 5)] {
            let retry = TickScheduler.due(
                schedules: [s], state: failed, runNowLabels: [],
                now: date(2026, 9, 7, hour, minute))
            XCTAssertEqual(retry.map(\.schedule.name), ["collect"])
            XCTAssertEqual(retry.map(\.reason), [.retry])
        }
    }

    func testLaterRetriesWaitTwoThenFourHours() {
        let s = schedule("collect", cadence: "Daily 06:00", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // Retry 1 started 07:05 and failed: retry 2 waits two hours.
        let afterFirst = tickState(started: [label: date(2026, 9, 7, 7, 5)], retries: [label: 1])
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], state: afterFirst, runNowLabels: [],
            now: date(2026, 9, 7, 8, 30)).isEmpty)
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], state: afterFirst, runNowLabels: [],
            now: date(2026, 9, 7, 9, 6)).map(\.reason), [.retry])
        // Retry 2 started 09:06 and failed: retry 3 waits four hours.
        let afterSecond = tickState(started: [label: date(2026, 9, 7, 9, 6)], retries: [label: 2])
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], state: afterSecond, runNowLabels: [],
            now: date(2026, 9, 7, 12, 30)).isEmpty)
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], state: afterSecond, runNowLabels: [],
            now: date(2026, 9, 7, 13, 7)).map(\.reason), [.retry])
    }

    func testNothingIsDueAfterThreeRetriesUntilTheNextFire() {
        let s = schedule("collect", cadence: "Daily 06:00", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        let exhausted = tickState(started: [label: date(2026, 9, 7, 13, 7)], retries: [label: 3])
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], state: exhausted, runNowLabels: [],
            now: date(2026, 9, 7, 23, 0)).isEmpty)
        // The next calendar fire is a fresh run, not a retry.
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], state: exhausted, runNowLabels: [],
            now: date(2026, 9, 8, 6, 1)).map(\.reason), [.fire])
    }

    func testSuccessSinceTheFireIsNeverRetried() {
        let s = schedule("collect", cadence: "Daily 06:00", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        let fire = date(2026, 9, 7, 6, 0)
        let ok = tickState(started: [label: fire], succeeded: [label: fire])
        for hour in [7, 12, 23] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [s], state: ok, runNowLabels: [],
                now: date(2026, 9, 7, hour, 5)).isEmpty, "no retry at \(hour):05")
        }
        // Yesterday's success does not cover today's failed start.
        let stale = tickState(
            started: [label: fire], succeeded: [label: date(2026, 9, 6, 6, 0)])
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], state: stale, runNowLabels: [],
            now: date(2026, 9, 7, 7, 5)).map(\.reason), [.retry])
    }

    func testNewFireResetsTheRetryCount() {
        let s = schedule("collect", cadence: "Daily 06:00", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        var state = tickState(started: [label: date(2026, 9, 6, 13, 7)], retries: [label: 3])
        let fresh = TickScheduler.due(
            schedules: [s], state: state, runNowLabels: [], now: date(2026, 9, 7, 6, 2))
        XCTAssertEqual(fresh.map(\.reason), [.fire])
        state.noteStarted(label, at: date(2026, 9, 7, 6, 2), reason: .fire)
        XCTAssertEqual(state.retryCount[label], 0)
        // …so today's failed run gets retries of its own.
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], state: state, runNowLabels: [],
            now: date(2026, 9, 7, 7, 3)).map(\.reason), [.retry])
    }

    func testGenerateFromCacheAndBackupAreNeverRetried() {
        let generate = schedule("gen", cadence: "Daily 06:00", mode: .jamfCLIOnly)
        let backup = schedule("backup", cadence: "Mon 07:00", mode: .backup)  // 09-07 is a Monday
        let failed = tickState(started: [
            generate.launchAgentLabel!: date(2026, 9, 7, 6, 0),
            backup.launchAgentLabel!: date(2026, 9, 7, 7, 0),
        ])
        for hour in [8, 12, 23] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [generate, backup], state: failed, runNowLabels: [],
                now: date(2026, 9, 7, hour, 0)).isEmpty, "no retry at \(hour):00")
        }
    }

    // MARK: - TickState bookkeeping

    func testNoteStartedAndSucceededKeepTheRetryCountHonest() {
        var state = TickState()
        let fire = date(2026, 9, 7, 6, 0)
        state.noteStarted("x", at: fire, reason: .fire)
        XCTAssertEqual(state.lastStarted["x"], fire)
        XCTAssertEqual(state.retryCount["x"], 0)
        state.noteStarted("x", at: date(2026, 9, 7, 7, 5), reason: .retry)
        state.noteStarted("x", at: date(2026, 9, 7, 9, 6), reason: .retry)
        XCTAssertEqual(state.retryCount["x"], 2)
        XCTAssertEqual(state.lastStarted["x"], date(2026, 9, 7, 9, 6))
        // Run now belongs to no fire: it neither resets nor advances the count.
        let runNow = date(2026, 9, 7, 9, 30)
        state.noteStarted("x", at: runNow, reason: .runNow)
        XCTAssertEqual(state.retryCount["x"], 2)
        XCTAssertNil(state.lastSucceeded["x"])
        state.noteSucceeded("x", startedAt: runNow)
        XCTAssertEqual(state.lastSucceeded["x"], runNow)
        XCTAssertEqual(state.retryCount["x"], 0)
    }

    func testScheduleRunOutcomeSucceedsOnlyWhenExitZeroAndComplete() {
        XCTAssertTrue(ScheduleRunOutcome(exitCode: 0, incomplete: false).succeeded)
        XCTAssertFalse(ScheduleRunOutcome(exitCode: 0, incomplete: true).succeeded)
        XCTAssertFalse(ScheduleRunOutcome(exitCode: 1, incomplete: false).succeeded)
        XCTAssertFalse(ScheduleRunOutcome(exitCode: 1, incomplete: true).succeeded)
    }

    func testTickStateRoundTripsAndLoadsEmptyWhenMissing() throws {
        let url = tempStateURL()
        XCTAssertEqual(TickState.load(url: url).lastStarted, [:])
        var state = TickState()
        state.lastStarted["x"] = date(2026, 9, 7, 6, 21)
        state.lastSucceeded["x"] = date(2026, 9, 7, 6, 21)
        state.retryCount["x"] = 2
        try state.save(url: url)
        let loaded = TickState.load(url: url)
        XCTAssertEqual(loaded.lastStarted["x"], date(2026, 9, 7, 6, 21))
        XCTAssertEqual(loaded.lastSucceeded["x"], date(2026, 9, 7, 6, 21))
        XCTAssertEqual(loaded.retryCount["x"], 2)
    }

    /// A pre-retry state file carries only `lastStarted`; losing it would
    /// re-run every schedule on the first wake after the upgrade.
    func testTickStateWithoutRetryKeysStillDecodes() throws {
        let url = tempStateURL()
        let stamp = ISO8601DateFormatter().string(from: date(2026, 9, 7, 6, 21))
        try Data(#"{"lastStarted":{"x":"\#(stamp)"}}"#.utf8).write(to: url)
        let loaded = TickState.load(url: url)
        XCTAssertEqual(loaded.lastStarted["x"], date(2026, 9, 7, 6, 21))
        XCTAssertTrue(loaded.lastSucceeded.isEmpty)
        XCTAssertTrue(loaded.retryCount.isEmpty)
    }
}
