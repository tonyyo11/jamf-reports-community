import Foundation

/// The bundled agent's entry: `JamfReports --tick [--now <label>]`.
/// Exit 0 unless the lock or a tick-state stamp cannot be written; each
/// schedule's own outcome lands in its Run History record, not in this code,
/// and a stamp failure in a "Background item" record (`TickFailureLog`).
@Sendable
func runTick(arguments: [String], now: Date = Date()) async -> Int32 {
    if let idx = arguments.firstIndex(of: "--now"), idx + 1 < arguments.count,
       !arguments[idx + 1].hasPrefix("--") {
        do { try TickRunner.requestRunNow(label: arguments[idx + 1]) } catch {
            fputs("[error] could not queue run-now: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
    let lock = TickLock(url: TickLock.defaultURL)
    guard lock.acquire() else {
        // Stamp the refusal before returning: the non-catch-up window for the
        // wake that eventually gets in is measured from here, not from that
        // wake's own clock.
        TickLock.noteBlocked()
        fputs("[info] tick: another run holds the lock — queued markers run on the next wake\n",
              stderr)
        return TickRunner.queuedExitCode
    }
    defer { lock.release() }
    let blockedSince = TickLock.takeBlockedSince()

    // Listed before the schedules load: Run now only queues a label whose schedule
    // already exists, so the load below sees every schedule a listed marker names.
    let runNowLabels = TickRunner.pendingRunNowLabels()
    let policy = AutomationPolicy.current()
    let profiles = ProfileService.discoverLocal()
    let base = ManagedAutomation.managedBaseProfile(profiles: profiles, policy: policy)
    let managed = ManagedAutomation.desiredSchedules(for: policy, baseProfile: base)
    let handBuilt = ScheduleStore().load().map { $0.toSchedule() }
        .sorted { ($0.launchAgentLabel ?? "") < ($1.launchAgentLabel ?? "") }
    let schedules = managed + handBuilt
    // A marker no schedule carries can never run: drop it now, as the old
    // read-and-delete did. The rest are cleared one by one as their runs start.
    let known = Set(schedules.compactMap(\.launchAgentLabel))
    for label in runNowLabels.subtracting(known) {
        TickRunner.clearRunNowMarker(label: label)
    }

    let state = TickState.load()
    let due = TickScheduler.due(
        schedules: schedules, state: state, runNowLabels: runNowLabels, now: now,
        nonCatchUpAnchor: blockedSince)
    let failures = TickFailureLog(profiles: profiles)
    defer { failures.finish() }
    return await TickLoop.runDue(
        due, state: state,
        save: { try $0.save() },
        clearRunNowMarker: { TickRunner.clearRunNowMarker(label: $0) },
        perform: { run in
            lock.touch()
            return await lock.keepingAlive { await runSchedule(run.schedule, verbose: false) }
        },
        recordFailure: failures.record,
        // Once per wake, after all runs, so a schedule that just fired is not
        // reported overdue by the same process.
        notifyOverdue: {
            await notifyOverdueSchedulesHeadless(
                profiles: profiles.map(\.name), excluding: Set(policy.excludedProfiles))
        })
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
    static func runDue(
        _ due: [TickScheduler.DueRun],
        state initial: TickState,
        save: (TickState) throws -> Void,
        clearRunNowMarker: (String) -> Void,
        perform: (TickScheduler.DueRun) async -> ScheduleRunOutcome,
        recordFailure: (Schedule, String) -> Void,
        notifyOverdue: () async -> Void
    ) async -> Int32 {
        var state = initial
        var failed = false
        for run in due {
            guard let label = run.schedule.launchAgentLabel else { continue }
            // Stamped BEFORE the run so a crash mid-collect still counts as an
            // attempt and cannot re-run on every wake.
            let before = state
            let startedAt = Date()
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
            if run.reason == .runNow { clearRunNowMarker(label) }
            let outcome = await perform(run)
            if outcome.endsRetries {
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
private func reportTickError(_ message: String) {
    fputs("[error] tick: \(message)\n", stderr)
    AppLogger.schedule.error("tick: \(message, privacy: .public)")
}
