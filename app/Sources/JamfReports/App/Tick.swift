import Foundation

/// The bundled agent's entry: `JamfReports --tick [--now <label>]`.
/// Exit 0 unless the lock or the state file cannot be written; each
/// schedule's own outcome lands in its Run History record, not in this code.
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

    let policy = AutomationPolicy.current()
    let profiles = ProfileService.discoverLocal()
    let base = ManagedAutomation.managedBaseProfile(profiles: profiles, policy: policy)
    let managed = ManagedAutomation.desiredSchedules(for: policy, baseProfile: base)
    let handBuilt = ScheduleStore().load().map { $0.toSchedule() }
        .sorted { ($0.launchAgentLabel ?? "") < ($1.launchAgentLabel ?? "") }
    let schedules = managed + handBuilt

    var state = TickState.load()
    let due = TickScheduler.due(
        schedules: schedules, state: state,
        runNowLabels: TickRunner.consumeRunNowMarkers(), now: now,
        nonCatchUpAnchor: blockedSince)
    for run in due {
        guard let label = run.schedule.launchAgentLabel else { continue }
        // Stamped BEFORE the run so a crash mid-collect still counts as an
        // attempt and cannot re-run on every wake.
        let startedAt = Date()
        state.noteStarted(label, at: startedAt, reason: run.reason)
        guard saveTickState(state) else { return 1 }
        lock.touch()
        let outcome = await lock.keepingAlive { await runSchedule(run.schedule, verbose: false) }
        if outcome.succeeded {
            state.noteSucceeded(label, startedAt: startedAt)
            guard saveTickState(state) else { return 1 }
        }
        print(tickResultLine(
            label: label, reason: run.reason, outcome: outcome,
            retries: state.retryCount[label] ?? 0))
    }
    // Once per wake, after all runs, so a schedule that just fired is not
    // reported overdue by the same process.
    await notifyOverdueSchedulesHeadless(
        profiles: profiles.map(\.name), excluding: Set(policy.excludedProfiles))
    return 0
}

/// `[info] tick: <label>[ retry N] exit <code>[ (incomplete|failed)]` — the
/// line the GUI's Run now streams back, so it names the attempt and the verdict.
private func tickResultLine(
    label: String, reason: TickScheduler.Reason, outcome: ScheduleRunOutcome, retries: Int
) -> String {
    let attempt = reason == .retry ? " retry \(retries)" : ""
    let verdict = outcome.succeeded ? "" : (outcome.incomplete ? " (incomplete)" : " (failed)")
    return "[info] tick: \(label)\(attempt) exit \(outcome.exitCode)\(verdict)"
}

/// False, with the error on stderr, when the stamps cannot be written. The
/// caller stops there: a run the state file cannot remember would repeat.
private func saveTickState(_ state: TickState) -> Bool {
    do {
        try state.save()
        return true
    } catch {
        fputs("[error] tick: could not write tick-state.json: \(error.localizedDescription)\n",
              stderr)
        return false
    }
}
