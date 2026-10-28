import XCTest
@testable import JamfReports

/// A multi-profile schedule's same-day retry re-collects only the profiles whose last outcome
/// says a retry could fetch something; the schedule's own stamps stay per label.
final class TickProfileOutcomeTests: XCTestCase {
    private let label = "com.github.tonyyo11.jamf-reports-community.multi.fleet"
    private let started = Date.testNoon.addingTimeInterval(-6 * 3600)

    private var schedule: Schedule {
        Schedule(
            name: "fleet", profile: "", schedule: "Daily 06:00", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label)
    }

    private func outcome(
        _ profile: String, exit: Int32 = 0, incomplete: Bool = false, helps: Bool = false
    ) -> ProfileOutcome {
        ProfileOutcome(
            profile: profile, exitCode: exit, incomplete: incomplete, retryCouldHelp: helps,
            started: started, finished: started.addingTimeInterval(60))
    }

    private func run(_ outcomes: [ProfileOutcome]) -> ScheduleRunOutcome {
        ScheduleRunOutcome(over: outcomes, ran: outcomes)
    }

    /// One `TickLoop.runDue` over `due` from `state`; returns the state it ends on.
    private func runDue(
        _ due: TickScheduler.DueRun, state: TickState, result: ScheduleRunOutcome
    ) async -> TickState {
        let saved = SavedState(state)
        _ = await TickLoop.runDue(
            [due], state: state, runNowLabels: [], clock: { self.started },
            save: { saved.set($0) }, clearRunNowMarker: { _ in },
            perform: { _ in result }, recordFailure: { _, _ in }, notifyOverdue: {})
        return saved.value
    }

    private func retryDue(_ state: TickState, runNow: Bool = false) -> TickScheduler.DueRun? {
        TickScheduler.due(
            schedules: [schedule], state: state, runNowLabels: runNow ? [label] : [],
            now: started.addingTimeInterval(3600 + 300)).first
    }

    private func firstRun(_ outcomes: [ProfileOutcome]) async -> TickState {
        let due = TickScheduler.DueRun(schedule: schedule, reason: .fire)
        return await runDue(due, state: TickState(), result: run(outcomes))
    }

    func testRetryRunsOnlyTheFailedAndThePartialProfile() async throws {
        let state = await firstRun([
            outcome("alpha", exit: 1, helps: true),
            outcome("beta", incomplete: true, helps: true),
            outcome("gamma"),
        ])
        let due = try XCTUnwrap(retryDue(state))
        XCTAssertEqual(due.reason, .retry)
        XCTAssertEqual(due.skipProfiles, ["gamma"])
        XCTAssertEqual(
            TickScheduler.profilesToRun(["alpha", "beta", "gamma"], skipping: due.skipProfiles),
            ["alpha", "beta"])
    }

    func testAProfileWhoseFailureRepeatsIsLeftOut() async throws {
        let state = await firstRun([
            outcome("alpha", exit: 1, helps: true),
            outcome("beta", exit: 1, helps: false),
            outcome("gamma"),
        ])
        XCTAssertEqual(try XCTUnwrap(retryDue(state)).skipProfiles, ["beta", "gamma"])
    }

    func testARetryOfSomeProfilesStillAnswersForAll() async throws {
        let first = await firstRun([
            outcome("alpha", exit: 1, helps: true), outcome("beta", exit: 1, helps: false),
        ])
        let retry = try XCTUnwrap(retryDue(first))
        let after = await runDue(retry, state: first, result: run([outcome("alpha")]))
        XCTAssertNil(after.lastSucceeded[label], "beta's repeating failure keeps the fire open")
        XCTAssertEqual(after.profileOutcomes[label]?.map(\.profile).sorted(), ["alpha", "beta"])
        XCTAssertEqual(after.retryCount[label], 1)
    }

    func testARetryThatClearsTheLastNeedingProfileEndsTheRetries() async throws {
        let first = await firstRun([outcome("alpha", exit: 1, helps: true), outcome("beta")])
        let retry = try XCTUnwrap(retryDue(first))
        let after = await runDue(retry, state: first, result: run([outcome("alpha")]))
        XCTAssertEqual(after.lastSucceeded[label], started)
    }

    func testRunNowAndAFireRunEveryProfile() async throws {
        let state = await firstRun([outcome("alpha", exit: 1, helps: true), outcome("beta")])
        XCTAssertEqual(try XCTUnwrap(retryDue(state, runNow: true)).skipProfiles, [])
        var next = state
        next.noteStarted(label, at: started.addingTimeInterval(86_400), reason: .fire)
        XCTAssertNil(next.profileOutcomes[label], "a new fire does not inherit yesterday's")
    }

    func testARunNowRecordsNoOutcomes() async {
        var state = TickState()
        XCTAssertFalse(state.noteProfileOutcomes(label, [outcome("alpha")], reason: .runNow))
        XCTAssertTrue(state.profileOutcomes.isEmpty)
    }

    func testWithNoRecordedOutcomesARetryRunsEveryProfile() throws {
        var state = TickState()
        state.lastStarted[label] = started
        let due = try XCTUnwrap(retryDue(state))
        XCTAssertEqual(due.skipProfiles, [])
        XCTAssertEqual(TickScheduler.profilesToRun(["a", "b"], skipping: []), ["a", "b"])
    }

    func testALeftOutSetThatCoversEveryProfileRunsAllOfThem() {
        XCTAssertEqual(
            TickScheduler.profilesToRun(["a", "b"], skipping: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(
            TickScheduler.profilesToRun(["a", "b", "new"], skipping: ["a", "b"]), ["new"],
            "a profile with no outcome is not left out")
    }

    func testOutcomesRoundTripAndAnOldStateFileDecodesAsToday() throws {
        var state = TickState()
        state.lastStarted[label] = started
        _ = state.noteProfileOutcomes(
            label, [outcome("alpha", exit: 1, helps: true)], reason: .fire)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-outcomes-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try state.save(url: url)
        XCTAssertEqual(
            TickState.load(url: url).profileOutcomes[label], state.profileOutcomes[label])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"retry_could_help\""), text)

        let old = Data(#"{"lastStarted":{"a":"2026-06-15T10:00:00Z"}}"#.utf8)
        try old.write(to: url)
        let loaded = TickState.load(url: url)
        XCTAssertNotNil(loaded.lastStarted["a"])
        XCTAssertTrue(loaded.profileOutcomes.isEmpty)
    }

    func testAnUnreadableOutcomeCostsNoStamps() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-bad-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(#"""
        {"lastStarted":{"a":"2026-06-15T10:00:00Z"},
         "profileOutcomes":{"a":[{"profile":"x","exit":"nope"}]}}
        """#.utf8).write(to: url)
        let loaded = TickState.load(url: url)
        XCTAssertNotNil(loaded.lastStarted["a"])
        XCTAssertTrue(loaded.profileOutcomes.isEmpty)
    }
}

private final class SavedState: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TickState

    init(_ state: TickState) { self.state = state }

    func set(_ new: TickState) { lock.withLock { state = new } }
    var value: TickState { lock.withLock { state } }
}
