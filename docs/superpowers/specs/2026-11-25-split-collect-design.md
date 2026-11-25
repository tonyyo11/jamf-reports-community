# Continue today's collect (split collect) — 2.13, wave D

*   **Author:** Tony Young
*   **Status:** Reviewed (EGM, 2026-11-25); awaiting approval
*   **Date:** 2026-11-25
*   **Epic:** [#421](https://github.com/tonyyo11/jamf-reports-community/issues/421) (Automation).
    Follows the 2.12 large-fleet design (`docs/superpowers/specs/2026-11-17-large-fleet-design.md`,
    L2 item 4).

--------------------------------------------------------------------------------

## Overview

On a large Jamf Pro or Jamf School fleet one collect can need more time than a scheduled run is
allowed to hold the lock. 2.12 already stops a scheduled run between sources once it has held the
tick lock for `jamf_cli.run_budget_minutes` (45 minutes by default), logs `[info] stopped early: …`
with what is left, and relies on the tick's same-day retry to collect the rest.

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

## How it works today

*   **The tick.** One background item (`JamfReports --tick`) wakes every 300 seconds. A wake takes
    the tick lock, a kernel lock on one file that covers the whole Mac: only one collect, for any
    workspace, runs at a time. A wake that finds the lock held exits and is checked again 300
    seconds later.
*   **Schedules.** Managed schedules come from the Automation policy (daily freshness collect of the
    refresh and inventory tiers, weekly scan, reports, backup); hand-built schedules come from the
    schedule store. Each has a mode: `snapshot-only` and `jamf-cli-full` collect, `jamf-cli-only`
    and `backup` do not.
*   **Due reasons.** `TickScheduler.due` decides, per schedule, whether this wake runs it: a
    **fire** (the cadence time passed since its last start), a **catch-up** (a daily schedule's first
    wake after the Mac was off), a **retry** (a same-day re-run after a failed or incomplete run, 1,
    2 and 4 hours after the previous start, then hourly while today's summary is missing), or a
    **Run now** marker a person queued. Per-label stamps (`lastStarted`, `lastSucceeded`,
    `retryCount`) and per-profile outcomes live in `tick-state.json`, per Mac, in Application
    Support.
*   **Tiers and the guard.** Sources belong to one of three tiers (refresh 12 h, inventory 48 h,
    scan 7 days). An unforced collect fetches only sources past their tier's cadence. A collect of
    all three tiers is a full collect, and a second unforced full collect on one day is skipped
    (the once-a-day guard), except on a same-day retry.
*   **Budget stop.** A scheduled run asks `runStop` before each source; once it has held the lock for
    the budget, or a person asks for a refresh in the app, it stops and logs `[info] stopped early:
    <reason>; N sources left for the next run: <names>`. That line is not `[partial]`, so Run History
    reads the run as OK.
*   **Dead-man switch.** `AutomationHealth` reads each schedule's last calendar fire and its status
    file, and reports a schedule overdue when a fire passed with no run.

## The Problem

What is true today (2.12), from the code:

*   **The pickup ends after about seven hours.** After a budget stop the tick retries 1, 2 and 4
    hours after the previous start (`TickScheduler.retryBackoffs`). The hourly retries after those
    three run only while today's summary is missing (`TickScheduler.retryIsDue`). A stopped run
    almost always has today's summary, because 2.12 writes an early summary before the slow sources
    and `finalizeCollect` writes one at the end. So a fleet that needs five budget-length runs gets
    four at most, and the rest waits for the next day's fire.
*   **A planned stop spends the failure backoff.** `stoppedEarly` makes `retryCouldHelp` true
    (`CollectHonestyWatcher.retryCouldHelp(profile:)`), and each retry advances `retryCount`. A real
    failure later that day then has fewer, later retries left.
*   **Why a run stopped is lost.** `RunStop` tells a budget stop from a stop for a manual refresh,
    but the outcome the tick keeps records neither.
*   **Nothing shows progress.** The operator sees `stopped early` in a run log, not "18 of 31
    sources collected today, next pickup at about 10:05".
*   **The status pill lies.** The schedule list shows `.ok` for every schedule, whatever its last run
    did. Five places build a `Schedule` with `lastStatus: .ok` as a placeholder
    (`ManagedAutomation.makeSchedule`, `ScheduleRecord.toSchedule` in `ScheduleStore`,
    `Schedules.Add.record` in the CLI, `HeadlessRun.swift:773`, `SchedulesView.swift:884`), and
    nothing replaces the placeholder with the real outcome before the list is shown. The CLI's
    `schedules list` prints no status at all. The decision log left this for #421 on 2026-11-15.
*   **A manual refresh does not say which workspace it is for.** `ManualRefreshRequest` is one
    per-Mac file. Clicking Refresh on workspace A stops a scheduled run collecting workspace B, which
    is right (A's refresh cannot start until B's run gives the lock up), but nothing then tells B's
    leftovers apart from leftovers A's own refresh will collect.

What is not known: no log yet shows a healthy fleet (every source answering) running past 45
minutes. The one large-fleet report (5,923 Macs, 2.12 rc1) spent its hours in one source,
`patch-status`, timing out; 2.12's timeout hold, title-by-title walk and `collect_skip` answered
that, and the decision log (2026-11-18) records that every other source then collected near
instantly. The author's production server's slowest source took 24 seconds. So summary provenance,
report timing on a split day and shared-workspace continuation are only sketched (Future
Improvements) and wait on the measurement gate.

## Decisions

| # | Decision | Source |
|---|---|---|
| 1 | Retire the name "micro-refresh"; this is "Continue today's collect" (UI) and "split collect" (spec) | Tony, 2026-11-25 |
| 2 | A continuation runs at the next tick wake where the lock is free and nothing else is due; no fixed interval. This reverses the `retryBackoffs` note that "the tick alone never re-polls an on-prem server inside an hour" for a split day | Tony, 2026-11-25 (confirmed after review) |
| 3 | Shared workspace: the Mac that started the day finishes it; peers do not continue in this wave | Tony, 2026-11-25 |
| 4 | Reports on a split day are generated on time; marking them "sources still coming" waits on the measurement gate | Tony, 2026-11-25 |
| 5 | A `lateSources` summary field waits on the measurement gate | Tony, 2026-11-25 |
| 6 | No opt-in switch: lowering `run_budget_minutes` is the opt-in | Tony, 2026-11-25 |
| 7 | A manual refresh still stops whatever run holds the lock; the request names its workspace (scoping it to that workspace was rejected, Alternative I) | Tony, 2026-11-25 |
| 8 | Full scope after review: keep the progress card, counts, Continue now and the named request | Tony, 2026-11-25 |
| 9 | Jamf School continues (unforced); Protect-only does not | Tony, 2026-11-25 |

## Goals

1.  A scheduled run that stopped at its budget keeps getting continuations, at the next free tick
    wake, until every source due today has landed or local midnight, whichever is first.
2.  A continuation does not advance the failure retry count and is never turned into a retry. When
    a run both stopped at its budget and had a failed source, the failure rule (1, 2, 4 hour
    backoff) decides the next runs; once those are spent, continuations resume.
3.  A run stopped for a full manual refresh of the same workspace is not continued: that refresh
    collects everything due. A run stopped for any other refresh (another workspace, or a refresh of
    only some tiers) is continued like a budget stop.
4.  A continuation collects only what is still due today (unforced, Jamf School included), gets
    past the once-a-day full collect guard, and holds the lock at most for the budget plus one
    source.
5.  The Automation screen shows, per schedule with an open split day for the active workspace,
    "N of M sources collected today" (or "K sources left" when the counts no longer line up) and
    "next pickup within about five minutes, once the lock is free".
6.  "Continue now" on that line runs the same unforced continuation immediately, under the same
    lock and budget.
7.  The schedule list's status pill (GUI) and a STATUS column in `jamf-reports schedules list` show
    the last real outcome, plus "In progress" for an open split day with no failure.
8.  A manual refresh still stops whatever scheduled run holds the lock, between sources, as in
    2.12, and now names its workspace and whether it is a full refresh so the tick can apply goal 3.
9.  Protect-only workspaces get no continuation and keep today's retry.
10. A continuation never makes a schedule read as overdue, and never stands in for a missed fire.

## Non-Goals

*   No fourth `CollectionTier`, no fifth managed schedule kind, no new cadence string form.
*   No opt-in switch and no interval setting.
*   No light "micro" sources between collects (wave A's kinds or `overview` on an interval), and no
    capture of `pro inventory-information` or `pro health-check` for this wave.
*   No continuation across local midnight.
*   No continuation for Protect-only workspaces: a Protect-only collect has no cadence skip, so a
    run that lands nothing new reads as a dead run (large-fleet L4).
*   No continuation for the app's own automatic collects (background refresh, self-repair,
    catch-up), which also stop at the budget: the scheduled run they share data with continues.
*   No wider Automation customization (per-workspace run time, report template, formats, retries,
    per-schedule notifications). No one has asked for it.

## Open Questions

*   **Q1. Server load from back-to-back continuations.** With "next free wake", a fleet that needs
    five budget-length runs holds the lock for about four hours with five-minute gaps. Manual
    refreshes and other schedules still go first, but the Jamf Pro server sees a collect most of
    the morning. The measurement gate records lock time per day; if that is a problem on a real
    server, a floor between continuations is the fallback (a constant, not a setting).

## Critical User Journeys (CUJs)

### CUJ 1: A large fleet finishes its day in several runs

*   **Given**: Managed freshness at 06:00 on a Jamf Pro workspace whose collect needs about two
    hours; `run_budget_minutes` 45.
*   **When**: The 06:00 run stops at 06:45 and logs `[info] stopped early: run budget used (45
    minutes); 12 sources left for the next run: …`.
*   **Then**: The next tick wake with the lock free (within about five minutes) runs a continuation,
    unforced, collecting only what is still due; so do later wakes until every source has landed.
    The retry count stays 0. The Automation screen reads "19 of 31 sources collected today, next
    pickup within about five minutes, once the lock is free", and the schedule list's pill reads
    "In progress" until the day's plan is done, then OK. With `run_budget_minutes` 90 the
    continuations are two hours apart and are still continuations, never retries.

### CUJ 2: A small fleet sees no change

*   **Given**: A 500-Mac workspace whose collect finishes in 6 minutes.
*   **When**: Managed freshness runs.
*   **Then**: The run ends without a budget stop, no continuation is ever due, no progress line is
    shown, and the pill reads OK.

### CUJ 3: Refresh while a continuation runs

*   **Given**: A continuation is collecting workspace A; workspace B has no run.
*   **When**: The operator clicks Refresh (Collect now) on workspace A.
*   **Then**: The continuation stops at the next source boundary, the forced manual collect runs,
    and the tick does not continue A's stopped run. Clicking Refresh on workspace B instead also
    stops A's continuation (B cannot collect while A holds the lock), B's refresh runs, and A's
    split day carries on at the next free wake.

### CUJ 4: Continue now

*   **Given**: An open split day on workspace A.
*   **When**: The operator clicks "Continue now".
*   **Then**: The app queues a Run now for that schedule and spawns the tick (`TickRunner.spawnNow`,
    `wait: false`). The tick runs it as a continuation whatever else is due that wake: unforced,
    past the once-a-day guard, within the budget. Nothing already fresh is fetched again.

### CUJ 5: A real failure on a split day

*   **Given**: A run stops at its budget and `patch-status` also timed out in it.
*   **When**: The tick decides the next runs.
*   **Then**: The failure rule wins: retries 1, 2 and 4 hours after the previous start, each
    unforced, so each also collects the rest and counts against the backoff. Once those three are
    spent and the split day is still open, continuations resume at the next free wakes; the failing
    source stays on its own timeout hold or cadence, so it is not re-run every wake.

### CUJ 6: Jamf School

*   **Given**: A School workspace whose `jamf-cli-full` run (normally forced past School's 12-hour
    cadence) stops at the budget.
*   **When**: The tick decides the next run.
*   **Then**: A continuation runs unforced, so `planSchoolCollect` skips the sources that landed this
    morning and collects the rest; the School device scan keeps its one pass a day. A Protect-only
    workspace keeps today's retry.

## Technical Plan (Architecture)

### Where it sits

```text
 tick wake (every 300 s, takes the lock)
   └─ TickScheduler.due(...)                       pure
        ├─ fire / catchUp / retry   (retry never due on a clean open split day)
        ├─ runNow marker            (on an open split day: always .continuation)
        └─ continuation             NEW: only when nothing else is due this wake, at most one
   └─ TickLoop.runDue
        ├─ TickState.noteStarted(.continuation)    lastStarted = now, retryCount unchanged
        ├─ runSchedule(continuing:)  isSameDayRetry = true for .retry and .continuation
        │    └─ scheduledRunSingle(continuing:) → CollectRouter → collect (unforced, School too)
        │         ├─ runStop: budget | manual refresh (named workspace, full or not)
        │         └─ runProgress: planned names, left names, the typed RunStop
        │    └─ returns ScheduledRunResult { exitCode, protectOnly } + RunProgress
        └─ TickState.splitDay[label][profile] updated; continuation due again or closed
 app
   └─ refreshAutomationHealth (detached): TickState + newest Run History status per label
   └─ Automation screen / schedules view: SplitCollectCard (progress, Continue now)
   └─ schedule list pill ← scheduleStatuses
```

### 1. Recording why a run stopped and what is left

The engine already holds the typed stop (`RunStop`) and a task-local `runStop`. Beside it, a second
task-local `ReportEngine.runProgress` holds a `RunProgress` (a final class with a `Mutex`), set in
`stoppingBetweenSources(profile:)` and read back by `runSchedule` after the run:

*   `planned: Set<String>`: each product's planner adds the names it plans to collect this run (the
    Jamf Pro matrix and after-matrix sources, `device scan` when the scan is due, the School
    matrix, Protect, Security Cloud).
*   `left: Set<String>`: `stopsRun` replaces it with the names it logs as left.
*   `stop: RunStop?`: set by `stopsRun`.

The run log keeps its lines for people and Run History; nothing parses counts or reasons from log
text. `securityCollect` is fixed to pass `running[index...]` as left, not its whole list
(`ReportEngine+SecurityCloud.swift:75`), which is also wrong in its log line today.

`RunStop.manualRefresh` becomes `manualRefresh(sameWorkspaceFull: Bool)`. The outcome's stop is
`SplitStop` (in `TickScheduler.swift`): `budget`, `manualRefresh` (a full refresh of the same
workspace), `otherRefresh` (any other refresh).

`CollectHonestyWatcher` gains `failureRetryCouldHelp(profile:exitCode:since:)`: today's
`retryCouldHelp` without the `stoppedEarly` short-circuit. The existing `retryCouldHelp` keeps its
result (failure or stopped early) for every current caller, so Run History and the GUI are
unchanged.

### 2. Which stops are continued

`SplitCollect.isContinuable(stop:mode:protectOnly:)`: true when the stop is `budget` or
`otherRefresh`, the mode collects (`runsAtLoad`), and the workspace is not a confirmed Protect-only
environment. `protectOnly` comes from `scheduledRunSingle`, which already loads the routing config,
returned in `ScheduledRunResult { exitCode: Int32; protectOnly: Bool }`.

Jamf School is continuable. A continuation runs it unforced even for `jamf-cli-full`
(`scheduledRunSingle(continuing:)` passes `force: false` when `continuing` is non-empty), so the
12-hour cadence skips what landed earlier that day.

### 3. The continuation due rule

`TickScheduler.Reason` gains `.continuation`. `TickState` gains `splitDay: [String: SplitDay]`,
decoded under its own `try?` like `profileOutcomes`, so an unreadable entry costs nothing else.
`SplitDay` = `day` (local start of day of the run that opened it) and `profiles: [String:
ProfileProgress]` (a single-profile schedule uses the key `""`). `ProfileProgress` = `planned:
Set<String>` (the union over the day's runs), `left: Set<String>` (the newest run's), `failed:
Bool` (that profile's newest `failureRetryCouldHelp`), `lastFinished: Date`.

`TickLoop.runDue`, per run outcome, by case:

| Outcome | `splitDay` | Retry accounting |
|---|---|---|
| Clean finish (exit 0, nothing left) | profile removed; label removed when empty | `noteSucceeded` as today |
| Continuable stop, no failure | profile opened or updated, `failed` false | none: no `noteRetry`, `retryCount`, `retryWouldRepeat` and `lastSucceeded` unchanged |
| Continuable stop and a failure | profile updated, `failed` true | `noteRetry` as today |
| Failure, no stop | profile removed | `noteRetry` as today |
| Non-continuable stop (same-workspace full refresh, Protect-only) | profile removed | as today |

A fire or catch-up on a new day removes yesterday's `SplitDay`. A run's day is the local day of its
start time (`Calendar.startOfDay`), so a continuation that starts at 23:58 and finishes after
midnight updates the day it started in, which is then ignored.

In `TickScheduler.due`:

*   `retryIsDue` returns false for a label with an open `SplitDay` for today on which no profile has
    `failed`. So a continuation is never turned into a retry, whatever the budget.
*   After the existing pass, if nothing is due, the first schedule (existing run order) that is
    enabled, has a `SplitDay` for today, and either has no `failed` profile or `retryCount >=
    retryBackoffs.count` is due as `.continuation`, with `skipProfiles` = the profiles outside its
    `SplitDay`. At most one such continuation per wake.
*   A Run now marker on a label with an open `SplitDay` for today runs as `.continuation` whatever
    else is due, and does not count toward the one per wake.

`noteStarted(.continuation)` sets `lastStarted` and leaves `retryCount` and `profileOutcomes`
alone. The day is already paid by the fire or catch-up that opened it.

`TickEnvironment.perform` sets `ReportEngine.isSameDayRetry` for `.retry` and `.continuation` and
passes `DueRun.continuing` (the label's `SplitDay` profiles; empty otherwise) to
`runSchedule(_:verbose:skipping:continuing:)`. `runScheduleExclusively` passes empty.
`TickScheduler.runProfiles` logs "continuing only profiles with sources left" for a continuation.
`tickResultLine` writes ` continuation`. A continuation's run record logs, after the proxy lines,
`[info] continuing today's collect: N of M sources collected so far`.

This reverses the `retryBackoffs` comment ("the tick alone never re-polls an on-prem server inside
an hour") for a split day, by decision 2; the comment is updated to say so.

### 4. Manual refresh names its workspace

The tick lock covers the whole Mac, so any manual refresh still stops whatever scheduled run holds
it, between sources (no change). `ManualRefreshRequest.post(workspace:full:)` writes
`<timestamp>\n<workspace>\n<full|tiers>`. `ManualRefreshRequest.pending(now:appSupport:) ->
PendingRefresh`, `enum PendingRefresh { case none, unnamed, named(String, full: Bool) }`; `unnamed`
is a file with one line (an older app), read as a full refresh of the same workspace, the 2.12
behaviour. `isPending` keeps its signature on top of it.

`manualCollectMayStart(workspace:full:)` takes its target from each caller: Collect now and first
collect pass the active workspace with `full: true`; the tier and heavy-tier refreshes pass
`full: false`; the Add sheet and the existing-profiles setup pass the workspace they adopt. The
`runStop` closure compares the request with its own profile and sets `sameWorkspaceFull`.

### 5. Progress and Continue now

`refreshAutomationHealth`'s existing detached task also loads `TickState` and publishes, for the
active workspace, `WorkspaceStore.splitCollectRows` (a stored property, cleared on profile switch
and demo toggle), built by the pure `SplitCollectRow.rows(state:schedules:workspace:now:)`:

*   `SplitCollectRow { label, displayName, done, of, left, failed }`.
*   While `left ⊆ planned`: "N of M sources collected today" with M = `planned.count` and N = M −
    `left.count`. Otherwise "K sources left" (sources came due again after 12 hours). Never clamped.
*   "Next pickup within about five minutes, once the lock is free", or, when `failed` and the
    backoffs are not spent, "retrying after a failure".

It refreshes with the existing 30-minute re-check and after Continue now. "Continue now" calls
`TickRunner.spawnNow(label:wait: false)`; it is disabled while `isAnyCollectInFlight` or
`CLIBridge.tickLockHeldRecently()`, and in demo mode (`DemoData.liveOnlyHelp`).

### 6. The status pill reads the real outcome

One reader, `RunHistoryService.newestStatus(label:in:) -> (date: Date, status:
Schedule.LastStatus)?`, built on the existing per-log parse (`parseLogTail`, `isPartialRun`,
`ScheduledRunRecorder.startDate(fromLogName:)`), picks the newest log of a label by its name stamp.
`loadSchedules` stays pure. `refreshAutomationHealth`'s detached task fills
`WorkspaceStore.scheduleStatuses: [String: ScheduleStatus]` for the active workspace (a multi
schedule reads the active workspace's logs); `SchedulesView` and `AutomationView` show it instead of
the placeholder. `Schedule.LastStatus` gains `.inProgress` ("In progress", muted tone), returned
only when the newest run is not fail or partial and the active workspace has an open
`SplitDay` entry without `failed`. The five `.ok` literals stay as "not read yet" placeholders.

`jamf-reports schedules list` gains a STATUS column for hand-built records, from the same reader,
printed as `status.rawValue.uppercased()` (English, never through the catalog), through a static
`Schedules.List.line(for:status:)`; an all-profiles record reads the first runnable workspace.

### 7. Run History and the dead-man switch

Continuations write under the schedule's own label. `ScheduledRunRecorder` prunes per label
(`pruneRunLogs(in:keep:label:)`, already supported), keeping 50 per label, so continuations never
push out another schedule's history.

The overdue check is unchanged: a continuation is only due on a day a fire or catch-up already
started, so it can never stand in for a missed fire. Its later `finishedAt` only moves the status
file's date forward, which never makes a schedule read overdue. Tests pin both.

### 8. Shared workspaces

On a peer Mac nothing continues, because no `SplitDay` exists there (decision 3).

### 9. What a workspace gets

| Workspace | Budget stop | Progress line | Pill |
|---|---|---|---|
| Jamf Pro | continued at the next free wake until done or midnight | yes | In progress, then the real outcome |
| Jamf Pro with Protect | continued; Protect's planned and left names are in the counts | yes | same |
| Jamf School | continued, unforced | yes | same |
| Protect-only | today's retry (1, 2, 4 h) | none | real outcome |
| Any, collect finishes in budget | nothing to continue | none | real outcome |

### Measurement gate

What: lock time per day, continuations per day, `<kind>.took`, and whether a split day finishes
before midnight. Where: first `TickSimulation` with stand-in outcomes (reasons, run counts,
`retryCount`, midnight), then the NFR (Jamf partner) test server at `run_budget_minutes: 10`.
What it opens: a real fleet log showing `stopped early` on most days opens the Future Improvements;
lock time that keeps a server busy past the operators' working day opens the Q1 floor.

## Alternatives Considered

### Alternative A: Do nothing; measure first

*   **Pros**: Adds no mechanism for a case no healthy fleet has shown yet.
*   **Cons**: Leaves the pill reading OK after failed runs, and leaves a large fleet's budget stop
    with four pickups a day and spent failure retries.
*   **Reason for Rejection**: Rejected by author: the pill defect stands on its own, and the retry
    accounting is cheap to fix and test before a fleet hits it. Measurement still gates the Future
    Improvements.

### Alternative B: Planned slices at a fixed interval with a stored plan

*   **Pros**: Predictable pickup times on screen.
*   **Cons**: A new state machine beside the tick; a stored list of what is left drifts as
    refresh-tier sources come due again; invites an interval setting.
*   **Reason for Rejection**: Rejected by author: `planCollect` already derives what is left. The
    progress line stores only the names the run reported, and shows "K left" when they stop lining
    up rather than a drifting count.

### Alternative C: A fixed 60-minute gap between continuations

*   **Pros**: Keeps the "never re-poll within the hour" note; spreads server load.
*   **Cons**: A fleet needing five budget-length runs finishes about four hours later.
*   **Reason for Rejection**: Rejected by author (decision 2). Kept as the Q1 fallback.

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

*   **Pros**: Fresher tiles and alerts mid-day from small calls.
*   **Cons**: Adds lock time on every fleet to fix a cost no one has reported; the 2026-11-16
    concern was lock contention.
*   **Reason for Rejection**: Rejected by author (decision 1).

### Alternative G: Store progress in the workspace (like `device-scan.round`)

*   **Pros**: A peer Mac could see the progress.
*   **Cons**: Peer-writable state the tick would have to read as untrusted (review checklist #13).
*   **Reason for Rejection**: Rejected by author: progress is per Mac; peers do not continue.

### Alternative H: A wider Automation settings matrix

*   **Pros**: Per-workspace run time, report template and formats, retries and notifications.
*   **Cons**: Settings, pins and UI for a need no one has stated.
*   **Reason for Rejection**: Rejected by author: no one has asked for it.

### Alternative I: A manual refresh stops only its own workspace's run

*   **Pros**: Refreshing workspace A never interrupts workspace B's continuation.
*   **Cons**: The lock covers the whole Mac, so A's refresh would wait for B's run to reach its
    45-minute budget, longer than the 30 minutes the app waits, and could fail.
*   **Reason for Rejection**: Rejected by author (decision 7).

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Crash or kill mid-continuation | The start is stamped before the run; the `SplitDay` stays open; the next free wake continues |
| Unreadable `splitDay` in `tick-state.json` | Decoded under its own `try?`; reads as no split day, costs no other stamp |
| Midnight and DST | The run's start time decides its day (`Calendar.startOfDay`); a `SplitDay` from another day is ignored |
| A continuation that lands nothing (every left source fails) | Its profile is `failed`, so the retry backoff governs; after the backoffs, continuations resume with the failing source on its timeout hold |
| Server load all morning | Q1 and the measurement gate |
| A two- or three-line request file read by a 2.12 app | Reads as no request; low risk, since the app and the tick ship as one binary |

## Non-Functional Requirements

*   **Security & privacy**: All new state is per Mac in Application Support (`tick-state.json`, the
    refresh request file), never in a workspace a peer can write. The workspace name in the request
    is compared, never logged as path text.
*   **Lock time**: per workspace, a continuation holds the lock for the budget plus at most one
    source's `collectKindTimeout` (the budget is checked between sources). A multi-workspace
    schedule spends one budget per workspace.
*   **Rollout & rollback**: New `tick-state.json` fields are read leniently and ignored by a
    downgrade. `Schedule.LastStatus` is not persisted.

## Additional Resources

*   `docs/superpowers/specs/2026-11-17-large-fleet-design.md` (L2 item 4: budget and pickup; L4:
    Protect-only).
*   `docs/superpowers/review-checklist.md`.
*   Review record: `.dev/egm/consolidated_review_report.md` and `.dev/egm/goldfish_review_report.md`
    (local).

## Future Improvements (opened by the measurement gate)

*   `DailySummary.lateSources`: kinds that landed in a continuation, through `filling(from:)`,
    `freshSummaryIsBetter` and the rebuild.
*   Reports and webhook cards on an open split day say "sources still coming".
*   Shared workspace: continuations take the claim with `checkFreshness: false`; activity is stamped
    when the day's plan is done; a peer continues after the starting Mac's claim expires.
*   A floor between continuations, if Q1 shows server load.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Five phases, one commit each, all in one PR from `dev/wave-d-automation-bdab91` into
`dev/2-13-0`. Each commit builds, adds its own catalog keys with translations by hand (never
`sync-strings.zsh --prune-stale`, which emptied 861 entries in a fresh worktree; run it only as a
check), and passes the suite on its own. Test paths are under `app/Tests/JamfReportsTests/`.

### Phase 1: status pill reads the real outcome

#### 1. `app/Sources/JamfReports/Services/RunHistoryService.swift` (Modify)

*   `static func newestStatus(label: String, in logs: URL) -> (date: Date, status:
    Schedule.LastStatus)?`: lists the label's logs, picks the newest by
    `ScheduledRunRecorder.startDate(fromLogName:)`, and derives its status with the same parse
    `list` uses (ok, warn, fail, partial; a log with no footer held by a recorder is not counted,
    the previous one is used).

#### 2. `app/Sources/JamfReports/Services/WorkspaceStore.swift` (Modify)

*   Stored `scheduleStatuses: [String: ScheduleStatus]` (`ScheduleStatus { date: Date?; status:
    Schedule.LastStatus }`), cleared on profile switch and demo toggle. `loadSchedules` unchanged.

#### 3. `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` (Modify)

*   `refreshAutomationHealth`'s detached task fills `scheduleStatuses` for the active workspace's
    `runHistoryDir` and each schedule label.

#### 4. `app/Sources/JamfReports/Views/SchedulesView.swift`, `Views/AutomationView.swift` (Modify)

*   The Last Run and Status columns read `scheduleStatuses[label]`, falling back to the schedule's
    own fields.

#### 5. `app/Sources/JamfReports/CLI/ScheduleCommands.swift` (Modify)

*   `Schedules.List` gains `static func line(for record: ScheduleRecord, status:
    Schedule.LastStatus?) -> String`, adding a STATUS column after MODE
    (`status?.rawValue.uppercased() ?? "-"`); `run()` reads `RunHistoryService.newestStatus` for the
    record's workspace (an all-profiles record: the first runnable workspace).

#### 6. Tests

*   `RunHistoryServiceTests.swift` (Modify): `newestStatus` for fail, partial, refused (warn), none,
    and a running newest log falling back to the previous one.
*   `ScheduleCommandsTests.swift` (Modify): `line(for:status:)` prints FAIL; `-` with no log.
*   `AutomationHealthTests.swift` (Modify): `scheduleStatuses` filled off the main actor for the
    active workspace.

### Phase 2: the run records why it stopped and what is left

#### 7. `app/Sources/JamfReports/Engine/ReportEngine+CollectPlan.swift` (Modify)

*   `RunStop.manualRefresh` → `manualRefresh(sameWorkspaceFull: Bool)`; `evaluate` takes
    `pending: PendingRefresh` and `profile`. New task-local `runProgress: RunProgress?` and
    `final class RunProgress: Sendable` (`Mutex` of `planned`, `left`, `stop`), set in
    `stoppingBetweenSources`. `stopsRun` writes `left` and `stop`. `planCollect`'s caller,
    `planSchoolCollect`'s caller and the device-scan plan add their planned names.

#### 8. `app/Sources/JamfReports/Engine/ReportEngine+SecurityCloud.swift` (Modify)

*   Pass `running[index...]` as `left` to `stopsRun`; add Security Cloud's planned names.

#### 9. `app/Sources/JamfReports/Engine/ReportEngine.swift` (`protectCollect`, `schoolCollect`) (Modify)

*   Add Protect's and School's planned names to `runProgress`.

#### 10. `app/Sources/JamfReports/Services/ManualRefreshRequest.swift` (Modify)

*   `post(workspace: String? = nil, full: Bool = true, now:appSupport:)` writes up to three lines;
    `pending(now:appSupport:) -> PendingRefresh`; `isPending` on top of it.

#### 11. `app/Sources/JamfReports/Services/WorkspaceStore+Refresh.swift`, `Views/AddSheet.swift`, `Views/ExistingCLISetupView.swift` (Modify)

*   `manualCollectMayStart(workspace:full:)`; each of the five callers passes its real target
    (Collect now and first collect `full: true`; tier and heavy-tier refreshes `full: false`; the
    Add sheet and the setup flow their adopted workspace, `full: true`).

#### 12. `app/Sources/JamfReports/Services/ScheduledRunSignals.swift` (Modify)

*   `CollectHonestyWatcher.failureRetryCouldHelp(profile:exitCode:since:)`.

#### 13. `app/Sources/JamfReports/Services/TickScheduler.swift` (Modify, part 1)

*   `enum SplitStop: String, Codable { case budget, manualRefresh = "manual_refresh", otherRefresh =
    "other_refresh" }`. `ProfileOutcome` gains `stop: SplitStop?`, `failureRetryCouldHelp: Bool`,
    `planned: [String]`, `left: [String]` (keys `stop`, `failure_retry_could_help`, `planned`,
    `left`, all `decodeIfPresent`, defaulting to nil, `retryCouldHelp`, empty, empty) and an
    explicit `init` with those defaults. `ScheduleRunOutcome` gains the same for a single-profile
    run; `init(over:ran:considered:)` sets the failure verdict to any profile's and keeps stops per
    profile.

#### 14. `app/Sources/JamfReports/Services/SplitCollect.swift` (Create)

*   `enum SplitCollect { static func isContinuable(stop: SplitStop?, mode: Schedule.RunMode,
    protectOnly: Bool) -> Bool }`.

#### 15. `app/Sources/JamfReports/App/HeadlessRun.swift` (Modify)

*   `scheduledRunSingle` returns `ScheduledRunResult { exitCode; protectOnly }` from the routing
    config it already loads, runs inside a fresh `runProgress`, and returns it. `runSchedule` builds
    the outcome's `stop` (nil unless `isContinuable`), `failureRetryCouldHelp`, `planned` and `left`.

#### 16. Tests

*   `RunStopTests.swift` (Modify): `PendingRefresh` cases; same-workspace full, other workspace,
    tier refresh, unnamed.
*   `DeviceScanCollectTests.swift:1164`, `DeviceScanPassesTests.swift:215`,
    `PatchByTitleTests.swift:254` (Modify): `.manualRefresh(sameWorkspaceFull: true)`.
*   `CollectPlanTests.swift` (Modify): `runProgress` planned and left after a budget stop, Pro plus
    Protect names; the device scan counted only when due.
*   `SecurityCloudCollectTests.swift` (Modify): left after a
    mid-way stop is the remainder.
*   `CollectHonestyTests.swift` (Modify): `failureRetryCouldHelp` false for a clean budget stop,
    true with a `[partial]` source line.
*   `SplitCollectTests.swift` (Create): continuable for Pro and School budget and other-refresh
    stops; not for Protect-only, a same-workspace full refresh, or `jamf-cli-only`.
*   `TickProfileOutcomeTests.swift` (Modify): an older `tick-state.json` decodes; new keys round-trip.

### Phase 3: the continuation due rule

#### 17. `app/Sources/JamfReports/Services/TickScheduler.swift` (Modify, part 2)

*   `Reason.continuation`. `TickState.splitDay` with `SplitDay` and `SplitDay.ProfileProgress` as in
    section 3, decoded under its own `try?`. `noteStarted(.continuation)`. `noteSplitDay(_:outcome:
    reason:now:) -> Bool` per the section 3 table. `retryIsDue` guard. The continuation pick and the
    Run now rule in `due`. `DueRun.continuing`. `runProfiles` log wording. `retryBackoffs` comment
    updated (decision 2).

#### 18. `app/Sources/JamfReports/App/Tick.swift` (Modify)

*   `perform` sets `isSameDayRetry` for `.continuation` and passes `continuing`. `runDue` applies the
    section 3 table. `tickResultLine` writes ` continuation`. `runScheduleExclusively` passes empty.

#### 19. `app/Sources/JamfReports/App/HeadlessRun.swift` (Modify)

*   `runSchedule(_:verbose:skipping:continuing:)` and `scheduledRunSingle(continuing:)`: unforced
    when continuing (School `jamf-cli-full` included); the "continuing today's collect" line after
    the proxy lines.

#### 20. `app/Sources/JamfReports/Models/Models.swift`, `Views/SchedulesView.swift`, `Views/RunsView.swift` (Modify)

*   `Schedule.LastStatus.inProgress` ("Last run status: In progress"); both `statusPill(for:)`
    switches (`L("IN PROGRESS")`, `.muted`, `arrow.triangle.2.circlepath`). `scheduleStatuses`
    returns `.inProgress` per section 6.

#### 21. `app/Sources/JamfReports/Services/ScheduledRunRecorder.swift` (Modify)

*   Prune per label: `pruneRunLogs(in:keep: maxRunLogs, label: label)`.

#### 22. Tests

*   `TickSchedulerContinuationTests.swift` (Create): due only when nothing else is due; one per wake;
    not after midnight; not while `failed` until the backoffs are spent, then yes; a Run now on an
    open split day is `.continuation` with other schedules due; `retryIsDue` false on a clean open
    split day at a 90-minute gap; a disabled schedule does not continue.
*   `TickLoopTests.swift` (Modify): each row of the section 3 table; School `jamf-cli-full`
    continuation runs unforced.
*   `TickSchedulerMissingSummaryTests.swift` (Modify): a budget-stop pickup no longer depends on
    `summaryMissing`.
*   `AutomationHealthTests.swift` (Modify): an open split day never reads overdue; a due pass with no
    fire today returns no `.continuation`.
*   `SchoolCollectPlanTests.swift` (Modify): a continuation skips sources landed this morning.
*   `ScheduledRunRecorderTests.swift` (Modify): pruning keeps 50 per
    label.
*   `ArtifactsViewPolishTests.swift` (Modify): the `LastStatus` switch at line 131 gains
    `.inProgress`.
*   `LocalizationCatalogTests.swift` (Modify): add IN PROGRESS to
    `japaneseStatusPillsAreTranslated`.
*   `TickSimulation.swift` (Modify): stand-in outcomes with `stop`, `failed` and left names; a day of
    wakes checks reasons, runs per day, `retryCount` and the midnight cut.

### Phase 4: progress card and Continue now — DRAFT, needs visual verification

#### 23. `app/Sources/JamfReports/Views/SplitCollectCard.swift` (Create)

*   `SplitCollectRow` and `rows(state:schedules:workspace:now:)` (pure), and the card: per row the
    progress text, the pickup text and "Continue now" (`TickRunner.spawnNow(label:wait: false)`),
    disabled per section 5. Hidden with no rows.

#### 24. `app/Sources/JamfReports/Services/WorkspaceStore.swift`, `WorkspaceStore+Automation.swift` (Modify)

*   Stored `splitCollectRows`, cleared on profile switch and demo toggle; filled in
    `refreshAutomationHealth`; refreshed after Continue now.

#### 25. `app/Sources/JamfReports/Views/AutomationView.swift`, `Views/SchedulesView.swift` (Modify)

*   `AutomationView`: the card under `HealthCard`. `SchedulesView`: above the schedules table.

#### 26. `app/Localization/Localizable.xcstrings` (Modify)

*   The card's strings, translated into every shipped language per `app/Localization/glossary.md`,
    by hand.

#### 27. Tests

*   `SplitCollectCardTests.swift` (Create): rows from a `TickState` fixture ("N of M", "K left",
    retrying text); demo mode disabled.

### Phase 5: docs and change notes

#### 28. `CHANGELOG.md` (Modify)

*   Unreleased: Changed (a run stopped at its budget is continued through the day, Jamf School
    included; the schedule list shows each schedule's real last outcome; `schedules list` has a
    STATUS column; Run History keeps 50 runs per schedule), Added (progress line and Continue now),
    Fixed (Security Cloud's stopped-early line listed every source as left).

#### 29. `docs/wiki/05-Scheduling-and-Automation.md` (Modify)

*   How a large fleet's collect is split, what Jamf School and Protect-only do, and that lowering
    `run_budget_minutes` is the opt-in.

#### 30. `config.example.yaml` (Modify)

*   Comment on `jamf_cli.run_budget_minutes`: a run stopped at the budget is continued later the
    same day; lower it to spread a collect over smaller runs.

#### 31. `CLAUDE.md` and `AGENTS.md` (Modify, kept in sync)

*   The `TickScheduler` row and the "Stopping between sources" paragraph describe `.continuation`,
    `SplitDay`, `runProgress` and the named refresh request; the `ScheduledRunRecorder` row says
    per-label pruning.

#### 32. `docs/superpowers/specs/2026-11-25-split-collect-design.md` and `docs/superpowers/specs/2026-11-17-large-fleet-design.md` (Modify)

*   Status to Approved; one forward-pointer line in the large-fleet spec's L2 item 4.

### Verification Plan

*   **Build**: `cd app && swift build --build-tests` after each phase.
*   **Tests**: full suite through the `tip-test` skill on the PR head; the Swift 6.1 floor in the
    `ci-macos15-xcode16.4` VM through `vm-test`.
*   **Lint**: `xcrun swift-format lint` on touched files as a hint; `LocalizationCatalogTests`.
*   **Measurement gate**: as in the Technical Plan.
*   **Visual**: phase 4 is marked DRAFT; render `SplitCollectCard` previews at
    `PageScaffold.minSupportedWidth` for Tony's pass.

--------------------------------------------------------------------------------

*Drafted with EGM*
