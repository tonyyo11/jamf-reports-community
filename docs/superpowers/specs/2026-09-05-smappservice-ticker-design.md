# One app-owned ticker: moving scheduling off `~/Library/LaunchAgents`

Status: design approved in conversation 2026-09-05, awaiting spec review.
Target release: 2.9.0, branched off main after 2.8.0 ships.

## Problem

Every schedule the app runs today is a legacy LaunchAgent plist in
`~/Library/LaunchAgents`, written by the copy of the app that happened to be
running. Three consequences were observed on real machines:

- Background Task Management registers each plist as a separate "legacy agent"
  item attributed to the developer. Every time the binary behind one changes
  (a beta pkg install, a rebuild of a scratch copy) macOS re-registers the item
  and posts "Software from Anthony Young can run in the background". On a dev
  Mac the developer item reached generation 164.
- An agent stays pinned to the bundle path that wrote it. Two managed agents
  were found pointing at a build scratch folder. 2.8.0 adds the executable path
  to the reconcile signature and a location warning; that is a mitigation, not a
  fix — the plist mechanism itself is the problem.
- Two scheduling mechanisms coexist: the managed policy (four reserved agents)
  and hand-built per-profile schedules. Fourteen source files read the plist
  mechanism; the deferred Phase 6 consolidation never happened.

## Decisions taken

| Question | Decision |
|---|---|
| Scope | Both managed and hand-built schedules, one design. |
| Fire-time tolerance | Up to 5 minutes late. |
| Existing plists | Import, then ask before removing. |
| Schedule records | Per machine, in Application Support — never in the workspace, which may be a synced team folder. |
| Mechanism | One `SMAppService.agent` ticker shipped in the bundle. |

Rejected: one static bundled plist per managed kind (cannot express a
user-chosen minute or any hand-built schedule; four Login Items rows); a login
item with the GUI resident (the headless remote box never has the GUI open).

## 1. Schedule store and the tick loop

**Sources of truth.** Managed schedules are derived from `AutomationPolicy` on
every tick, exactly as `ManagedAutomation.desiredSchedules` does today, and are
never stored. Hand-built schedules are records in
`~/Library/Application Support/JamfReports/schedules.json`, one per schedule:
`label`, `profile` (or all-profiles plus `excludedProfiles`), `mode`, `tiers`,
`schedule` (the existing cadence string), `enabled`. Decoding is lenient
(`decodeIfPresent`, the `AutomationPolicy` pattern) so a new field never wipes
the file. `Schedule` stays the model the views render.

**Due.** A schedule is due when its most recent calendar fire time is later
than its last recorded run start. The fire time comes from
`LaunchAgentService.lastScheduledFireDate` (the backward-stepping matcher the
dead-man switch already uses, 35-day cap); the last run start comes from the
per-label status file `ScheduledRunRecorder` writes. There is no last-tick
clock. A missed fire (sleep, logged out) fires once, never N times.

The `runsAtLoad` distinction survives as a rule: modes that run at load today
(`snapshot-only`, `jamf-cli-full`, `csv-assisted`) may catch up from any missed
fire; `jamf-cli-only` and `backup` run only when the missed fire is within the
last 15 minutes.

**The tick.** `JamfReports --tick`, launched by the bundled agent every 300 s
and at login:

1. Take `~/Library/Application Support/JamfReports/.tick.lock` containing this
   pid. If the file exists and its pid is alive, exit 0 immediately — a
   20-minute collect is never overlapped by the next wake.
2. Load the policy and the store, evaluate every schedule.
3. Run due schedules sequentially, in the managed order
   freshness → scan → reports → backup then hand-built by label, through the
   existing `--scheduled-run` body with the schedule's label, so the recorder,
   logs, webhooks and alerts behave exactly as now. The `+0/+10/+20/+30`
   stagger becomes ordering within one tick.
4. Release the lock, exit.

A wake with nothing due is one JSON read and one status-file stat per
schedule.

**Deleted.** `JRC_WORKSPACES_ROOT` in plists (the tick reads the same
preference the GUI does); `WorkingDirectory`, `StandardOutPath`,
`StandardErrorPath` (the recorder owns logs); the `managedRunAtLoadMigratedV1`
flag; `ManagedAutomation.reconcile`, `plan`, the signature and
`invalidateManagedPlists`.

## 2. Migration and consolidation

**Registration.** On every launch (GUI or included CLI) the app calls
`SMAppService.agent(plistName:
"com.github.tonyyo11.jamf-reports-community.tick.plist").register()`. The call
is idempotent and is what re-binds the item after the app is moved or replaced
by a pkg. macOS posts its one-time "Background Items Added" notification and
shows one "JamfReports" row under Login Items › Allow in the Background.
`status` is read on every launch: `.requiresApproval` means the operator turned
it off there; the Automation screen says so with a button calling
`SMAppService.openSystemSettingsLoginItems()`. A disabled ticker is the single
failure mode, and it is visible in Settings.

**Import.** On the first launch of the new version, every JRC plist in
`~/Library/LaunchAgents` is read through `LaunchAgentService.parse`. Managed
labels (`ManagedAutomation.owns`) are skipped — the policy describes them.
Every other label becomes a store record with the same label, so Run History
and the dead-man switch see contiguous history. A plist that fails to parse is
reported by name and left untouched. Import is a pure function over `[Schedule]`
plus the list of unparseable URLs.

**Ask before removing.** Imported plists stay loaded. The Automation screen's
consolidation card lists them under "Schedules now run by JamfReports" with a
checklist and its existing confirm dialog. Confirming boots them out and
archives them to `<workspacesRoot>/_archived-launchagents` with the existing
secret-scrubbing copy. Until confirmed an imported schedule runs twice per
fire, once from launchd and once from the tick; the card states that. The
exception is the managed plists: the policy owns them, so the first launch
boots them out and archives them without asking, as a policy edit already
replaces them.

**Rollback.** A downgrade restores nothing automatically; the archived plists
are the rollback. `SMAppService.unregister()` runs when the master toggle goes
off with no hand-built schedules left, so a machine with automation fully off
has no background item.

## 3. Dead-man switch, Run History, Run now, CLI

**Dead-man switch.** `AutomationHealth.evaluate` keeps its inputs; the source
of `ScheduleHealthInput` becomes the same list the tick evaluates. One new
input, `tickerStatus`: `.requiresApproval` or `.notRegistered` collapses every
schedule into a single "background item disabled" issue with the Login Items
button as its action, because the cause is one switch. The overdue webhook
digest carries the same single fact.

**Run History.** Unchanged. The tick runs the `--scheduled-run` body with the
schedule's label; `ScheduledRunRecorder` writes the same files. The legacy
`.out.log`/`.err.log` readers stay one further release.

**Run now.** Writes a one-shot marker `automation/.run-now/<label>` and spawns
`JamfReports --tick --now <label>` detached. The run happens at once, under the
same lock, through the same recorder, and works even when the ticker is
disabled. If another run holds the lock the marker is consumed by the next
wake instead of being lost.

**Included CLI.** `--scheduled-run` remains the internal body and the entry
point for an external scheduler (the wiki's self-written-cron caveats still
apply to it). `jamf-reports schedules list|add|remove|run` edits and runs the
store — the first time hand-built schedules are scriptable. `--tick` is the
agent's entry point, not a documented subcommand.

**Multi-machine.** The shared-workspace claim and freshness gate are untouched;
each Mac keeps its own ticker and store.

## 4. Bundle, signing, build, tests, rollout

**Bundle.** One file at
`JamfReports.app/Contents/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist`:

```xml
Label            com.github.tonyyo11.jamf-reports-community.tick
BundleProgram    Contents/MacOS/JamfReports
ProgramArguments [JamfReports, --tick]
StartInterval    300
RunAtLoad        true
ProcessType      Background
```

`build-app.sh` gains the `mkdir -p` and copy; the existing `codesign --deep`
signs it with the bundle, so notarization, `build-pkg.sh` and `package-dmg.sh`
are unchanged. No new entitlement. macOS 15 floor (2.8.0) already exceeds
`SMAppService`'s macOS 13 requirement.

**Dev builds.** `swift run` has no bundle: registration is skipped with a log
line and the Automation screen shows "ticker unavailable in this build".
`JamfReports --tick` runs from any binary, which is how a developer tests
scheduling. The 2.8.0 "not in an Applications folder" banner stays.

**Tests.** The tick decision is a pure function over (schedules, last runs,
now): due at the exact fire; one catch-up after a gap; the 15-minute rule for
non-catch-up modes; disabled schedules never due; `--now` marker wins over the
calendar. Store round-trip with a lenient decode. Import drops managed labels
and reports unparseable files. Lock: dead pid is taken over, live pid exits.
Registration goes behind a `TickerRegistrar` protocol (`register`, `status`,
`unregister`, `openLoginItems`) so the tick loop and health inputs run against
a stub; the real `SMAppService` is exercised by a beta on a Mac. That beta is
the acceptance test: one Login Items row; no Background Activity notification
on the next pkg install; a 06:20 schedule started by 06:25; a schedule imported
from a hand-built plist appears on the Schedules screen and in the
consolidation card.

**Deleted with this change.** `LaunchAgentWriter`'s plist generation and
`launchctl` bootstrap/bootout; `LaunchAgentService.kickstartNow`;
`reconcileManagedAutomationHeadless` in `main.swift`;
`ScheduleConsolidation`'s duplicate detection (the card is reused for the
import list); the 2.8.0 executable-path signature and `bundleLocationWarning`'s
doctor row (the banner stays). `LaunchAgentService` shrinks to `parse` for
import, `lastScheduledFireDate`, and the archive helper.

**Rollout.** 2.9.0 headline. One release carries the import-then-confirm flow.
Legacy log readers survive one more release, then go.

## Out of scope

- Per-schedule log files outside the recorder (nothing reads them).
- Sharing schedules between machines through the workspace.
- Any change to the shared-workspace claim, freshness gate, or the included
  CLI's `collect`/`generate` behaviour.
