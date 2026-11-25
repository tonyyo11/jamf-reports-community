import Foundation
import XCTest
@testable import JamfReports

/// Phase 3 of the split collect: a run that stopped at its budget is continued at the next free
/// wake, never turned into a retry, until its sources land or local midnight.
final class TickSchedulerContinuationTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func schedule(
        _ name: String, cadence: String = "Daily 06:00", multi: Bool = false
    ) -> Schedule {
        Schedule(
            name: name, profile: "alpha", schedule: cadence, cadence: "daily",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.\(name)",
            multiTarget: multi ? MultiTarget(scope: .all) : nil)
    }

    private func stopped(failed: Bool = false) -> ScheduleRunOutcome {
        ScheduleRunOutcome(
            exitCode: 0, incomplete: failed, retryCouldHelp: true, stop: .budget,
            planned: ["overview", "computers", "ea-results"], left: ["computers", "ea-results"],
            failureRetryCouldHelp: failed)
    }

    /// One tick run of `run` from `state` with the given outcome, returning the new state.
    private func tick(
        _ run: TickScheduler.DueRun, from state: TickState, at time: Date,
        outcome: ScheduleRunOutcome
    ) async -> TickState {
        let saved = SavedState()
        _ = await TickLoop.runDue(
            [run], state: state, runNowLabels: [], clock: { time },
            save: { saved.value = $0 }, clearRunNowMarker: { _ in },
            perform: { _ in outcome }, recordFailure: { _, _ in }, notifyOverdue: {})
        return saved.value ?? state
    }

    func testABudgetStopIsContinuedWithoutSpendingARetry() async {
        let freshness = schedule("freshness")
        let label = freshness.launchAgentLabel!
        var state = await tick(
            .init(schedule: freshness, reason: .fire), from: TickState(), at: at(6),
            outcome: stopped())
        XCTAssertEqual(state.retryCount[label], 0)
        XCTAssertNil(state.lastSucceeded[label])
        XCTAssertEqual(state.splitDay[label]?.profiles[""]?.left, ["computers", "ea-results"])

        // Ninety minutes later the retry backoff has passed; it is still a continuation.
        let due = TickScheduler.due(
            schedules: [freshness], state: state, runNowLabels: [], now: at(7.5))
        XCTAssertEqual(due.map(\.reason), [.continuation])

        state = await tick(due[0], from: state, at: at(7.5),
                           outcome: ScheduleRunOutcome(exitCode: 0, incomplete: false))
        XCTAssertNil(state.splitDay[label], "a clean finish closes the split day")
        XCTAssertEqual(state.retryCount[label], 0)
        XCTAssertEqual(state.lastSucceeded[label], at(7.5))
        XCTAssertTrue(TickScheduler.due(
            schedules: [freshness], state: state, runNowLabels: [], now: at(9)).isEmpty)
    }

    func testAContinuationWaitsWhileAnythingElseIsDue() async {
        let freshness = schedule("freshness")
        let backup = schedule("backup", cadence: "Daily 07:00")
        let state = await tick(
            .init(schedule: freshness, reason: .fire), from: TickState(), at: at(6),
            outcome: stopped())
        var withBackupDone = state
        withBackupDone.lastStarted[backup.launchAgentLabel!] = at(7)

        XCTAssertEqual(TickScheduler.due(
            schedules: [freshness, backup], state: state, runNowLabels: [], now: at(7.1))
            .map(\.reason), [.fire], "the backup's fire goes first")
        XCTAssertEqual(TickScheduler.due(
            schedules: [freshness, backup], state: withBackupDone, runNowLabels: [],
            now: at(7.2)).map(\.reason), [.continuation])
    }

    func testAFailureRetriesFirstThenContinuationsResume() async {
        let freshness = schedule("freshness")
        let label = freshness.launchAgentLabel!
        var state = await tick(
            .init(schedule: freshness, reason: .fire), from: TickState(), at: at(6),
            outcome: stopped(failed: true))
        XCTAssertEqual(state.splitDay[label]?.failed, true)
        XCTAssertTrue(TickScheduler.due(
            schedules: [freshness], state: state, runNowLabels: [], now: at(6.5)).isEmpty,
            "no continuation before the first retry")
        XCTAssertEqual(TickScheduler.due(
            schedules: [freshness], state: state, runNowLabels: [], now: at(7)).map(\.reason),
            [.retry])

        state.retryCount[label] = TickScheduler.retryBackoffs.count
        state.lastStarted[label] = at(14)
        XCTAssertEqual(TickScheduler.due(
            schedules: [freshness], state: state, runNowLabels: [], now: at(14.2))
            .map(\.reason), [.continuation], "the backoffs are spent: the rest of the day goes on")
    }

    func testNothingContinuesPastMidnight() async {
        let weekly = schedule("weekly", cadence: "Mon 23:00")
        let state = await tick(
            .init(schedule: weekly, reason: .fire), from: TickState(), at: at(23),
            outcome: stopped())
        XCTAssertTrue(TickScheduler.due(
            schedules: [weekly], state: state, runNowLabels: [], now: at(24.2))
            .filter { $0.reason == .continuation }.isEmpty)
    }

    func testContinueNowRunsAsAContinuationEvenWithAnotherScheduleDue() async {
        let freshness = schedule("freshness")
        let backup = schedule("backup", cadence: "Daily 07:00")
        let state = await tick(
            .init(schedule: freshness, reason: .fire), from: TickState(), at: at(6),
            outcome: stopped())
        let due = TickScheduler.due(
            schedules: [freshness, backup], state: state,
            runNowLabels: [freshness.launchAgentLabel!], now: at(7.1))
        XCTAssertEqual(due.map(\.reason), [.continuation, .fire])
        XCTAssertNotNil(due[0].continuing)
    }

    func testAMultiProfileContinuationRunsOnlyTheProfilesWithSourcesLeft() async {
        let fleet = schedule("fleet", multi: true)
        let label = fleet.launchAgentLabel!
        let a = ProfileOutcome(
            profile: "a", exitCode: 0, incomplete: false, retryCouldHelp: true,
            started: at(6), finished: at(6.75), stop: .budget, failureRetryCouldHelp: false,
            planned: ["x", "y"], left: ["y"])
        let b = ProfileOutcome(
            profile: "b", exitCode: 0, incomplete: false, retryCouldHelp: false,
            started: at(6.75), finished: at(6.8))
        let state = await tick(
            .init(schedule: fleet, reason: .fire), from: TickState(), at: at(6),
            outcome: ScheduleRunOutcome(over: [a, b], ran: [a, b], considered: ["a", "b"]))
        XCTAssertEqual(Set(state.splitDay[label]?.profiles.keys ?? [:].keys), ["a"])
        let due = TickScheduler.due(schedules: [fleet], state: state, runNowLabels: [], now: at(7))
        XCTAssertEqual(due.first?.reason, .continuation)
        XCTAssertEqual(due.first.map { Set($0.continuing?.profiles.keys ?? [:].keys) }, ["a"])
    }

    func testAnUnreadableSplitDayCostsNoOtherStamp() throws {
        let json = """
        {"lastStarted":{"x":"2026-11-25T06:00:00Z"},"splitDay":{"x":{"day":42}}}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-state-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = TickState.load(url: url)
        XCTAssertNotNil(state.lastStarted["x"])
        XCTAssertTrue(state.splitDay.isEmpty)
    }

    func testThePillReadsInProgressUnlessTheRunFailed() {
        let freshness = schedule("freshness")
        let label = freshness.launchAgentLabel!
        let split = [label: SplitDay(
            day: day, profiles: ["": .init(planned: ["x"], left: ["x"], lastFinished: at(6))],
            failed: false)]
        XCTAssertEqual(WorkspaceStore.withLastRuns(
            [freshness], [:], splitDay: split, workspace: "alpha", now: at(7))[0].lastStatus,
            .inProgress)
        var failed = split
        failed[label]?.failed = true
        XCTAssertEqual(WorkspaceStore.withLastRuns(
            [freshness], [:], splitDay: failed, workspace: "alpha", now: at(7))[0].lastStatus,
            .ok)
        XCTAssertEqual(WorkspaceStore.withLastRuns(
            [freshness], [:], splitDay: split, workspace: "alpha", now: at(31))[0].lastStatus,
            .ok, "yesterday's split day is closed")
    }

    func testTheResultLineNamesAContinuation() {
        XCTAssertEqual(tickResultLine(
            label: "x", reason: .continuation,
            outcome: ScheduleRunOutcome(exitCode: 0, incomplete: false), retries: 0),
            "[info] tick: x continuation exit 0")
    }
}

private final class SavedState: @unchecked Sendable {
    var value: TickState?
}
