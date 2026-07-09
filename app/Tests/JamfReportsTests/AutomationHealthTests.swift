import XCTest
@testable import JamfReports

/// Pure tests for the scheduled-run dead-man switch (2.6 trust trio #2):
/// `LaunchAgentService.lastScheduledFireDate` (past-fire resolution) and
/// `AutomationHealth.evaluate` (overdue / failing model). No launchctl, no real
/// LaunchAgents dir, no repo fixtures — all inputs are injected.
final class AutomationHealthTests: XCTestCase {

    // MARK: - Fixed clock

    /// A stable reference instant: 2026-07-06 14:30:00 local.
    private func referenceNow() -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 6
        comps.hour = 14
        comps.minute = 30
        comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    private func date(
        year: Int, month: Int, day: Int, hour: Int, minute: Int
    ) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    // MARK: - lastScheduledFireDate

    func testDailyEntryResolvesTodayWhenFireAlreadyPassed() {
        let now = referenceNow()  // 14:30
        // Daily at 06:00 — today's 06:00 is the most recent past fire.
        let raw: [String: Int] = ["Hour": 6, "Minute": 0]
        let fire = LaunchAgentService.lastScheduledFireDate(from: raw, before: now)
        XCTAssertNotNil(fire)
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        XCTAssertEqual(fire, expected)
    }

    func testDailyEntryResolvesYesterdayWhenFireIsLaterToday() {
        let now = referenceNow()  // 14:30
        // Daily at 22:00 — today's 22:00 hasn't happened yet, so the most recent
        // past fire is YESTERDAY at 22:00.
        let raw: [String: Int] = ["Hour": 22, "Minute": 0]
        let fire = LaunchAgentService.lastScheduledFireDate(from: raw, before: now)
        XCTAssertNotNil(fire)
        let expected = date(year: 2026, month: 7, day: 5, hour: 22, minute: 0)
        XCTAssertEqual(fire, expected)
    }

    func testFireExactlyAtNowCountsAsAlreadyFired() {
        let now = referenceNow()  // 14:30
        let raw: [String: Int] = ["Hour": 14, "Minute": 30]
        let fire = LaunchAgentService.lastScheduledFireDate(from: raw, before: now)
        // <= now, so today's 14:30 == now is the resolved past fire.
        XCTAssertEqual(fire, now)
    }

    func testWeeklyEntryResolvesMostRecentMatchingWeekday() {
        let now = referenceNow()  // 2026-07-06 is a Monday, 14:30
        // launchd Weekday 1 = Monday. 06:00 Monday already passed today.
        let raw: [String: Int] = ["Weekday": 1, "Hour": 6, "Minute": 0]
        let fire = LaunchAgentService.lastScheduledFireDate(from: raw, before: now)
        XCTAssertNotNil(fire)
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        XCTAssertEqual(fire, expected)
    }

    func testWeeklyEntryResolvesPriorWeekWhenNotYetDueThisWeek() {
        let now = referenceNow()  // Monday 14:30
        // Weekday 3 = Wednesday. This week's Wednesday is in the future, so the
        // most recent past Wednesday fire is LAST week (2026-07-01).
        let raw: [String: Int] = ["Weekday": 3, "Hour": 6, "Minute": 0]
        let fire = LaunchAgentService.lastScheduledFireDate(from: raw, before: now)
        XCTAssertNotNil(fire)
        let expected = date(year: 2026, month: 7, day: 1, hour: 6, minute: 0)
        XCTAssertEqual(fire, expected)
    }

    func testArrayOfDictsPicksLatestPastFireAcrossEntries() {
        let now = referenceNow()  // 14:30
        // Two daily fires: 06:00 and 12:00. Both passed today; the latest is 12:00.
        let raw: [[String: Int]] = [
            ["Hour": 6, "Minute": 0],
            ["Hour": 12, "Minute": 0],
        ]
        let fire = LaunchAgentService.lastScheduledFireDate(from: raw, before: now)
        XCTAssertNotNil(fire)
        let expected = date(year: 2026, month: 7, day: 6, hour: 12, minute: 0)
        XCTAssertEqual(fire, expected)
    }

    func testNilRawYieldsNil() {
        XCTAssertNil(LaunchAgentService.lastScheduledFireDate(from: nil, before: referenceNow()))
    }

    func testGarbageRawYieldsNil() {
        let garbage: Any = "every so often"
        XCTAssertNil(LaunchAgentService.lastScheduledFireDate(from: garbage, before: referenceNow()))
    }

    /// S1 (security review): the outer loop over calendar entries is capped at
    /// 64 so a plist with a pathologically large `StartCalendarInterval` array
    /// can't force unbounded `Calendar.nextDate` work. A 200-entry array must
    /// return promptly and its result must equal running only the first 64.
    func testUncappedEntryArrayIsBoundedAndMatchesPrefix() {
        let now = referenceNow()  // 14:30
        // 200 entries, all daily fires spaced one minute apart starting at
        // 00:00 — every one has already fired today, so the winner is
        // whichever entry has the LATEST hour/minute among those considered.
        let full: [[String: Int]] = (0..<200).map { i in
            ["Hour": i / 60, "Minute": i % 60]
        }
        let capped = Array(full.prefix(64))

        let fireFull = LaunchAgentService.lastScheduledFireDate(from: full, before: now)
        let fireCapped = LaunchAgentService.lastScheduledFireDate(from: capped, before: now)

        XCTAssertNotNil(fireFull)
        XCTAssertEqual(fireFull, fireCapped, "the 200-entry result must equal the 64-entry-prefix result")
    }

    // MARK: - AutomationHealth.evaluate

    private func input(
        label: String = "com.github.tonyyo11.jamf-reports-community.prod.freshness",
        displayName: String = "Freshness",
        enabled: Bool = true,
        expectedFire: Date?,
        lastRunFinishedAt: Date?,
        lastRunSuccess: Bool?
    ) -> LaunchAgentService.ScheduleHealthInput {
        LaunchAgentService.ScheduleHealthInput(
            label: label,
            displayName: displayName,
            enabled: enabled,
            expectedFire: expectedFire,
            lastRunFinishedAt: lastRunFinishedAt,
            lastRunSuccess: lastRunSuccess
        )
    }

    func testFiredAndRecordedProducesNoIssue() {
        let now = referenceNow()
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        // A run finished after the expected fire and succeeded.
        let recorded = date(year: 2026, month: 7, day: 6, hour: 6, minute: 5)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: recorded, lastRunSuccess: true)],
            now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testExpectedFirePassedGraceWithNoArtifactIsOverdue() {
        let now = referenceNow()  // 14:30
        // Expected at 06:00, well past the 60-min grace, and no run ever recorded.
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: nil, lastRunSuccess: nil)],
            now: now
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .overdue)
        XCTAssertEqual(issues.first?.expectedFire, expected)
    }

    func testArtifactAfterExpectedFireIsHealthy() {
        let now = referenceNow()
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        // A run finished 2 minutes after the expected fire → the cycle is covered.
        let recorded = date(year: 2026, month: 7, day: 6, hour: 6, minute: 2)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: recorded, lastRunSuccess: true)],
            now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testArtifactBeforeExpectedFireStaysOverdue() {
        let now = referenceNow()
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        // The only recorded run is from YESTERDAY — it does not cover today's
        // fire, so today's missed cycle is still overdue.
        let recorded = date(year: 2026, month: 7, day: 5, hour: 6, minute: 5)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: recorded, lastRunSuccess: true)],
            now: now
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .overdue)
        XCTAssertEqual(issues.first?.lastRunFinishedAt, recorded)
    }

    func testArtifactSuccessFalseIsFailing() {
        let now = referenceNow()
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        // Ran on time but the run failed.
        let recorded = date(year: 2026, month: 7, day: 6, hour: 6, minute: 5)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: recorded, lastRunSuccess: false)],
            now: now
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .failing)
    }

    func testDisabledScheduleNeverOverdue() {
        let now = referenceNow()
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        let issues = AutomationHealth.evaluate(
            inputs: [input(
                enabled: false, expectedFire: expected,
                lastRunFinishedAt: nil, lastRunSuccess: false
            )],
            now: now
        )
        // Disabled schedules produce no overdue AND no failing issue.
        XCTAssertTrue(issues.isEmpty)
    }

    func testWithinGraceIsNotYetOverdue() {
        let now = referenceNow()  // 14:30
        // Expected at 14:00 — only 30 min ago, inside the 60-min grace.
        let expected = date(year: 2026, month: 7, day: 6, hour: 14, minute: 0)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: nil, lastRunSuccess: nil)],
            now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    /// Mutation-sweep survivor s5m3: pins the grace BOUNDARY — a schedule whose
    /// expected fire is exactly `graceSeconds` ago is already overdue (`>=`,
    /// not `>`). One second inside the window is not.
    func testOverdueFiresAtExactGraceBoundary() {
        let now = referenceNow()
        let atBoundary = now.addingTimeInterval(-AutomationHealth.graceSeconds)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: atBoundary, lastRunFinishedAt: nil, lastRunSuccess: nil)],
            now: now
        )
        XCTAssertEqual(issues.first?.kind, .overdue,
                       "expected-fire exactly graceSeconds ago must already read overdue")

        let insideWindow = now.addingTimeInterval(-AutomationHealth.graceSeconds + 1)
        let none = AutomationHealth.evaluate(
            inputs: [input(expectedFire: insideWindow, lastRunFinishedAt: nil, lastRunSuccess: nil)],
            now: now
        )
        XCTAssertTrue(none.isEmpty, "one second inside the grace window is not overdue")
    }

    func testOverdueTakesPrecedenceOverFailing() {
        let now = referenceNow()
        let expected = date(year: 2026, month: 7, day: 6, hour: 6, minute: 0)
        // Last recorded run failed AND is from before today's expected fire, so
        // today's cycle is both missed and the last artifact is a failure —
        // overdue wins (the more urgent "nothing ran today" state).
        let recorded = date(year: 2026, month: 7, day: 5, hour: 6, minute: 5)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: expected, lastRunFinishedAt: recorded, lastRunSuccess: false)],
            now: now
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .overdue)
    }

    func testNilExpectedFireWithFailingArtifactIsFailing() {
        let now = referenceNow()
        // Manual/unparseable interval (no expected fire) but the last run failed.
        let recorded = date(year: 2026, month: 7, day: 6, hour: 6, minute: 5)
        let issues = AutomationHealth.evaluate(
            inputs: [input(expectedFire: nil, lastRunFinishedAt: recorded, lastRunSuccess: false)],
            now: now
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .failing)
    }
}
