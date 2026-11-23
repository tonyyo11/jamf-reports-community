import XCTest
@testable import JamfReports

/// The real `runTick` end to end: its lock, schedule store, state file, clock, run and exit are
/// the `TickEnvironment`'s stand-ins, so the wiring a copy of its body could not vouch for runs.
final class RunTickTests: XCTestCase {

    private var root: URL!
    private let label = "\(LaunchAgentWriter.labelPrefix).alpha.daily"
    /// Tuesday 2026-09-08 10:00, after the schedule's 06:00 fire.
    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 8; c.hour = 10
        return Calendar.current.date(from: c)!
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-RunTick-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent("beta"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            TimedProcessBox.reopen()   // the give-up test latches the exit path
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func environment(
        heartbeatLimit: Duration = .seconds(60),
        perform: @escaping @Sendable (TickScheduler.DueRun) async -> ScheduleRunOutcome,
        exit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) throws -> TickEnvironment {
        let schedule = Schedule(
            name: "daily", profile: "alpha", schedule: "Daily 06:00", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label)
        let store = ScheduleStore(url: root.appendingPathComponent("schedules.json"))
        try store.save([try XCTUnwrap(ScheduleRecord(schedule: schedule))])
        let alpha = JamfCLIProfile(name: "alpha", url: "", schedules: 0, status: .ok)
        let beta = JamfCLIProfile(name: "beta", url: "", schedules: 0, status: .ok)
        return TickEnvironment(
            lock: TickLock(url: root.appendingPathComponent(".tick.lock")),
            blockedURL: root.appendingPathComponent(".tick.blocked"),
            stateURL: root.appendingPathComponent("tick-state.json"),
            markerDir: root.appendingPathComponent("run-now"), scheduleStore: store,
            profiles: { [alpha, beta] }, policy: { AutomationPolicy() }, clock: { [now] in now },
            summaryIsMissing: { _, _, _ in false }, perform: perform,
            heartbeatEvery: .milliseconds(10), heartbeatLimit: heartbeatLimit, exit: exit)
    }

    func testADueScheduleRunsAndItsStartIsStamped() async throws {
        let ran = Counter()
        let env = try environment(perform: { run in
            ran.add(run.schedule.launchAgentLabel ?? "")
            return ScheduleRunOutcome(exitCode: 0, incomplete: false)
        })

        let exit = await runTick(arguments: ["--tick"], environment: env)

        XCTAssertEqual(exit, 0)
        XCTAssertEqual(ran.values, [label])
        let state = TickState.load(url: env.stateURL)
        XCTAssertEqual(state.lastStarted[label], now)
        XCTAssertEqual(state.lastSucceeded[label], now)
        XCTAssertEqual(state.lastTick, now)
    }

    /// A policy a suite left in the shared defaults must not run managed schedules in a tick.
    func testATestProcessTickIgnoresAStoredManagedPolicy() {
        let key = AutomationPolicy.storageKey
        let saved = UserDefaults.standard.string(forKey: key)
        var managed = AutomationPolicy()
        managed.isManaged = true
        UserDefaults.standard.set(managed.serialize(), forKey: key)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: key) }

        XCTAssertTrue(AutomationPolicy.current().isManaged)
        XCTAssertFalse(TickEnvironment().policy().isManaged)
        XCTAssertFalse(TickEnvironment.storedPolicy().isManaged)
    }

    func testAHeldLockExitsQueuedKeepsTheMarkerAndRunsNothing() async throws {
        let ran = Counter()
        let env = try environment(perform: { _ in
            ran.add("ran")
            return ScheduleRunOutcome(exitCode: 0, incomplete: false)
        })
        let hold: TickLockHold
        guard case .acquired(let held) = env.lock.claim() else { return XCTFail("no lock") }
        hold = held
        defer { hold.release() }

        let exit = await runTick(arguments: ["--tick", "--now", label], environment: env)

        XCTAssertEqual(exit, TickRunner.queuedExitCode)
        XCTAssertTrue(ran.values.isEmpty)
        XCTAssertEqual(TickRunner.pendingRunNowLabels(dir: env.markerDir), [label])
        XCTAssertNotNil(TickLock.takeBlockedSince(url: env.blockedURL))
    }

    /// A run that outlasts the heartbeat limit gives the lock up and the tick ends itself,
    /// leaving the reason in the Run History of the workspace the stalled schedule is for, and
    /// of no other workspace.
    func testARunPastTheHeartbeatLimitExitsAndRecordsWhy() async throws {
        let exits = Counter()
        let env = try environment(
            heartbeatLimit: .milliseconds(60),
            perform: { _ in
                for _ in 0..<500 where exits.values.isEmpty {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return ScheduleRunOutcome(exitCode: 1, incomplete: false)
            },
            exit: { exits.add("\($0)") })

        _ = await runTick(arguments: ["--tick"], environment: env)

        XCTAssertEqual(exits.values.first, "1")
        let run = try XCTUnwrap(RunHistoryService.list(profile: "alpha").first)
        XCTAssertEqual(run.name, "Background item")
        let text = RunHistoryService.loadLog(run.logURL).map(\.text)
        XCTAssertTrue(text.contains { $0.contains("-hour limit and was stopped") }, "\(text)")
        XCTAssertTrue(text.contains { $0.hasPrefix("[error] tick: ") }, "\(text)")
        XCTAssertTrue(RunHistoryService.list(profile: "beta").isEmpty,
                      "the other workspace's history is untouched")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func add(_ value: String) { lock.withLock { recorded.append(value) } }
}
