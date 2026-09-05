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
        schedules: schedules, lastStarted: state.lastStarted,
        runNowLabels: TickRunner.consumeRunNowMarkers(), now: now,
        nonCatchUpAnchor: blockedSince)
    for schedule in due {
        guard let label = schedule.launchAgentLabel else { continue }
        state.lastStarted[label] = Date()
        do { try state.save() } catch {
            fputs("[error] tick: could not write tick-state.json: \(error.localizedDescription)\n",
                  stderr)
            return 1
        }
        let code = await runSchedule(schedule, verbose: false)
        print("[info] tick: \(label) exit \(code)")
    }
    // Once per wake, after all runs, so a schedule that just fired is not
    // reported overdue by the same process.
    await notifyOverdueSchedulesHeadless(
        profiles: profiles.map(\.name), excluding: Set(policy.excludedProfiles))
    return 0
}
