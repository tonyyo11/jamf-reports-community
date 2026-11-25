# Continue today's collect (split collect) — 2.13, wave D

*   **Author:** Tony Young
*   **Status:** Proposed (awaiting egm-review)
*   **Date:** 2026-11-25
*   **Epic:** #421 (Automation). Follows the 2.12 large-fleet design
    (`docs/superpowers/specs/2026-11-17-large-fleet-design.md`, L2 item 4).

--------------------------------------------------------------------------------

## Overview

On a large Jamf Pro fleet one collect can need more time than a scheduled run is allowed to hold
the lock. 2.12 already stops a scheduled run between sources once it has held the tick lock for
`jamf_cli.run_budget_minutes` (45 minutes by default), logs `[info] stopped early: …` with what is
left, and relies on the tick's same-day retry to collect the rest.

This design makes that pickup a planned continuation instead of a failure retry. A run that stopped
at its budget is continued at the next tick wake where the lock is free and nothing else is due,
until every source due today has landed or local midnight comes. It does not spend the 1, 2 and 4
hour backoff kept for real failures. The Automation screen shows today's progress per workspace and
offers "Continue now". The schedule list's status pill shows each schedule's real last outcome
instead of a hardcoded OK.

Small fleets that finish inside the budget see no change. An operator who wants smaller runs lowers
`run_budget_minutes`; there is no new switch.

The feature was called "micro-refresh" in epic #421, where it meant light fleet-level calls between
collects. Tony's answer on 2026-11-25 is that the purpose is spreading one large fleet's collect,
so that name is retired here and the light-calls item is closed in #421 with that answer as the
reason.

## The Problem

What is true today (2.12), from the code:

*   **The pickup ends after about seven hours.** After a budget stop the tick retries 1, 2 and 4
    hours after the previous start (`TickScheduler.retryBackoffs`). The hourly retries after those
    three run only while today's summary is missing (`TickScheduler.retryIsDue`, the
    `summaryMissing()` branch). A stopped run almost always has today's summary, because 2.12 writes
    an early summary before the slow sources and `finalizeCollect` writes one at the end. So a fleet
    that needs five budget-length runs gets four at most, and the rest waits for the next day's
    fire.
*   **A planned stop spends the failure backoff.** `stoppedEarly` makes `retryCouldHelp` true
    (`ScheduledRunSignals`), and each retry advances `retryCount`. A real failure later that day
    then has fewer, later retries left.
*   **Why a run stopped is lost.** `RunStop` tells a budget stop (`.budgetUsed`) from a stop for a
    manual refresh (`.manualRefresh`), but the per-profile outcome the tick keeps
    (`ProfileOutcome`: exit, incomplete, retryCouldHelp) records neither, so the tick cannot treat
    them differently.
*   **Nothing shows progress.** The operator sees `stopped early` in a run log, not "18 of 31
    sources collected today, next pickup at 10:05".
*   **The status pill lies.** The schedule list builds every row with `lastStatus: .ok`
    (`ManagedAutomation.makeSchedule`, `ScheduleStore`, and the CLI's `schedules list`), whatever the
    last run did. The decision log left this for #421 on 2026-11-15.
*   **A manual refresh does not say which workspace it is for.** `ManualRefreshRequest` is one
    per-Mac file. Clicking Refresh on workspace A stops a scheduled run collecting workspace B, which
    is right (the tick lock covers the whole Mac, so A's refresh cannot start until B's run gives it
    up), but nothing then tells B's leftovers apart from leftovers A's own refresh will collect.

What is not known: no log yet shows a healthy fleet (every source answering) running past 45
minutes. The one large-fleet report (5,923 Macs) spent its hours in one source, `patch-status`,
timing out; 2.12's timeout hold, title-by-title walk and `collect_skip` answered that, and the
decision log records that every other source then collected near instantly. Prod's slowest source
took 24 s. So the split-day handling beyond the defects above (summary provenance, report timing,
shared workspaces) is designed here but built only after a measurement shows it is needed.

## Goals

1.  A scheduled run that stopped at its budget keeps getting continuations, at the next free tick
    wake, until every source due today has landed or local midnight, whichever is first.
2.  A continuation does not advance the failure retry count. When a run both stopped at its budget
    and had a failed source, the failure rule (1, 2, 4 hour backoff) decides the next run.
3.  A run stopped for a manual refresh of the same workspace is not continued by the tick: that
    refresh collects everything due. A run stopped for a refresh of another workspace is continued
    like a budget stop.
4.  A continuation collects only what is still due today (unforced), gets past the once-a-day full
    collect guard, and stays inside the run budget.
5.  The Automation screen shows, per workspace with an open split day, "N of M sources collected
    today" and the next pickup time, computed by the same function the tick uses to decide a
    continuation is due.
6.  "Continue now" on that line runs the same unforced continuation immediately, under the same
    lock and budget.
7.  The schedule list's status pill (GUI and `jamf-reports schedules list`) shows the last real
    outcome, plus an "in progress" state for an open split day.
8.  A manual refresh still stops whatever scheduled run holds the lock, between sources, as in
    2.12, and now names its workspace so the tick can apply goal 3.
9.  Jamf School and Protect-only workspaces get no continuation, and the screen says why.
10. A continuation never makes a schedule read as overdue, and a continuation's stamp never hides a
    missed fire.

## Non-Goals

*   No fourth `CollectionTier`, no fifth managed schedule kind, no new cadence string form.
*   No opt-in switch and no interval setting. Lowering `jamf_cli.run_budget_minutes` is the opt-in.
*   No light "micro" sources between collects (wave A's kinds or `overview` on an interval), and no
    capture of `pro inventory-information` or `pro health-check` for this wave.
*   No continuation across local midnight.
*   No continuation for Jamf School or Protect-only workspaces (both collect every source each run,
    so a continuation would fetch everything again).
*   No wider Automation customization (per-workspace run time, report template, formats, retries,
    per-schedule notifications). No one has asked for it.
*   Designed here, not built in this wave (waits on a real fleet log showing `stopped early` on most
    days): a `lateSources` field in the daily summary, reports and cards marked "sources still
    coming" on a split day, and shared-workspace continuation (the starting Mac finishes, peers wait
    for its claim to expire).

## Open Questions

*   **Q4. Server load from back-to-back continuations.** With "next free wake", a fleet that needs
    five budget-length runs holds the lock for about four hours with five-minute gaps. Manual
    refreshes and other schedules still go first, but the Jamf Pro server sees a collect most of
    the morning. The measurement gate (fake jamf-cli, then NFR at `run_budget_minutes: 10`) records
    total lock time per day; if that is a problem on a real server, a floor between continuations
    is the fallback (a constant, not a setting).

(Q1 to Q3 from the first draft are answered in the Technical Plan: a continuation stamps
`lastStarted` without touching the retry count; M counts every source the day's first run planned,
Protect included; continuations stay under the schedule's own label in Run History.)

## Critical User Journeys (CUJs)

### CUJ 1: A large fleet finishes its day in several runs

*   **Given**: Managed freshness at 06:00 on a Jamf Pro workspace whose collect needs about two
    hours; `run_budget_minutes` 45.
*   **When**: The 06:00 run stops at 06:45 with `[info] stopped early: run budget used (45
    minutes); 12 sources left for the next run`.
*   **Then**: The next tick wake with the lock free (about 06:50) runs a continuation, unforced,
    collecting only what is still due; so do later wakes until every source has landed. The retry
    count stays 0, the Automation screen reads "19 of 31 sources collected today, next pickup at
    about 06:50", and the schedule list's pill reads "In progress" until the day's plan is done,
    then OK.

### CUJ 2: A small fleet sees no change

*   **Given**: A 500-Mac workspace whose collect finishes in 6 minutes.
*   **When**: Managed freshness runs.
*   **Then**: The run ends without a budget stop, no continuation is ever due, no progress line is
    shown, and the pill reads OK.

### CUJ 3: Refresh while a continuation runs

*   **Given**: A continuation is collecting workspace A; workspace B has no run.
*   **When**: The operator clicks Refresh on workspace A.
*   **Then**: The continuation stops at the next source boundary (`stopped for a manual
    refresh`), the forced manual collect runs, and the tick does not continue A's stopped run.
    Clicking Refresh on workspace B instead also stops A's continuation (B cannot collect while A
    holds the lock), B's refresh runs, and A's split day carries on at the next free wake.

### CUJ 4: Continue now

*   **Given**: An open split day on workspace A, next pickup at about 10:05.
*   **When**: The operator clicks "Continue now" at 09:50.
*   **Then**: The app queues a Run now for that schedule label, which the tick runs as a
    continuation: unforced, past the once-a-day guard, within the budget. Nothing already fresh is
    fetched again.

### CUJ 5: A real failure on a split day

*   **Given**: A run stops at its budget and `patch-status` also timed out in it.
*   **When**: The tick decides the next run.
*   **Then**: The failure rule wins: a retry after 1 hour (unforced, so it also collects the rest),
    counted against the 1, 2, 4 hour backoff. Continuations resume only once a run ends with the
    budget as its only reason to come back.

### CUJ 6: Jamf School and Protect-only

*   **Given**: A School workspace whose `jamf-cli-full` run stops at the budget.
*   **When**: The tick decides the next run.
*   **Then**: No continuation: the run keeps today's retry behaviour, and the Automation screen says
    "Jamf School collects every source in each run, so a stopped run is retried, not continued."
    Protect-only reads the same with "Jamf Protect".

## Technical Plan (Architecture)

### Where it sits

```text
 tick wake (every 300 s, takes the lock)
   └─ TickScheduler.due(...)                       pure
        ├─ fire / catchUp / retry   (unchanged)
        ├─ runNow marker            (unchanged; on an open split day it runs as .continuation)
        └─ continuation             NEW: only when nothing else is due this wake, at most one
   └─ TickLoop.runDue
        ├─ TickState.noteStarted(.continuation)    lastStarted = now, retryCount unchanged
        ├─ runSchedule  (isSameDayRetry = true for .retry and .continuation)
        │    └─ scheduledRunSingle → CollectRouter → ReportEngine.collect (unforced)
        │         └─ RunStop: budget | manual refresh (now scoped to its workspace)
        │    └─ CollectHonestyWatcher: stop reason + planned/left counts per profile
        └─ TickState: splitDay[label][profile] updated; continuation due again or closed
 app
   └─ Automation screen: progress line + Continue now  ← reads tick-state.json (same Mac)
   └─ schedule list pill                                ← status file + log + splitDay
```

### 1. Telling a budget stop from the rest

`ReportEngine.stopsRun` already writes `stoppedEarlyMarker` + `RunStop.reason`. The reason texts
become named constants (`run budget used`, `stopped for a manual refresh`) so the watcher can read
which one it was. `CollectHonestyWatcher` gains:

*   `stopReason`: `.budget`, `.manualRefresh` or nil, from the stopped-early line.
*   `plannedSources` and `sourcesLeft`: the sum of the `collecting N sources` lines the run logs
    (Jamf Pro's `[plan]` line, then Protect's and Security Cloud's own), and the sum of the counts
    in its stopped-early lines (`N sources left`; a stopped Pro run lets Protect start and stop at
    once, with a line of its own).
*   A failure verdict that ignores the stop: `retryCouldHelp(profile:)` today returns true as soon
    as `stoppedEarly` is set. That line moves out, into the outcome builder below, so the verdict
    for "did something fail that a retry could fetch" is computed on its own.

`ScheduleRunOutcome` and `ProfileOutcome` gain an optional `stop` (`budget` or `manual_refresh`)
and the planned and left counts. `ProfileOutcome` decodes them with `decodeIfPresent`, so an older
`tick-state.json` reads as no stop. `retryCouldHelp` on the outcome keeps its meaning for
everything that reads it today, defined as "failure could be fetched OR stopped early", so Run
History, the GUI and existing tests are unchanged; the tick reads the two parts apart.

### 2. Which stops are continued

A run's budget stop is continuable only when all of these hold, decided where the outcome is built
in `runSchedule` (one function, `SplitCollect.isContinuable`):

*   The stop reason is `.budget`, or a manual refresh of another workspace.
*   The schedule's mode collects (`runsAtLoad`).
*   The workspace routes to Jamf Pro: `ProfileProductType.detect` is not Jamf School and
    `EnvironmentProfiles.isConfirmedProtectOnly` is false. School `jamf-cli-full` runs and
    Protect-only runs are forced, so a continuation would fetch everything again; they keep
    today's retry.

### 3. The continuation due rule

`TickScheduler.Reason` gains `.continuation`. `TickState` gains `splitDay: [label: SplitDay]`,
`SplitDay` = `day` (local start of day), `profiles: [profile: Progress]` with `planned`, `left`,
`lastFinished`. It is written by `TickLoop.runDue` from the run's outcome:

*   A scheduled run (fire, catch-up, retry, continuation) whose outcome is continuable opens or
    updates the label's `SplitDay` for today. `planned` is set by the day's first run only; later
    runs update `left` and `lastFinished`.
*   A run with no continuable stop for a profile removes that profile; an empty `SplitDay` is
    removed. A fire or catch-up on a new day removes yesterday's.

In `TickScheduler.due`, after the existing reasons are decided for every schedule:

*   If any schedule is due for another reason, no continuation is added this wake.
*   Otherwise the first schedule (in the existing run order) with a `SplitDay` for today, whose
    newest outcome does not have `retryCouldHelp` for a failure, is due as `.continuation`, with
    `skipProfiles` = the profiles not in its `SplitDay`. At most one per wake.
*   A `SplitDay` whose `day` is not today is ignored, so nothing continues past local midnight.
*   A Run now marker on a label with a `SplitDay` for today runs as `.continuation` (the existing
    rule: "a Run now marker runs the schedule's own due reason when it has one").

`noteStarted(.continuation)` sets `lastStarted` and leaves `retryCount` and `profileOutcomes`
alone: the day is already paid by the fire, and the failure backoff is not spent. A failed source
on a split day goes down the existing retry path (CUJ 5); when that retry ends on a budget stop
alone, the `SplitDay` carries on.

`TickEnvironment.perform` sets `ReportEngine.isSameDayRetry` for `.retry` and `.continuation`, so
an all-tier hand-built schedule is not answered "already collected" by the once-a-day guard. The
run is unforced (scheduled Jamf Pro collects already are), so only sources still due are fetched.

`tickResultLine` writes ` continuation` for the reason, and `scheduledRunSingle` logs one line at
the start of a continuation's run record: `[info] continuing today's collect: N of M sources
collected so far`.

### 4. Manual refresh names its workspace

The tick lock covers the whole Mac, so any manual refresh still stops whatever scheduled run holds
it, between sources (no change). `ManualRefreshRequest.post(workspace:)` writes
`<timestamp>\n<workspace>`; `isPending` keeps its meaning (any pending request). A new
`requestedWorkspace()` returns the named workspace, nil for a file an older app wrote.
`RunStop.manualRefresh` gains `sameWorkspace: Bool`, set by the `runStop` closure in
`stoppingBetweenSources(profile:)` by comparing its profile with the request (nil reads as the same
workspace, the 2.12 behaviour). The reason text tells them apart (`stopped for a manual refresh`,
`stopped for a manual refresh of another workspace`). A stop for a refresh of the same workspace is
not continued; a stop for another workspace's refresh is continuable like a budget stop.
`manualCollectMayStart` posts the active workspace.

Rejected by author (2026-11-25), replacing brainstorm decision 7: scoping the request so a refresh
stops only its own workspace's run would make a refresh on workspace A wait for workspace B's run to
reach its 45-minute budget, longer than the 30 minutes the app waits, so the refresh could fail.

### 5. Progress and Continue now (Automation screen)

`WorkspaceStore` reads `TickState.load()` (same Mac, Application Support) when automation health
is refreshed and publishes, for the active workspace, the open `SplitDay` entries: "N of M sources
collected today" with N = `planned − left`, clamped to 0…M (refresh-tier sources come due again
after 12 hours, so `left` can grow). The next pickup is `TickScheduler.nextContinuation(after:)`:
"at the next free check, about HH:MM", HH:MM being the next 300 s wake after `lastFinished` and
now. This line appears only on a Jamf Pro workspace with an open split day; School and
Protect-only workspaces show the sentence from CUJ 6 only when their last run stopped at the
budget.

"Continue now" calls `TickRunner.spawnNow(label:)` for the schedule, as Run now does. Disabled in
demo mode and while the lock is held by this app.

### 6. The status pill reads the real outcome

`Schedule.LastStatus` gains `.inProgress` (pill text "In progress", muted tone, accessibility
"Last run status: In progress"). One reader, `LaunchAgentService.lastRun(of:statusProfile:)`,
returns the last run's date and status from what `healthInputs` already reads (the per-profile or
multi status file) plus the newest run log of that label for the `[partial]` marker, through the
existing private `lastStatus(from:logSummary:)`. It returns `.inProgress` when the label has a
`SplitDay` for today. The three builders that hardcode `.ok` call it:
`WorkspaceStore.loadSchedules` (managed and hand-built), and the CLI's `schedules list`.
`ManagedAutomation.makeSchedule` and `ScheduleRecord.toSchedule` keep `.ok` as the placeholder for
"not read yet", since they are pure and have no file access.

### 7. Run History and the dead-man switch

Continuations write under the schedule's own label, so the status file the overdue check reads is
updated by them and the schedule's history reads as one sequence of runs. Five continuations a day
fill the recorder's 50 logs per workspace in about seven days instead of about fifty; the
measurement gate counts runs per day, and a separate cap is added only if that is a problem.

The overdue check is unchanged: a continuation is only due on a day that a fire or catch-up
already started, so it can never stand in for a missed fire, and its later `finishedAt` cannot
make a schedule read overdue. Tests pin both.

### 8. Shared workspaces in this wave

No change to the gate. On the Mac that started the day, a continuation passes the freshness check
(it ignores this Mac's own collects) and re-takes its own claim. On a peer Mac nothing continues,
because no `SplitDay` exists there. The planned handling (decision 3) waits for PR 3.

### 9. What a workspace gets

| Workspace | Budget stop | Progress line | Pill |
|---|---|---|---|
| Jamf Pro | continued at the next free wake until done or midnight | yes | In progress, then the real outcome |
| Jamf Pro with Protect | continued; Protect's sources count in M and run once Pro's are done | yes | same |
| Jamf School | today's retry (1, 2, 4 h) | CUJ 6 sentence | real outcome |
| Protect-only | today's retry | CUJ 6 sentence | real outcome |
| Any, collect finishes in budget | nothing to continue | none | real outcome |

## Alternatives Considered

### Alternative A: Do nothing; measure first

*   **Pros**: Adds no mechanism for a case no healthy fleet has shown yet.
*   **Cons**: Leaves two shipped defects: a budget stop gets at most four runs a day because the
    hourly retries need a missing summary, and a planned stop spends the failure backoff. The
    status pill keeps reading OK after a failed run.
*   **Reason for Rejection**: Rejected by author: the defects exist in 2.12 whatever a large fleet
    measures. Kept as the gate for the deferred split-day work (summary provenance, report timing,
    shared workspaces).

### Alternative B: Planned slices at a fixed interval with a stored plan

*   **Pros**: Predictable pickup times on screen.
*   **Cons**: A new state machine beside the tick. A stored list of what is left drifts: refresh-tier
    sources come due again after 12 hours, and `slowLast` keeps slow leftovers at the back. It
    duplicates what each kind's `.last` file already says, and invites an interval setting.
*   **Reason for Rejection**: Rejected by author: `planCollect` already derives what is left from
    `.last`, so only a count (for the progress line) is stored. Its UI goal survives as the
    progress line.

### Alternative C: A fixed 60-minute gap between continuations

*   **Pros**: Spreads load on the Jamf Pro server; matches the retry floor.
*   **Cons**: A fleet needing five budget-length runs finishes about four hours later than with the
    next free wake.
*   **Reason for Rejection**: Rejected by author (decision 2, 2026-11-25): the rest should start as
    soon as a run finishes. Kept as the fallback if the measurement shows server load is a problem
    (Q4), as a constant, not a setting.

### Alternative D: Extend `RefreshCoordinator`

*   **Pros**: Already checks staleness on an interval.
*   **Cons**: Runs only while the app is open; a large fleet's collect is scheduled and headless.
*   **Reason for Rejection**: Rejected by author: needs the app open.

### Alternative E: A fourth `CollectionTier` or a fifth managed schedule kind

*   **Pros**: Explicit in the policy and the schedule list.
*   **Cons**: A fourth tier changes `isFullCollect` (`tiers == allCases`) and every `allCases`
    default, and a kind can sit in only one tier. A fifth kind needs a new reserved label, a new
    interval cadence form and a dead-man switch that reads it.
*   **Reason for Rejection**: Rejected by author: the tick's existing due rule carries a continuation
    with one new reason.

### Alternative F: Light "micro" sources between collects (the epic's original micro-refresh)

*   **Pros**: Fresher tiles and alerts mid-day from small calls (wave A's kinds, `overview`).
*   **Cons**: Adds lock time on every fleet to fix a cost no one has reported; the epic's own
    concern (2026-11-16) was lock contention.
*   **Reason for Rejection**: Rejected by author (2026-11-25): the purpose is spreading a large
    fleet's collect, and no one has reported a cost from late alerts. The #421 item is closed with
    that answer.

### Alternative G: Store progress in the workspace (like `device-scan.round`)

*   **Pros**: A peer Mac could see the progress.
*   **Cons**: Peer-writable state the tick would have to read as untrusted (review checklist #13).
*   **Reason for Rejection**: Rejected by author: progress is per Mac in `tick-state.json`; a peer does
    not continue in this wave anyway.

### Alternative H: A wider Automation settings matrix

*   **Pros**: Per-workspace run time, report template and formats, retries and notifications per
    schedule.
*   **Cons**: Settings, pins and UI for a need no one has stated.
*   **Reason for Rejection**: Rejected by author (2026-11-25): no one has asked for it.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Security & privacy**: All new state is per Mac in Application Support (`tick-state.json`, the
    refresh request file), never in a workspace a peer can write. The workspace name in the
    request file is written by this app and compared, never shown or logged as path text.
*   **Lock time**: A continuation holds the lock under the same `run_budget_minutes` budget as any
    scheduled run, plus at most one source's `collectKindTimeout` (the budget is checked between
    sources). The measurement gate records total lock time per day (Q4).
*   **Rollout & rollback**: New `tick-state.json` fields and the request file's second line are read
    leniently, so a downgrade ignores them and an older app's request reads as "same workspace".
    `Schedule.LastStatus` is not persisted, so `.inProgress` needs no migration.

--------------------------------------------------------------------------------

### Additional Resources

*   `docs/superpowers/specs/2026-11-17-large-fleet-design.md` (L2 item 4: budget and pickup).
*   `.dev/egm/concepts_brief.md`, `.dev/egm/wave-d-research-brief.md`.
*   `docs/superpowers/review-checklist.md`.

### Future Improvements (PR 3, gated on a real fleet log showing `stopped early` on most days)

*   `DailySummary.lateSources`: kinds that landed in a continuation, through `filling(from:)`,
    `freshSummaryIsBetter` and the rebuild.
*   Reports and webhook cards on an open split day say "sources still coming".
*   Shared workspace: continuations take the claim with `checkFreshness: false`; activity is stamped
    when the day's plan is done; a peer continues after the starting Mac's claim expires.
*   A floor between continuations, if Q4 shows server load.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Commits, in order, all in one PR from `dev/wave-d-automation-bdab91` into `dev/2-13-0`. Each
commit builds and passes the suite on its own.

### Commit 1: status pill reads the real outcome (PR 0)

#### 1. `app/Sources/JamfReports/Models/Models.swift` (Modify)

*   `Schedule.LastStatus` gains `case inProgress`, with accessibility label "Last run status: In
    progress".

#### 2. `app/Sources/JamfReports/Services/LaunchAgentService.swift` (Modify)

*   New `static func lastRun(of schedule: Schedule, statusProfile: String?, splitDayOpen: Bool)
    -> (date: Date?, status: Schedule.LastStatus)`. Reads the status file the way `healthInputs`
    does (`multiRunStatus` or `readRunStatus`), and the newest run log of that label in the owning
    workspace's `runHistoryDir` for `[partial]` and the exit footer, then calls the existing private
    `lastStatus(from:logSummary:)`. `.inProgress` when `splitDayOpen`. No status and no log:
    `(nil, .ok)`, as today.

#### 3. `app/Sources/JamfReports/Services/WorkspaceStore.swift` (Modify)

*   `loadSchedules` fills `last` (`FileDisplay.date`) and `lastStatus` from `lastRun(of:)` for each
    schedule, with `statusProfile` = the base profile and `splitDayOpen` from `TickState.load()`.
    It is `nonisolated static`, so it stays off the main actor where it is already called.

#### 4. `app/Sources/JamfReports/CLI/ScheduleCommands.swift` (Modify)

*   `schedules list` builds its rows through the same reader instead of `lastStatus: .ok`, and
    prints the status word.

#### 5. `app/Sources/JamfReports/Views/SchedulesView.swift`, `Views/RunsView.swift` (Modify)

*   `statusPill(for:)` gains `.inProgress`: `Pill(text: L("IN PROGRESS"), tone: .muted, icon:
    "arrow.triangle.2.circlepath")`. Both switches are exhaustive, so the compiler finds them.

#### 6. Tests (Create/Modify)

*   `app/Tests/JamfReportsTests/LaunchAgentServiceTests.swift`: `lastRun(of:)` for a failed status
    file (fail), a status file with a `[partial]` log (partial), a refused run (warn), none (ok,
    nil date), a multi schedule, and `splitDayOpen` (in progress).
*   `app/Tests/JamfReportsTests/ScheduleCommandsTests.swift`: `schedules list` prints FAIL for a
    failed run.

### Commit 2: the run says why it stopped (PR 1, part 1)

#### 7. `app/Sources/JamfReports/Engine/ReportEngine+CollectPlan.swift` (Modify)

*   `RunStop.manualRefresh` becomes `manualRefresh(sameWorkspace: Bool)`; `reason` texts become
    constants `RunStop.budgetReasonPrefix` ("run budget used"), `manualRefreshReason` ("stopped for
    a manual refresh") and `otherWorkspaceRefreshReason` ("stopped for a manual refresh of another
    workspace"). `evaluate` takes `manualRefreshFor: String??` (nil: none pending; `.some(nil)`:
    pending, no workspace named) and `profile`. `stoppingBetweenSources(profile:)` passes
    `ManualRefreshRequest.pendingWorkspace()`.

#### 8. `app/Sources/JamfReports/Services/ManualRefreshRequest.swift` (Modify)

*   `post(workspace:now:appSupport:)` writes the timestamp, a newline and the workspace.
    `pendingWorkspace(now:appSupport:) -> String??` returns `.none` when nothing is pending,
    `.some(nil)` for a pending file with no second line, `.some(name)` otherwise. `isPending` keeps
    its signature, implemented on top of it.

#### 9. `app/Sources/JamfReports/Services/WorkspaceStore+Refresh.swift` (Modify)

*   `manualCollectMayStart` posts `ManualRefreshRequest.post(workspace: profile)`.

#### 10. `app/Sources/JamfReports/Services/ScheduledRunSignals.swift` (Modify)

*   `CollectHonestyWatcher` records `stopReason` (`budget`, `manualRefreshSame`,
    `manualRefreshOther`) from the stopped-early line, and sums `planned` (each `collecting N
    sources` line) and `left` (each `N sources left`). New `failureRetryCouldHelp(profile:exitCode:
    since:)`: today's `retryCouldHelp` without the `stoppedEarly` short-circuit. The existing
    `retryCouldHelp(profile:…)` keeps its result (failure OR stopped early) for every current
    caller.

#### 11. `app/Sources/JamfReports/Services/TickScheduler.swift` (Modify, part 1)

*   `ProfileOutcome` and `ScheduleRunOutcome` gain `stop: SplitStop?` (`budget`, `manual_refresh`,
    `other_refresh`), `failureRetryCouldHelp: Bool`, `planned: Int?`, `left: Int?`, all
    `decodeIfPresent` in `ProfileOutcome`, defaulting to no stop and `failureRetryCouldHelp =
    retryCouldHelp`. Existing initializers keep working through defaulted parameters.

#### 12. `app/Sources/JamfReports/App/HeadlessRun.swift` (Modify)

*   `runSchedule` fills the new outcome fields from the watcher, through
    `SplitCollect.isContinuable(stop:mode:profile:)` (new, file 13), so a School or Protect-only
    stop is recorded with `stop` nil and keeps today's retry.

#### 13. `app/Sources/JamfReports/Services/SplitCollect.swift` (Create)

*   `enum SplitCollect` with `isContinuable(stop:mode:profile:) -> Bool` (budget or other-workspace
    refresh, collect mode, Jamf Pro routing as in section 2) and `progress(planned:left:) -> (done:
    Int, of: Int)` (clamped). Pure except the product read, which takes the config as a parameter
    for tests.

#### 14. Tests

*   `RunStopTests.swift`: same-workspace, other-workspace and no-workspace requests; reason texts.
*   `CollectHonestyTests.swift`: stop reason and counts from real log lines (Pro plus Protect lines
    summed); `failureRetryCouldHelp` false for a clean budget stop, true with a `[partial]` source
    line.
*   `SplitCollectTests.swift` (Create): continuable for Jamf Pro budget and other-workspace stops;
    not for School, Protect-only, a same-workspace refresh, or `jamf-cli-only`.

### Commit 3: continuation due rule (PR 1, part 2)

#### 15. `app/Sources/JamfReports/Services/TickScheduler.swift` (Modify, part 2)

*   `Reason` gains `.continuation`. `TickState` gains `splitDay: [String: SplitDay]`
    (`decodeIfPresent`, under its own `try?` like `profileOutcomes`), `SplitDay { day: Date;
    profiles: [String: Progress] }`, `Progress { planned: Int; left: Int; lastFinished: Date }`.
*   `noteStarted(.continuation)`: `lastStarted = now`; retry count and outcomes unchanged. `.fire`
    and `.catchUp` also clear `splitDay[label]` when its `day` is not today.
*   `noteSplitDay(_ label:, outcome:, reason:, now:) -> Bool`: per profile (one entry under `""`
    for a single-profile schedule), a continuable stop opens or updates the entry (`planned` only
    on first sight that day), anything else removes it; drops an empty `SplitDay`. Run now stamps
    nothing here, except when it ran as `.continuation`.
*   `due(...)`: after the existing pass, if the result is empty, pick the first schedule in input
    order whose `splitDay` is for today and whose `retryWouldRepeat`/failure verdict does not make
    it retry-due; return it as `.continuation` with `skipProfiles` = profiles outside its
    `SplitDay`. A Run now marker on a label with an open `SplitDay` returns `.continuation`
    instead of `.runNow`.
*   `static func nextContinuation(label:state:now:wake:) -> Date?`: the next 300 s wake after
    `max(now, lastFinished)` while the `SplitDay` is open, nil otherwise. Used by the GUI.

#### 16. `app/Sources/JamfReports/App/Tick.swift` (Modify)

*   `TickEnvironment.perform` sets `isSameDayRetry` for `.retry` and `.continuation`.
*   `TickLoop.runDue` calls `noteSplitDay` after `noteProfileOutcomes` and saves when it changed;
    the tick decides retry vs continuation from `failureRetryCouldHelp` (a real failure keeps the
    retry path; a clean budget stop calls `noteSucceeded`-equivalent for the retry count only:
    `retryCount` and `retryWouldRepeat` stay as they were).
*   `tickResultLine` writes ` continuation` for the reason.

#### 17. `app/Sources/JamfReports/App/HeadlessRun.swift` (Modify)

*   `scheduledRunSingle` takes the reason; for `.continuation` it records `[info] continuing
    today's collect: N of M sources collected so far` as the run record's first line.

#### 18. Tests

*   `TickSchedulerTests.swift` / new `TickSchedulerContinuationTests.swift`: continuation due only
    when nothing else is due; at most one per wake; not after midnight; not when the newest
    outcome has a failure a retry could fetch; Run now on an open split day runs `.continuation`;
    `nextContinuation` times.
*   `TickLoopTests.swift`: a budget stop leaves `retryCount` unchanged and opens a `SplitDay`; a
    clean finish closes it; a failure plus a budget stop retries on the 1 h backoff; a School stop
    retries as today.
*   `TickSchedulerMissingSummaryTests.swift`: the budget-stop pickup no longer depends on
    `summaryMissing`.
*   `AutomationHealthTests.swift`: an open split day never reads overdue; a continuation's stamp on
    a day with no fire does not exist, so a missed fire still reads overdue.
*   `TickProfileOutcomeTests.swift`: an older `tick-state.json` without the new fields decodes; a
    bad `splitDay` entry does not cost the stamps.
*   `TickSimulation.swift` (Modify): a fake-jamf-cli simulation with per-kind delays and a 5-minute
    budget, checking the day finishes before midnight, no source runs twice, lock time per run is at
    most the budget plus one source, and the count of run logs per day.

### Commit 4: progress line and Continue now (PR 2) — DRAFT, needs visual verification

#### 19. `app/Sources/JamfReports/Views/SplitCollectCard.swift` (Create)

*   One card, shown by `AutomationView` (managed) and `SchedulesView` (hand-built), like
    `NotificationsCard`: per open `SplitDay` for the active workspace, "N of M sources collected
    today", "next pickup at about HH:MM" and a "Continue now" button (`TickRunner.spawnNow`). For a
    School or Protect-only workspace whose last run stopped at the budget, the CUJ 6 sentence
    instead. Hidden when there is nothing to show. Disabled in demo mode with
    `DemoData.liveOnlyHelp`.

#### 20. `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` (Modify)

*   `refreshAutomationHealth` also loads `TickState` off the main actor and publishes
    `splitCollectRows` for the active workspace.

#### 21. `app/Sources/JamfReports/Views/AutomationView.swift`, `Views/SchedulesView.swift` (Modify)

*   Place `SplitCollectCard` under the health card.

#### 22. `app/Localization/Localizable.xcstrings` (Modify)

*   New strings from commits 1 and 4, translated into every shipped language per
    `app/Localization/glossary.md`, through `app/scripts/sync-strings.zsh --prune-stale`.

#### 23. Tests

*   `SplitCollectCardTests.swift` (Create): rows from a `TickState` fixture; School sentence;
    demo mode disabled.

### Commit 5: docs and change notes (PR 4)

#### 24. `CHANGELOG.md` (Modify)

*   Unreleased: Changed (a run stopped at its budget is continued through the day; the schedule
    list shows each schedule's real last outcome), Added (progress line and Continue now).

#### 25. `docs/wiki/05-Scheduling-and-Automation.md` (Modify)

*   How a large fleet's collect is split, what School and Protect-only do, and that lowering
    `run_budget_minutes` is how to opt in.

#### 26. `config.example.yaml` (Modify)

*   Comment on `jamf_cli.run_budget_minutes`: a run stopped at the budget is continued later the
    same day; lower it to spread a collect over smaller runs.

#### 27. `CLAUDE.md` and `AGENTS.md` (Modify, kept in sync)

*   The `TickScheduler` row and the "Stopping between sources" paragraph describe `.continuation`,
    `SplitDay` and the named refresh request.

#### 28. `docs/superpowers/specs/2026-11-25-split-collect-design.md` (Create) and `docs/superpowers/specs/2026-11-17-large-fleet-design.md` (Modify)

*   This design, copied by hand once approved; one forward-pointer line in the large-fleet spec's
    L2 item 4.

### Verification Plan

*   **Build**: `cd app && swift build --build-tests`.
*   **Tests**: full suite through the `tip-test` skill on the PR head; the Swift 6.1 floor in the
    `ci-macos15-xcode16.4` VM through `vm-test`.
*   **Lint**: `xcrun swift-format lint` on touched files as a hint; `LocalizationCatalogTests`.
*   **Measurement gate** (before PR 3 is considered): the `TickSimulation` run above, then NFR with
    `run_budget_minutes: 10`, reading `<kind>.took`, continuations per day and total lock time.
*   **Visual**: commit 4 is marked DRAFT; render `SplitCollectCard` previews at
    `PageScaffold.minSupportedWidth` for Tony's pass.
