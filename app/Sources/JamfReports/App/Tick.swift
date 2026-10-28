import Foundation

/// What `runTick` touches outside its own logic. The defaults are the real files, clock, runs
/// and exit; a test swaps them so the real function runs end to end.
struct TickEnvironment: Sendable {
    var lock = TickLock(url: TickLock.defaultURL)
    var blockedURL = TickLock.defaultBlockedURL
    var stateURL = TickState.defaultURL
    var markerDir = TickRunner.runNowMarkerDir
    var scheduleStore = ScheduleStore()
    var profiles: @Sendable () -> [JamfCLIProfile] = { ProfileService.discoverLocal() }
    var policy: @Sendable () -> AutomationPolicy = { TickEnvironment.storedPolicy() }
    var clock: @Sendable () -> Date = { Date() }
    var summaryIsMissing: @Sendable (Schedule, [JamfCLIProfile], Date) -> Bool = {
        summaryMissing(for: $0, profiles: $1, now: $2)
    }
    var perform: @Sendable (TickScheduler.DueRun) async -> ScheduleRunOutcome = { run in
        // A same-day retry must not be answered by the once-a-day collect guard.
        await ReportEngine.$isSameDayRetry.withValue(run.reason == .retry) {
            await runSchedule(
                run.schedule, verbose: false, skipping: run.skipProfiles)
        }
    }
    var heartbeatEvery: Duration = TickLock.heartbeatInterval
    var heartbeatLimit: Duration = TickLock.heartbeatLimit
    var exit: @Sendable (Int32) -> Void = { Darwin.exit($0) }

    /// The stored policy. A test process shares `UserDefaults.standard` across suites, so a
    /// policy one left behind would run managed schedules another never asked for; there a tick
    /// reads the default policy unless the test injects one through `policy`.
    static func storedPolicy() -> AutomationPolicy {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { return AutomationPolicy() }
        #endif
        return AutomationPolicy.current()
    }
}

/// The bundled agent's entry: `JamfReports --tick [--now <label>]`.
/// Exit 0 unless the lock or a tick-state stamp cannot be written, 75 when another run holds
/// the lock. Each schedule's own outcome lands in its Run History record, not in this code,
/// and a lock or stamp failure in a "Background item" record (`TickFailureLog`).
@Sendable
func runTick(
    arguments: [String],
    environment: TickEnvironment = TickEnvironment()
) async -> Int32 {
    let now = environment.clock()
    let lock = environment.lock
    if let idx = arguments.firstIndex(of: "--now"), idx + 1 < arguments.count,
       !arguments[idx + 1].hasPrefix("--") {
        do {
            try TickRunner.requestRunNow(label: arguments[idx + 1], dir: environment.markerDir)
        } catch {
            fputs("[error] could not queue run-now: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
    let hold: TickLockHold
    switch lock.claim() {
    case .acquired(let held):
        hold = held
    case .heldElsewhere:
        // Stamp the refusal before returning: the non-catch-up window and the off gap for the
        // wake that eventually gets in are measured from here, not from that wake's own clock.
        TickLock.noteBlocked(url: environment.blockedURL, now: now)
        fputs("[info] tick: another run holds the lock — queued markers run on the next wake\n",
              stderr)
        return TickRunner.queuedExitCode
    case .writeFailed:
        // Not a queue: nobody holds the lock. Running without it is pointless, since
        // `TickState.save` writes beside it, and a blocked stamp would hide the overdue warning.
        let message = "lock file not writable (\(lock.url.path))"
        fputs("[error] tick: \(message)\n", stderr)
        let failures = TickFailureLog(profiles: environment.profiles())
        failures.recordInEveryWorkspace(message)
        failures.finish()
        return 1
    }
    defer { hold.release() }
    let blocked = TickLock.takeBlockedSince(url: environment.blockedURL)

    // Listed before the schedules load: Run now only queues a label whose schedule
    // already exists, so the load below sees every schedule a listed marker names.
    let runNowLabels = TickRunner.pendingRunNowLabels(dir: environment.markerDir)
    let policy = environment.policy()
    let profiles = environment.profiles()
    let base = ManagedAutomation.managedBaseProfile(profiles: profiles, policy: policy)
    let managed = ManagedAutomation.desiredSchedules(for: policy, baseProfile: base)
    let handBuilt = environment.scheduleStore.load().map { $0.toSchedule() }
        .sorted { ($0.launchAgentLabel ?? "") < ($1.launchAgentLabel ?? "") }
    let schedules = managed + handBuilt
    // A marker no schedule carries can never run: drop it now, as the old
    // read-and-delete did. The rest are cleared one by one as their runs start.
    let known = Set(schedules.compactMap(\.launchAgentLabel))
    for label in runNowLabels.subtracting(known) {
        TickRunner.clearRunNowMarker(label: label, dir: environment.markerDir)
    }

    var state = TickState.load(url: environment.stateURL)
    let due = TickScheduler.due(
        schedules: schedules, state: state, runNowLabels: runNowLabels, now: now,
        nonCatchUpAnchor: TickScheduler.nonCatchUpAnchor(refusals: blocked, now: now),
        wasOff: TickScheduler.wasOff(lastTick: state.lastTick, refusals: blocked, now: now),
        summaryMissingToday: { environment.summaryIsMissing($0, profiles, now) })
    // After the decision, which reads the previous wake. Best-effort: without it a daily
    // schedule just waits for its fire. A wake a long run turns away stamps `.tick.blocked`,
    // so the run's own length never reads as the Mac being off.
    state.lastTick = now
    saveLastTick(state, to: environment.stateURL)
    let failures = TickFailureLog(profiles: profiles)
    defer { failures.finish() }
    let result = await TickLoop.runDue(
        due, state: state, runNowLabels: runNowLabels,
        clock: environment.clock,
        save: { try $0.save(url: environment.stateURL) },
        clearRunNowMarker: { TickRunner.clearRunNowMarker(label: $0, dir: environment.markerDir) },
        perform: { run in
            hold.touch()
            return await hold.keepingAlive(
                every: environment.heartbeatEvery, limit: environment.heartbeatLimit,
                onGiveUp: {
                    // The stalled run is this schedule's, so its record goes to the workspaces
                    // the schedule is for.
                    exitAfterLockGiveUp(
                        workspaces: { workspaces(of: run.schedule, among: { profiles }) },
                        exit: environment.exit)
                }
            ) {
                await environment.perform(run)
            }
        },
        recordFailure: failures.record,
        holdsLock: { hold.isHeld },
        // Once per wake, after all runs, so a schedule that just fired is not
        // reported overdue by the same process. Inside the heartbeat like the runs, so a slow
        // webhook send cannot let the lock read as stale.
        notifyOverdue: {
            await hold.keepingAlive(
                every: environment.heartbeatEvery, limit: environment.heartbeatLimit,
                onGiveUp: { exitAfterLockGiveUp(profiles: profiles, exit: environment.exit) }
            ) {
                await notifyOverdueSchedulesHeadless(
                    profiles: profiles.map(\.name), excluding: Set(policy.excludedProfiles),
                    policy: policy)
                // A Run now (the GUI, `schedules run`) is not the background item's own wake.
                guard !arguments.contains("--now") else { return }
                await ScheduledRunSignals.notifyHeartbeats(
                    profiles: profiles.map(\.name), excluding: Set(policy.excludedProfiles))
            }
        })
    return result
}

/// True when a run of `schedule` is meant to write today's summary for a workspace that has
/// none. Jamf Pro and Jamf School collects both write one; only a collect that reaches the
/// refresh or inventory tier is meant to, not the weekly scan or a run from cache.
func summaryMissing(for schedule: Schedule, profiles: [JamfCLIProfile], now: Date) -> Bool {
    guard schedule.mode.runsAtLoad,
          schedule.tiers.map({ !$0.isDisjoint(with: [.refresh, .inventory]) }) ?? true
    else { return false }
    let names = schedule.isMulti
        ? ProfileService.runnableProfiles(
            profiles, excluding: Set(schedule.excludedProfiles ?? [])).map(\.name)
        : [schedule.profile]
    return names.contains { !SummaryJSONParser.hasSummary(profile: $0, on: now) }
}

/// Who held the tick lock when its heartbeat gave it up; names the process in the log line and
/// the Run History record.
enum LockHolder: Sendable {
    case tick, scheduledRun, command

    var label: String {
        switch self {
        case .tick: "tick"
        case .scheduledRun: "scheduled run"
        case .command: "command"
        }
    }
}

/// The heartbeat gave the lock up after `TickLock.heartbeatLimit`, so a call that never
/// answered is still running with no lock. The next wake would start a second run beside it, so
/// the process ends, which ends the call; the run's own record is left without a footer and
/// reads as interrupted, and this adds the reason to the Run History of `workspaces` (the ones
/// the run was for). `workspaces` runs after the children are stopped: discovering profiles can
/// launch `config list`, and the stalled call must not keep running while it does.
func exitAfterLockGiveUp(
    caller: LockHolder = .tick,
    workspaces: () -> [String],
    exit: @Sendable (Int32) -> Void
) {
    let hours = TickLock.heartbeatLimit.components.seconds / 3600
    let message = "a run passed the tick lock's \(hours)-hour limit and was stopped so it "
        + "cannot run beside the next wake"
    reportTickError(message, caller: caller)
    // Ending this process does not end the jamf-cli call it started, so stop that first. It also
    // latches the exit path, so a probe the lookup below launches is stopped at its own site.
    CLIBridge.terminateRunningChildren()
    let failures = TickFailureLog(profiles: [])
    failures.record(message, in: workspaces(), as: caller)
    failures.finish()
    // A launch that slipped in during the writes above is stopped by its own site; this catches
    // any that were already running.
    CLIBridge.terminateRunningChildren()
    exit(1)
}

/// The tick's give-up: its record goes to every runnable workspace, since any of them may be the
/// one an operator opens.
func exitAfterLockGiveUp(profiles: [JamfCLIProfile], exit: @Sendable (Int32) -> Void) {
    exitAfterLockGiveUp(
        workspaces: { ProfileService.runnableProfiles(profiles, excluding: []).map(\.name) },
        exit: exit)
}

/// The give-up for a process that holds the tick lock through `holdingForRun` (`--scheduled-run`,
/// the included CLI): the tick's own, so a stalled jamf-cli call there cannot run beside the
/// next wake either.
func lockGiveUp(
    _ caller: LockHolder,
    workspaces: @escaping @Sendable () -> [String],
    exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }
) -> @Sendable () -> Void {
    { exitAfterLockGiveUp(caller: caller, workspaces: workspaces, exit: exit) }
}

/// The workspaces a scheduled run is for: its profile, or for a multi-profile schedule the
/// runnable ones it fans out over. For a multi schedule `among` defaults to discovery, which in a
/// give-up runs after the exit path is latched, so it is folder-based at that point.
func workspaces(
    of schedule: Schedule,
    among profiles: () -> [JamfCLIProfile] = { ProfileService.discoverLocal() }
) -> [String] {
    guard schedule.isMulti else { return [schedule.profile] }
    return ProfileService.runnableProfiles(
        profiles(), excluding: Set(schedule.excludedProfiles ?? [])
    ).map(\.name)
}

private func saveLastTick(_ state: TickState, to url: URL) {
    do { try state.save(url: url) } catch {
        AppLogger.schedule.warning(
            "tick: wake time not recorded: \(error.localizedDescription, privacy: .public)")
    }
}

/// `runSchedule` for a process that is not the tick: `--scheduled-run` from an external
/// scheduler. It holds the tick lock as the tick does, so it cannot overlap a GUI collect or
/// report, a tick or a CLI command. Nil, with one line on stderr and nothing run, when another
/// live process holds the lock; the caller exits `TickRunner.queuedExitCode`, as a tick does.
@Sendable
func runScheduleExclusively(
    _ schedule: Schedule,
    verbose: Bool,
    lock: TickLock = TickLock(url: TickLock.defaultURL),
    limit: Duration = TickLock.heartbeatLimit,
    onGiveUp: (@Sendable () -> Void)? = nil
) async -> ScheduleRunOutcome? {
    let giveUp = onGiveUp ?? lockGiveUp(.scheduledRun, workspaces: { workspaces(of: schedule) })
    let outcome = await lock.holdingForRun(limit: limit, onGiveUp: giveUp) {
        await runSchedule(schedule, verbose: verbose)
    }
    if outcome == nil {
        fputs("[info] scheduled-run: \(TickLock.busyMessage)\n", stderr)
    }
    return outcome
}

/// The per-schedule half of a tick. Its effects are passed in so the stamp and
/// marker ordering can be tested without the lock, the state file or a real run.
enum TickLoop {
    /// Runs `due` in order, then the overdue digest. Returns 1 when any tick-state
    /// stamp could not be written, else 0.
    ///
    /// A start that cannot be stamped skips only that schedule: a run the state
    /// file cannot remember would repeat on every wake. The in-memory state goes
    /// back to what it was, so a later save cannot record a start that never
    /// happened, and a run-now marker stays for the next wake. A success that
    /// cannot be stamped is logged and the loop carries on: the run happened, a
    /// later save in this tick still records it, and at worst a same-day retry
    /// repeats it. Neither failure stops the schedules after it or the digest, and
    /// both go to `recordFailure` with their schedule for Run History.
    ///
    /// A Run now writes nothing to the state, but its start is still saved first so a marker is
    /// never cleared on a state file that cannot be written. A marker is cleared whichever
    /// reason its label runs under. `clock` is the start time each run is stamped with.
    static func runDue(
        _ due: [TickScheduler.DueRun],
        state initial: TickState,
        runNowLabels: Set<String>,
        clock: () -> Date = Date.init,
        save: (TickState) throws -> Void,
        clearRunNowMarker: (String) -> Void,
        perform: (TickScheduler.DueRun) async -> ScheduleRunOutcome,
        recordFailure: (Schedule, String) -> Void,
        holdsLock: () -> Bool = { true },
        notifyOverdue: () async -> Void
    ) async -> Int32 {
        var state = initial
        var failed = false
        for run in due {
            guard holdsLock() else {
                // A run that outlasted the lock's time limit gave it up: the rest wait, still
                // due, for the next wake rather than start beside whatever took it.
                fputs("[warn] tick: the lock was given up mid-wake — remaining schedules wait\n",
                      stderr)
                break
            }
            guard let label = run.schedule.launchAgentLabel else { continue }
            // Stamped BEFORE the run so a crash mid-collect still counts as an
            // attempt and cannot re-run on every wake.
            let before = state
            let startedAt = clock()
            state.noteStarted(label, at: startedAt, reason: run.reason)
            do {
                try save(state)
            } catch {
                state = before
                failed = true
                let message = "skipped \(label): its start could not be recorded — "
                    + "could not write tick-state.json: \(error.localizedDescription)"
                reportTickError(message)
                recordFailure(run.schedule, message)
                continue
            }
            // The start is on disk, so the request is honoured. Cleared before the
            // run, never after: see `TickRunner.clearRunNowMarker`.
            if runNowLabels.contains(label) { clearRunNowMarker(label) }
            let ran = await perform(run)
            // A Run now pays no day and ends no retries.
            let scheduled = run.reason != .runNow
            let outcomesChanged = state.noteProfileOutcomes(
                label, ran.profiles, considered: ran.considered, reason: run.reason)
            // A retry of some profiles still answers for all of them, one that ran none included.
            let merged = scheduled ? state.profileOutcomes[label] ?? [] : []
            let outcome = merged.isEmpty
                ? ran : ScheduleRunOutcome(over: merged, ran: ran.profiles)
            if scheduled, outcome.endsRetries {
                state.noteSucceeded(label, startedAt: startedAt)
                do {
                    try save(state)
                } catch {
                    failed = true
                    let message = "\(label) succeeded, but the success could not be recorded — "
                        + "could not write tick-state.json: \(error.localizedDescription)"
                    reportTickError(message)
                    recordFailure(run.schedule, message)
                }
            } else if scheduled {
                let verdictChanged = state.noteRetry(label, couldHelp: outcome.retryCouldHelp)
                // Best-effort: unrecorded, the hourly retries run as if a retry could help and
                // a retry runs every profile.
                if verdictChanged || outcomesChanged {
                    do { try save(state) } catch {
                        AppLogger.schedule.warning(
                            "tick: \(label, privacy: .public) retry verdict not recorded")
                    }
                }
            }
            print(tickResultLine(
                label: label, reason: run.reason, outcome: outcome,
                retries: state.retryCount[label] ?? 0))
        }
        await notifyOverdue()
        return failed ? 1 : 0
    }
}

/// `[info] tick: <label>[ retry N] exit <code>[ (incomplete|failed)]` — the
/// line the GUI's Run now streams back, so it names the attempt and the verdict.
func tickResultLine(
    label: String, reason: TickScheduler.Reason, outcome: ScheduleRunOutcome, retries: Int
) -> String {
    let attempt = reason == .retry ? " retry \(retries)" : ""
    let verdict = outcome.succeeded ? "" : (outcome.incomplete ? " (incomplete)" : " (failed)")
    return "[info] tick: \(label)\(attempt) exit \(outcome.exitCode)\(verdict)"
}

/// Run History for tick-level failures: one record per workspace per wake, under the
/// background item's own label, in every workspace the affected schedule runs for.
final class TickFailureLog {
    /// Tick records a workspace keeps. A tick-state file that stays unwritable adds one
    /// every wake; without a cap they would push schedule runs out of the recorder's window.
    static let keptRecords = 5

    private let profiles: [JamfCLIProfile]
    private var recorders: [String: ScheduledRunRecorder] = [:]

    /// `profiles` are this wake's discovered profiles, which a multi schedule fans out over.
    init(profiles: [JamfCLIProfile]) {
        self.profiles = profiles
    }

    func record(_ schedule: Schedule, _ message: String) {
        let names = schedule.isMulti
            ? ProfileService.runnableProfiles(
                profiles, excluding: Set(schedule.excludedProfiles ?? [])).map(\.name)
            : [schedule.profile]
        for name in names {
            recorder(for: name)?.record("[error] tick: \(message)")
        }
    }

    /// A failure that belongs to no schedule (the tick could not take its lock): the record
    /// goes to every runnable workspace, since any of them may be the one an operator opens.
    func recordInEveryWorkspace(_ message: String) {
        record(message, in: ProfileService.runnableProfiles(profiles, excluding: []).map(\.name))
    }

    /// A failure of the process `caller` names, recorded in the workspaces it was for.
    func record(_ message: String, in names: [String], as caller: LockHolder = .tick) {
        for name in names {
            recorder(for: name)?.record("[error] \(caller.label): \(message)")
        }
    }

    /// Ends each record as a failed run.
    func finish() {
        for recorder in recorders.values { recorder.finish(exitCode: 1) }
        recorders = [:]
    }

    private func recorder(for profile: String) -> ScheduledRunRecorder? {
        if let open = recorders[profile] { return open }
        if let logs = try? WorkspacePaths.runHistoryDir(for: profile) {
            ScheduledRunRecorder.pruneRunLogs(
                in: logs, keep: Self.keptRecords - 1, label: AutomationHealth.tickerLabel)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let recorder = ScheduledRunRecorder(
                  workspace: workspace, label: AutomationHealth.tickerLabel)
        else { return nil }
        recorders[profile] = recorder
        return recorder
    }
}

/// stderr reaches only a Run now caller that streams the tick's output; the bundled
/// agent's stderr goes nowhere, so OSLog and `TickFailureLog` are the lasting record.
private func reportTickError(_ message: String, caller: LockHolder = .tick) {
    fputs("[error] \(caller.label): \(message)\n", stderr)
    AppLogger.schedule.error("\(caller.label, privacy: .public): \(message, privacy: .public)")
}
