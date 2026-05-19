# ADR PR-22+: Per-report tiered collection with screen-driven defaults

**Status:** Draft (pending review)
**Authors:** Tony Young + Claude (drafted 2026-05-18 session)
**Date:** 2026-05-18

---

## Context

The reference Python/zsh deployment at
`~/Documents/Mac_Engineering/Jamf Reports/jamf-cli-data/collect.zsh`
schedules jamf-cli commands at **per-report cadences**:

- **Daily** (every 86400 s): `overview`, `policy-status`
- **Weekly** (every 604800 s): `security`, `patch-status`, `app-status`
- **Biweekly** (1st/15th of month, before 10 AM): `policy-status --scan-failures`
- **Excluded forever**: `update-status`, `profile-status` (kill the on-prem
  Jamf Pro server with memory exhaustion / per-device enumeration cost)

Mechanics: a single LaunchAgent fires daily at 07:00; `collect.zsh` checks
per-report `state/<report>.last` files and skips anything not due. 30 s
sleep between calls; rotation keeps newest 30 JSON files per directory.

The Swift app's `ReportEngine.collect` runs the **full command set every
time** — 20+ jamf-cli commands in sequence, no pacing, no per-report
gating. Today's controls:

| Knob | Granularity | Where set |
|------|-------------|-----------|
| `jamf_cli.collect_skip` (PR-16) | Per-report, binary (skip yes/no, global) | `config.yaml` |
| Settings "Skip expensive collections" | Drops 4 commands from **manual** GUI refreshes only | UserDefault |
| Schedule cadence | Per-schedule (daily/weekly/etc.) — each schedule still does a full collect | Schedules form |

The Swift app also has tier scaffolding from prior work — `ScheduleTier`
(`hot`/`warm`/`cold` at 15 min / 4 h / 24 h), `TieredLaunchAgentWriter`,
`RefreshCoordinator`, `RefreshPolicy`. But:

1. The tiers represent **whole-collection cadences**, not per-report cadences. Every tier calls the same `bridge.collect(profile:)` which runs ALL commands.
2. `TieredLaunchAgentWriter` has **zero callers in any View** — it's
   scaffolding without wiring (flagged in this branch's anti-churn
   guardrails as a pattern to avoid).
3. `RefreshCoordinator` is wired only for the sidebar profile-switch
   debounce; it does not coordinate scheduled background collection.

So the user gap is real: there is no way in today's GUI to express
"refresh `overview` hourly, refresh `security` daily, refresh
`patch-device-failures` weekly, never run `update-status` against this
on-prem server."

The intent — articulated by Tony in the 2026-05-18 review — is **not**
1:1 parity with `collect.zsh`. It is:

> *"the app should be able to keep historical data, regularly
> download/record that historical data, and present as much up to date
> data as it can without overloading the servers with a full blown
> export and thousands of API calls scanning potentially thousands of
> devices."*

And the configuration must be **GUI-first**: users on the app should
never have to hand-edit `config.yaml` to express this.

## Goals / Non-goals

**Goals:**

- Per-report-type cadence in the Swift engine — different reports can
  refresh at different intervals.
- GUI-first configuration — Schedules form gains the controls; `config.yaml`
  is generated, not hand-edited.
- Sensible defaults based on tenant type (on-prem vs cloud) so a fresh
  install does the right thing without tuning.
- Extend `snapshot-only` so it grabs the small set of commands the
  Overview screen needs — keeps the Overview fresh between full runs
  without requiring a workbook generation.
- Preserve the Trends-recording discipline (`summary.json` writes) added
  in PR-20.
- Migrate `jamf_cli.collect_skip` cleanly — users with it set today get
  identical behavior on upgrade.

**Non-goals:**

- 1:1 `collect.zsh` parity. We will NOT initially port: time-of-day
  gating ("only run failures before 10 AM"), day-of-month gating
  ("only on 1st/15th"), or the 30 s inter-call pacing. Each is a
  defensible v2 feature; none is load-bearing for the goal.
- New jamf-cli capabilities. This ADR wraps what jamf-cli already
  exposes — it does not add new subcommands or flags upstream.
- Backwards compatibility with the legacy `collect_skip` shape beyond
  a one-time migration. Per CLAUDE.md: "Replace, don't deprecate."

## Decision

### Three screen-driven tiers

Tiers are named after **what they keep fresh**, not abstract cadences.
Each report belongs to exactly one tier.

| Tier | Purpose | Default cadence | Reports (initial set) |
|------|---------|------------------|------------------------|
| **Refresh** | Overview KPIs + Trends summary stay current | every 1 h (cloud) / 4 h (on-prem) | `overview`, `security`, `inventory-summary`, `patch-status` (summary only), `policy-status` |
| **Inventory** | Deep Dive screens (Policies, Profiles, Apps, Mobile) stay current | daily | `app-status`, `classic-macos-profiles`, `classic-ios-profiles`, `mobile-devices-list`, `computers`, `policies`, `scripts`, `packages`, `smart-computer-groups`, `categories`, `sites`, `buildings`, `departments`, `computer-extension-attributes`, `software-installs` |
| **Scan** | Full per-device accuracy: Risk Score, Compliance Bands, Patch Failures, Update Failures | weekly | `ea-results --all`, `device-compliance`, `patch-status --scan-failures`, `update-status --scan-failures`, `profile-status`, `mobile-device-inventory-details` |

Three tiers, not four, because:
- Two is too few (everything is either "all the time" or "weekly" —
  doesn't reflect that the Overview screen wants hourly summaries but
  the Patch Failures table is fine weekly).
- Four (the user's collect.zsh has overview-only / daily / weekly /
  biweekly) over-specifies for a GUI surface. Biweekly is a special
  case of weekly with extra gating; we collapse it into weekly and
  defer time-of-day gating to a follow-up.

### `snapshot-only` narrows to Refresh tier

**Today:** `snapshot-only` runs the full collect (20+ commands) plus
emits the summary. Slow on on-prem; overkill for the mode's intent.

**PR-22:** `snapshot-only` runs ONLY the Refresh tier (5-6 commands)
plus emits the summary. Fast, safe to run hourly, keeps the Overview
and Trends current without touching expensive per-device endpoints.

This is the answer to "should snapshot-only get extended a little to
keep Overview fresh?" — it already runs *too much*; the right move is
narrowing it to "just enough."

Migration impact: on-prem users get a strict win (fewer API calls).
Cloud users who relied on snapshot-only as "fresh everything" will see
the Patch / Updates / EA dashboards lag until the Inventory or Scan
tier runs. The Schedules form should default a fresh install to:
- 1× snapshot-only daily (covers Refresh tier)
- 1× jamf-cli-full weekly (covers Inventory + Scan)

so a single-schedule user out of the box gets the right behavior.

### Mode → tier-set mapping

The four `Schedule.RunMode` cases gain a default tier-set, but the user
can override per-schedule in the form. Defaults:

| Mode | Default tier set | Override available? |
|------|------------------|----------------------|
| `snapshot-only` | Refresh | Yes — add Inventory and/or Scan |
| `jamf-cli-only` | (no collect — generates from whatever is cached) | N/A |
| `jamf-cli-full` | Refresh + Inventory + Scan | Yes — drop any tier |
| `csv-assisted` | Refresh + Inventory + Scan + CSV | Yes — drop any tier |

`jamf-cli-only` is unaffected because by definition it does no collect.
The other three default to whatever is most useful for the mode's
stated purpose.

### Server-load presets

In Settings → Performance (new pane), three presets:

| Preset | Refresh cadence | Inventory | Scan | Pacing | Hard exclusions |
|--------|------------------|-----------|------|--------|------------------|
| **On-prem (conservative)** | 4 h | daily | weekly | 15 s | `update-status`, `update-device-failures` |
| **Cloud (aggressive)** | 1 h | every 12 h | every 3 days | 0 s | none |
| **Custom** | — | — | — | — | — (exposes raw per-report table) |

The preset is per-profile (a single workspace may have one cloud and
one on-prem profile). First-launch onboarding prompts the user to pick
a preset per profile. Existing profiles that have `collect_skip:
[update-status, ...]` set auto-pick **On-prem** on migration.

The Custom mode exposes a per-report cadence editor for the small
audience that wants `collect.zsh`-level granularity.

### Engine model — state files and `is_due()`

`<workspace>/jamf-cli-data/state/<report>.last` holds a Unix epoch
timestamp of the last successful fetch (mirrors `collect.zsh`'s
mechanism, deliberately). On every `ReportEngine.collect` invocation:

```
for each report in <profile's resolved tier set>:
    cadence = resolveCadence(report, profile)
    if cadence == .never: skip
    if isDue(report, cadence): fetch; on success update state file
    else: log "[skip] <report> not due (last: <ts>, due in <duration>)"
sleep(pacing) between fetches
```

Pacing defaults to 0 s for cloud, 15 s for on-prem (via preset). The
preset's `pace_seconds` is what `_run_jamfcli_to_file`'s 30 s in
`collect.zsh` becomes — same intent, configurable.

State files are per-profile (under the workspace's `jamf-cli-data/state/`).
No global state.

### Generated `config.yaml` schema

The GUI writes; the user does not edit. Shape:

```yaml
collect_cadence:
  preset: on-prem            # on-prem | cloud | custom
  pace_seconds: 15           # honored regardless of preset
  per_report:                # only populated for custom + overrides
    update-status: never     # the "kill switch"
    overview: { tier: refresh, cadence: 3600 }
    security: { tier: refresh, cadence: 7200 }
    patch-device-failures: { tier: scan, cadence: 604800 }
```

For `preset: on-prem | cloud`, the engine resolves cadences from the
preset's defaults; `per_report` is purely overrides. For `preset:
custom`, the engine requires every report to have an entry.

`jamf_cli.collect_skip` (PR-16) is migrated automatically: on first
GUI save after upgrade, each entry becomes
`per_report: <name>: never` and the legacy key is removed. The
in-memory model already supports both during the migration window;
post-PR-22 the legacy key is no longer read.

## Open questions

### Q1: In-app coordinator vs LaunchAgent — who owns cadence?

LaunchAgents fire on their own cadence regardless of whether the app
is open. The in-app `RefreshCoordinator` fires while the app is open
based on staleness checks. With per-report cadences, both could
contend.

**Proposed answer:** LaunchAgent is the source of truth for scheduled
recurring refreshes. `RefreshCoordinator` becomes a "backfill if
overdue" mechanism — when the app opens, it checks per-report state
files and triggers a refresh for any report whose `last` timestamp is
older than its cadence × 1.5. No periodic in-app polling. Avoids the
double-refresh that today's `RefreshCoordinator` already coalesces.

### Q2: Should `TieredLaunchAgentWriter` be wired or deleted?

The existing class writes one LaunchAgent per profile per tier
(`hot`/`warm`/`cold`) with `StartInterval` driven by the tier. After
PR-22 this concept changes — tiers are per-report, not per-cadence.

**Proposed answer:** Delete `TieredLaunchAgentWriter` and the
`ScheduleTier.hot/warm/cold` enum. `RefreshCoordinator` keeps a
simplified tier concept (Refresh / Inventory / Scan, matching the new
model). Per CLAUDE.md: "Replace, don't deprecate" — no backwards
shim. The class has zero callers in any View; the only consumer is
the `RefreshCoordinator` profile-switch debounce, which can switch
to "trigger Refresh tier" with no behavioral change.

### Q3: Time-of-day gating — defer or include?

`collect.zsh` runs failure scans only on 1st/15th and only before 10 AM.
GUI translation is awkward ("Schedules form runs at fixed time; how
does 'only on these days' compose?").

**Proposed answer:** Defer to a future PR. Users who need this can
create two schedules — one daily for Refresh, one weekly for Scan on
their preferred day. The "before 10 AM" gating was specifically about
avoiding the 10 AM Jamf nightly job; the right user-facing knob is
"avoid these hours" as a preset/profile-wide setting, which is a
Settings concern not a Schedules concern.

### Q4: Multi-profile — per-profile cadence or org-wide?

`config.yaml` is per-profile already. Cadence config goes in
`config.yaml`, so it's per-profile by construction.

**Proposed answer:** Per-profile. The on-prem and cloud presets exist
precisely because different profiles need different cadences.

## Phasing

This is too large for a single PR. Proposed split:

- **PR-22** (engine): `collect_cadence` config schema, `is_due()`
  machinery in `ReportEngine.collect`, state-file persistence,
  pacing, preset-based cadence resolution. `snapshot-only` narrows
  to Refresh tier. `collect_skip` auto-migration. **No GUI yet** —
  defaults are baked in so the default behavior improves for everyone
  immediately. Add a `[migrate] collect_skip → per_report` line on
  first run so operators see what happened.

- **PR-23** (GUI): Schedules form tier picker + Settings → Performance
  preset picker + onboarding preset prompt. `TieredLaunchAgentWriter`
  delete + `ScheduleTier.hot/warm/cold` replaced with the new tier
  names. `RefreshCoordinator` switches to the new tier model.

- **PR-24** (optional / when needed): time-of-day gating, "avoid
  these hours" preset, per-report custom editor polish.

PR-22 ships standalone — users on the upgrade get the cadence model
even before the GUI lands. PR-23 makes it discoverable and
configurable.

## Test plan (PR-22)

- Engine unit tests:
  - `IsDueTests` — given pinned mtimes and cadences, returns expected
    boolean.
  - `TierResolverTests` — given a mode + tier overrides, returns the
    correct set of reports to fetch.
  - `PresetTests` — `on-prem` resolves expected cadences; `cloud`
    resolves expected cadences; `custom` requires per-report entries.
  - `MigrationTests` — pre-PR-22 config with `collect_skip: [...]`
    rewrites correctly to `per_report: <name>: never`.
- Integration:
  - `snapshot-only` with Refresh tier writes summary + only fetches
    the 5–6 Refresh-tier reports.
  - `jamf-cli-full` after a recent `snapshot-only` skips the
    Refresh-tier reports that are still fresh (`is_due` returns false).
  - State file rotation: 30 day retention default; old `.last` files
    pruned.
- Manual:
  - On-prem profile with `update-status: never` — confirm no
    `update-status` calls in the run log.
  - Schedule snapshot-only hourly + jamf-cli-full weekly; confirm
    each schedule reaches into the expected commands.

## Test plan (PR-23)

- Schedules form: tier picker preview matches what the engine actually
  runs (visual + integration).
- Settings → Performance: switching presets writes the expected
  `collect_cadence.preset` value and resolves cadences via the engine.
- Onboarding: first-launch prompt walks the user through preset
  selection; default is on-prem (conservative).
- `RefreshCoordinator` profile-switch backfill: opening a profile
  whose Refresh tier is overdue triggers a single backfill collect,
  not a full collect.

## Consequences

**Wins:**
- Overview / Trends / Deep Dive screens stay current at the cadence
  each one actually needs — no more "I refresh every hour and burn the
  on-prem server" or "I refresh once a week and Overview is stale."
- `snapshot-only` becomes a genuinely cheap option; small-fleet
  on-prem users can run it hourly without fear.
- Server-load presets give a sensible default to non-power-users.
  Custom mode is there for `collect.zsh`-level granularity.
- `collect_skip` (PR-16) graduates from binary skip-toggle to a real
  cadence model that includes "never" as a value.
- Removes dead code (`TieredLaunchAgentWriter`) and reconciles the
  existing tier scaffolding with the new model.

**Costs:**
- Large feature; spans engine + GUI + onboarding flow + tests + docs.
- Behavior change for `snapshot-only`: users running it today get a
  faster but narrower run. Surfaced in CHANGELOG; tested in CI.
- Per-report state files (`<workspace>/jamf-cli-data/state/<report>.last`)
  add filesystem surface. Need to be in the manifest hash (PR-7 territory)
  so a tampered state file can't trick the engine into skipping a fresh
  fetch indefinitely.
- One-time migration of `collect_skip` runs on first GUI save; needs
  a fallback path if the GUI is never opened (LaunchAgent-only users).

**Rejected alternatives:**
- *Wire the existing `TieredLaunchAgentWriter` as-is:* the model is
  wrong (per-cadence rather than per-report). Would require a second
  rewrite within a release.
- *Add `--tier` flag to `jamf-cli pro collect` upstream:* out of
  scope — this ADR wraps what jamf-cli exposes today. Could be a
  future upstream contribution if the pattern proves valuable.
- *Use a single cadence per profile (no per-report):* simpler, but
  doesn't solve the "Overview wants hourly, EA scans want weekly"
  problem. Would still require expensive commands at the most-frequent
  cadence.
- *Drop server-load presets and require users to configure each
  report:* unfriendly to non-power-users; defeats the GUI-first goal.

## References

- `~/Documents/Mac_Engineering/Jamf Reports/jamf-cli-data/collect.zsh` —
  reference implementation, lines 253-328 cover the daily/weekly/biweekly
  tier definitions and the `is_due()` mechanic
- `app/Sources/JamfReports/Services/CollectionTier.swift` — existing
  `ScheduleTier` enum (to be replaced)
- `app/Sources/JamfReports/Services/RefreshCoordinator.swift` —
  existing in-app coordinator (to be retargeted at the new tier names)
- `app/Sources/JamfReports/Services/TieredLaunchAgentWriter.swift` —
  unwired scaffolding (to be deleted in PR-23)
- `app/Sources/JamfReports/Engine/ReportEngine.swift:745+` — the
  `collect` static method that this ADR modifies
- PR-16 (`jamf_cli.collect_skip`): the binary skip mechanism this ADR
  generalizes
- PR-20 (snapshot-only emits summary.json): the Trends-recording
  contract that this ADR preserves and extends
- PR-21 (strict RunMode contract): the four-mode framework that this
  ADR composes with via the mode → tier-set mapping
