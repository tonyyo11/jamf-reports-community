import Foundation
import XCTest
@testable import JamfReports

/// Split-day bookkeeping edges the 2.13 mutation sweep left unpinned: what each start stamps,
/// how a day's runs merge, and which split days the scheduler may continue.
final class TickSchedulerSplitBoundaryTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }
    private let label = "com.github.tonyyo11.jamf-reports-community.freshness"

    private func schedule(mode: Schedule.RunMode = .snapshotOnly, enabled: Bool = true) -> Schedule {
        Schedule(
            name: "freshness", profile: "alpha", schedule: "Daily 06:00", cadence: "daily",
            mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: enabled, launchAgentLabel: label, multiTarget: nil)
    }

    private func stopped(planned: [String], left: [String]) -> ScheduleRunOutcome {
        ScheduleRunOutcome(
            exitCode: 0, incomplete: false, retryCouldHelp: true, stop: .budget,
            planned: planned, left: left, failureRetryCouldHelp: false)
    }

    private func openDay(on date: Date) -> SplitDay {
        SplitDay(day: Calendar.current.startOfDay(for: date),
                 profiles: ["": .init(planned: ["a"], left: ["a"], lastFinished: date)],
                 failed: false)
    }

    // MARK: - Starts

    func testAFireOrCatchUpClosesTheSplitDay() {
        for reason in [TickScheduler.Reason.fire, .catchUp] {
            var state = TickState()
            state.splitDay[label] = openDay(on: at(6))
            state.noteStarted(label, at: at(7), reason: reason)
            XCTAssertNil(state.splitDay[label], "\(reason)")
        }
    }

    func testAContinuationStampsItsStartAndSpendsNoRetry() {
        var state = TickState()
        state.retryCount[label] = 2
        state.noteStarted(label, at: at(8), reason: .continuation)
        XCTAssertEqual(state.lastStarted[label], at(8))
        XCTAssertEqual(state.retryCount[label], 2)
    }

    func testADayWithNoProfilesIsNotOpen() {
        XCTAssertFalse(SplitDay(day: day, profiles: [:], failed: false).isOpen(on: at(9)))
    }

    // MARK: - Merging a day's runs

    func testARunNowRecordsNothing() {
        var state = TickState()
        XCTAssertFalse(state.noteSplitDay(
            label, outcome: stopped(planned: ["a"], left: ["a"]), failed: false, reason: .runNow,
            startedAt: at(6), finishedAt: at(7)))
        XCTAssertNil(state.splitDay[label])
    }

    func testPlannedSourcesAreTheDaysUnionAndAnotherDayStartsOver() {
        var state = TickState()
        _ = state.noteSplitDay(label, outcome: stopped(planned: ["a", "b"], left: ["b"]),
                               failed: false, reason: .fire, startedAt: at(6), finishedAt: at(7))
        _ = state.noteSplitDay(label, outcome: stopped(planned: ["b", "c"], left: ["c"]),
                               failed: false, reason: .continuation, startedAt: at(8),
                               finishedAt: at(9))
        XCTAssertEqual(state.splitDay[label]?.profiles[""]?.planned, ["a", "b", "c"])

        _ = state.noteSplitDay(label, outcome: stopped(planned: ["d"], left: ["d"]),
                               failed: false, reason: .fire, startedAt: at(30), finishedAt: at(31))
        XCTAssertEqual(state.splitDay[label]?.profiles[""]?.planned, ["d"],
                       "a run started the next day does not keep yesterday's plan")
    }

    func testTheSameOutcomeAgainIsNoChange() {
        var state = TickState()
        let outcome = stopped(planned: ["a"], left: ["a"])
        XCTAssertTrue(state.noteSplitDay(label, outcome: outcome, failed: false, reason: .fire,
                                         startedAt: at(6), finishedAt: at(7)))
        XCTAssertFalse(state.noteSplitDay(label, outcome: outcome, failed: false,
                                          reason: .continuation, startedAt: at(6),
                                          finishedAt: at(7)))
    }

    // MARK: - Which split days continue

    private func stateWithSplit(on date: Date) -> TickState {
        var state = TickState()
        state.lastStarted[label] = at(6)
        state.retryCount[label] = 0
        state.splitDay[label] = openDay(on: date)
        return state
    }

    func testOnlyAnEnabledCollectingScheduleContinuesTodaysSplitDay() {
        let state = stateWithSplit(on: at(6))
        XCTAssertEqual(TickScheduler.due(schedules: [schedule()], state: state, runNowLabels: [],
                                         now: at(9)).map(\.reason), [.continuation])
        XCTAssertTrue(TickScheduler.due(schedules: [schedule(enabled: false)], state: state,
                                        runNowLabels: [], now: at(9)).isEmpty)
        XCTAssertTrue(TickScheduler.due(schedules: [schedule(mode: .backup)], state: state,
                                        runNowLabels: [], now: at(9)).isEmpty)
    }

    func testYesterdaysSplitDayNeitherContinuesNorBlocksARetry() {
        var state = stateWithSplit(on: at(-18))
        XCTAssertEqual(TickScheduler.due(schedules: [schedule()], state: state, runNowLabels: [],
                                         now: at(7.5)).map(\.reason), [.retry],
                       "today's 06:00 run failed and has no split day of its own")
        state.lastStarted[label] = at(6)
        state.lastSucceeded[label] = at(6)
        XCTAssertTrue(TickScheduler.due(schedules: [schedule()], state: state, runNowLabels: [],
                                        now: at(9)).isEmpty)
    }
}
