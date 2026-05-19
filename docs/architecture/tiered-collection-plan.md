# Implementation Plan: PR-22 + PR-23 tiered collection

**Companion doc to:** `docs/architecture/tiered-collection-adr.md`
**Status:** Ready for implementation (pending review of cadence numbers)
**Date:** 2026-05-19

---

## Overview

Replace the all-or-nothing `ReportEngine.collect` with a per-report
cadence model:
- Three tiers (Refresh / Inventory / Scan) define **what gets fetched**
- Two presets (on-prem / cloud) define **how often**
- State files (`<workspace>/jamf-cli-data/state/<report>.last`) track
  per-report freshness
- The GUI Schedules form gains a tier picker; Settings → Performance
  gains a preset chooser; no YAML editing required for the common case
- `snapshot-only` narrows from "everything" to "Refresh tier only" —
  a real Overview-keeps-fresh path safe to schedule once or twice daily

Full design rationale in the ADR. This doc is the implementable
breakdown.

---

## Architecture decisions (from ADR)

- **Three tiers, not four.** Refresh / Inventory / Scan. Biweekly
  collapsed into weekly; time-of-day gating deferred to PR-24.
- **Presets bake in cadences.** On-prem = daily / weekly / weekly;
  Cloud = twice daily / every 2-3 days / weekly. Neither preset goes
  more frequent than twice daily for Refresh.
- **State files are persistent and per-profile**, under
  `<workspace>/jamf-cli-data/state/`.
- **`snapshot-only` narrows to `{.refresh}`** in PR-22 (engine change).
  GUI defaults are touched in PR-23.
- **No legacy shim for `collect_skip`** — auto-migrated on first config
  load; legacy key removed after migration. Per CLAUDE.md "Replace,
  don't deprecate."
- **`TieredLaunchAgentWriter` + `ScheduleTier.hot/warm/cold` are
  deleted** (not rewritten) in PR-23. `RefreshCoordinator` retargets
  at the new `.refresh` tier.

---

## Dependency graph

```
Foundation (types, pure functions)
    │
    ├── T-1 CollectionTier enum + report→tier lookup
    ├── T-2 CadencePreset enum + default cadence tables
    ├── T-3 CollectCadenceConfig Codable types
    └── T-4 isDue() pure function
                │
                ├── State machinery
                │       ├── T-5 StateFileStore
                │       └── T-6 WorkspacePaths.stateDir
                │
                └── Cadence resolution
                        └── T-7 CadenceResolver
                                │
                                └── Engine integration
                                        ├── T-8 ReportEngine.collect filters by isDue
                                        ├── T-9 tiers parameter on collect
                                        ├── T-10 snapshot-only dispatcher narrowing
                                        └── T-11 pacing
                                                │
                                                ├── Migration
                                                │       ├── T-12 collect_skip → per_report
                                                │       └── T-13 migration log line
                                                │
                                                └── Integrity
                                                        └── T-14 state files in manifest

                        PR-22 boundary
                            │
                            ▼
                        Dead code removal (PR-23)
                            ├── T-15 delete TieredLaunchAgentWriter
                            └── T-16 RefreshCoordinator → .refresh tier
                                    │
                                    ├── Schedules form
                                    │       ├── T-17 tier picker UI
                                    │       ├── T-18 LaunchAgentWriter --tiers
                                    │       ├── T-19 LaunchAgentService parse --tiers
                                    │       └── T-20 main.swift --tiers
                                    │
                                    ├── Settings preset chooser
                                    │       ├── T-21 Performance pane
                                    │       ├── T-22 ConfigService writeback
                                    │       └── T-23 custom mode editor
                                    │
                                    ├── Onboarding
                                    │       └── T-24 preset prompt on profile create
                                    │
                                    └── Migration UX
                                            └── T-25 settings banner
```

---

## PR-22: engine layer

### Phase 1: Foundation — types and pure functions

#### Task T-1: `CollectionTier` enum + report→tier lookup

**Description:** Define the three-tier enum and the lookup table that
maps each known jamf-cli report kind to a tier. Pure value type, no
I/O. This is the load-bearing type the rest of the work hangs off of.

**TDD:** Write the lookup-table test first (every command in
`ReportEngine.collect`'s list has a tier; lookup is total).

**Acceptance criteria:**
- [ ] `CollectionTier` enum (`refresh` / `inventory` / `scan`) is `Sendable`, `Hashable`, `CaseIterable`
- [ ] `CollectionTier.tier(forReport:)` returns the correct tier for every command in `ReportEngine.collect`'s `commands` list (verify by iterating the list in a test)
- [ ] Unknown report names return `nil` (so callers can decide whether to skip or default)

**Verification:**
- [ ] `swift test --filter CollectionTierTests`
- [ ] `swift build --build-tests` — clean

**Dependencies:** None

**Files likely touched:**
- `app/Sources/JamfReports/Services/CollectionTier.swift` (replaces the existing `ScheduleTier`-based file)
- `app/Tests/JamfReportsTests/CollectionTierTests.swift` (new)

**Scope:** S (1-2 files)

---

#### Task T-2: `CadencePreset` enum + default cadence tables

**Description:** Define `.onPrem` / `.cloud` / `.custom` and the
hardcoded per-tier cadence defaults for each preset. Pure data, no I/O.

**TDD:** Tests assert each preset returns expected cadences (in
seconds) for each tier. These are the published contract — locking
them in tests prevents accidental drift.

**Acceptance criteria:**
- [ ] `CadencePreset.onPrem` returns `86_400` (daily) for `.refresh`, `604_800` (weekly) for `.inventory` and `.scan`
- [ ] `CadencePreset.cloud` returns `43_200` (12h) for `.refresh`, `172_800` (2 days) for `.inventory`, `604_800` for `.scan`
- [ ] `CadencePreset.custom` returns `nil` for every tier (no defaults — requires per-report config)
- [ ] `paceSeconds` returns `15` for on-prem, `0` for cloud, `0` for custom

**Verification:**
- [ ] `swift test --filter CadencePresetTests`

**Dependencies:** None (can run in parallel with T-1)

**Files likely touched:**
- `app/Sources/JamfReports/Services/CadencePreset.swift` (new)
- `app/Tests/JamfReportsTests/CadencePresetTests.swift` (new)

**Scope:** S

---

#### Task T-3: `CollectCadenceConfig` Codable types

**Description:** Add the Codable types that mirror the YAML shape in
the ADR. Plug into `ReportConfig` so `ConfigLoader.load` reads it.
YAML round-trip via existing `YAMLCodec`.

**TDD:** Write decoding tests for each preset form, then a round-trip
test (decode → encode → decode → equal).

**Acceptance criteria:**
- [ ] `CollectCadenceConfig` decodes from the ADR YAML schema:
  ```yaml
  collect_cadence:
    preset: on-prem
    pace_seconds: 15
    per_report:
      update-status: never
      overview: { tier: refresh, cadence: 43200 }
  ```
- [ ] `per_report` entry accepts string `"never"` OR object `{tier, cadence}` (test both)
- [ ] Round-trip preserves all fields
- [ ] Decoding `preset: custom` without a `per_report` entry for a known report **does not throw** — resolution at fetch time returns `.never` for unconfigured reports under custom preset

**Verification:**
- [ ] `swift test --filter CollectCadenceConfigTests`
- [ ] Existing `YAMLCompactSequenceTests` still pass

**Dependencies:** None (can run in parallel with T-1, T-2)

**Files likely touched:**
- `app/Sources/JamfReports/Models/ReportConfig.swift` (add field)
- `app/Sources/JamfReports/Services/CollectCadenceConfig.swift` (new)
- `app/Tests/JamfReportsTests/CollectCadenceConfigTests.swift` (new)

**Scope:** S

---

#### Task T-4: `isDue(lastRun:cadence:now:)` pure function

**Description:** The core decision function. Given the last successful
fetch timestamp, the cadence in seconds, and a clock, return whether
to fetch now.

**TDD:** Write tests first — fresh, stale, exactly-due, never-run,
`.never`.

**Acceptance criteria:**
- [ ] `isDue(lastRun: nil, cadence: 86400, now: anyDate)` returns `true` (never fetched)
- [ ] `isDue(lastRun: now - 86399, cadence: 86400, now: now)` returns `false` (not yet due)
- [ ] `isDue(lastRun: now - 86400, cadence: 86400, now: now)` returns `true` (exactly due)
- [ ] `isDue(lastRun: now - 90000, cadence: 86400, now: now)` returns `true` (overdue)
- [ ] `isDue(lastRun: anyDate, cadence: .never, now: anyDate)` returns `false`
- [ ] `now` parameter defaults to `Date()` for production callers; tests inject a fixed clock

**Verification:**
- [ ] `swift test --filter IsDueTests`

**Dependencies:** T-2 (uses `Cadence` type that may be defined alongside the preset)

**Files likely touched:**
- `app/Sources/JamfReports/Services/CadenceResolver.swift` (new — houses `isDue` and `Cadence` enum)
- `app/Tests/JamfReportsTests/IsDueTests.swift` (new)

**Scope:** S

---

### Checkpoint: Foundation (after T-1 through T-4)

- [ ] All four foundation test files pass
- [ ] `swift build` clean
- [ ] No callers of the new types yet — they're load-bearing primitives,
      not yet wired
- [ ] Review: do the cadence numbers (12h refresh on cloud, 2.5-day inventory,
      etc.) feel right? Last call before they ship in code.

---

### Phase 2: State machinery

#### Task T-5: `StateFileStore`

**Description:** Read/write `<state-dir>/<report>.last` Unix epoch
timestamps. Atomic writes via temp file + rename. Pure I/O service;
no scheduling logic.

**TDD:** Tests use a temp directory; cover read-missing, write,
read-back, rotation, malformed-file recovery.

**Acceptance criteria:**
- [ ] `StateFileStore.lastFetch(report:)` returns `nil` for non-existent file
- [ ] `StateFileStore.markFetched(report:at:)` writes Unix epoch atomically
- [ ] `StateFileStore.lastFetch` reads back the timestamp written by `markFetched`
- [ ] Malformed `.last` file (non-numeric content, empty) returns `nil` (treated as "never fetched") and logs a warning via `AppLogger.engine.warning`
- [ ] Writes use temp file + `replaceItem` for atomicity (no half-written file on crash)
- [ ] Directory created with `0o700` permissions (state contains run timing — same sensitivity as logs)

**Verification:**
- [ ] `swift test --filter StateFileStoreTests`
- [ ] Verify permissions test (`0o700`) passes on macOS CI

**Dependencies:** T-6 (state dir path resolution)

**Files likely touched:**
- `app/Sources/JamfReports/Services/StateFileStore.swift` (new)
- `app/Tests/JamfReportsTests/StateFileStoreTests.swift` (new)

**Scope:** S

---

#### Task T-6: `WorkspacePaths.stateDir(for:)`

**Description:** Add the state directory path constant. Lives under
`<dataDir>/state/`. Profile-validated like every other `WorkspacePaths`
helper.

**Acceptance criteria:**
- [ ] `WorkspacePaths.stateDir(for: "dummy")` returns `<workspace>/jamf-cli-data/state/` (honoring `jamf_cli.data_dir` config)
- [ ] Throws `PathError.invalidProfile` for invalid slugs
- [ ] No new escape vectors — relative `data_dir` continues to resolve via existing `resolve()`

**Verification:**
- [ ] `swift test --filter WorkspacePathsTests`
- [ ] Existing `WorkspacePathsAbsoluteTests` still pass

**Dependencies:** None (can run in parallel with T-5)

**Files likely touched:**
- `app/Sources/JamfReports/Services/WorkspacePaths.swift` (add method)
- `app/Tests/JamfReportsTests/WorkspacePathsTests.swift` (extend)

**Scope:** XS

---

### Phase 3: Cadence resolution

#### Task T-7: `CadenceResolver`

**Description:** Given a report name, the `CollectCadenceConfig`, and
the active preset, return the effective cadence. Per-report override
wins over preset default; `.never` is a valid cadence; custom preset
with no override for a report returns `.never`.

**TDD:** Test cases — preset default, override of preset default,
custom-with-no-override, custom-with-override, `.never` override under
both preset types, missing config (use on-prem defaults as safe fallback).

**Acceptance criteria:**
- [ ] `resolve(report: "overview", config: <onPrem>)` returns 86400
- [ ] `resolve(report: "overview", config: <onPrem with override: 3600>)` returns 3600 (override wins)
- [ ] `resolve(report: "update-status", config: <onPrem>)` returns `.never` (preset hard-exclusion)
- [ ] `resolve(report: "overview", config: <custom>)` returns `.never` (custom requires explicit override)
- [ ] `resolve(report: "overview", config: nil)` returns 86400 (on-prem defaults as the missing-config fallback — conservative)

**Verification:**
- [ ] `swift test --filter CadenceResolverTests`

**Dependencies:** T-2, T-3, T-4

**Files likely touched:**
- `app/Sources/JamfReports/Services/CadenceResolver.swift` (add to file from T-4)
- `app/Tests/JamfReportsTests/CadenceResolverTests.swift` (new)

**Scope:** S

---

#### Task T-8: `ReportEngine.collect` filters by `isDue` per report

**Description:** The integration point. `collect` consults
`CadenceResolver` + `StateFileStore` for each report; skips reports
whose cadence isn't due; on successful fetch, calls
`StateFileStore.markFetched`.

**TDD:** Integration test uses a temp workspace, seeds a state file with
a recent timestamp for `overview`, runs collect, asserts overview was
skipped and other reports proceeded. Second test seeds a stale state
file; asserts overview was re-fetched.

**Acceptance criteria:**
- [ ] `ReportEngine.collect` consults `CadenceResolver.resolve(report:config:)` for each command in its plan
- [ ] Reports with `.never` cadence are filtered out before any subprocess launch
- [ ] Reports with a fresh state file are skipped; `[skip] <report> not due (last: <iso8601-ts>)` logged
- [ ] Reports that fetch successfully call `StateFileStore.markFetched(report:at: Date())`
- [ ] Failed fetches do **not** update the state file (so a transient failure doesn't extend the skip window)
- [ ] The existing `useCachedData` + `collect_skip` (PR-16) behavior continues to work during the migration window (T-12 removes the legacy key)

**Verification:**
- [ ] `swift test --filter ReportEngineCollectCadenceTests`
- [ ] Manual: run `swift run JamfReports --scheduled-run --profile dummy --mode snapshot-only`; on first run all configured reports fetch, on second run within the cadence window most are skipped

**Dependencies:** T-1, T-5, T-6, T-7

**Files likely touched:**
- `app/Sources/JamfReports/Engine/ReportEngine.swift` (modify `collect`)
- `app/Tests/JamfReportsTests/ReportEngineCollectCadenceTests.swift` (new)

**Scope:** M (3-5 files)

---

### Checkpoint: Engine respects per-report cadence (after T-1 through T-8)

- [ ] All tests pass
- [ ] Manual snapshot-only run shows `[skip]` lines for already-fresh reports
- [ ] CHANGELOG entry drafted for the behavior change
- [ ] **Review:** confirm the `[skip]` log line format is what operators want
      to see in `automation/logs/`

---

### Phase 4: Snapshot-only narrowing

#### Task T-9: Tier-set parameter on `ReportEngine.collect`

**Description:** Add `tiers: Set<CollectionTier>` parameter to
`ReportEngine.collect`. Defaults to all tiers to preserve existing
behavior. Commands are filtered by tier membership before the
cadence check.

**Acceptance criteria:**
- [ ] `ReportEngine.collect(profile:tiers:...)` accepts a tier set; defaults to `Set(CollectionTier.allCases)` for backward compatibility
- [ ] Commands whose tier (from `CollectionTier.tier(forReport:)`) is not in the set are filtered out before the cadence check
- [ ] Calling with `tiers: [.refresh]` runs only Refresh-tier commands

**Verification:**
- [ ] `swift test --filter ReportEngineTierFilterTests` (new test file)
- [ ] Existing `ReportEngine.collect` callers still work (CLIBridge, main.swift) by virtue of the default

**Dependencies:** T-8

**Files likely touched:**
- `app/Sources/JamfReports/Engine/ReportEngine.swift`
- `app/Tests/JamfReportsTests/ReportEngineTierFilterTests.swift` (new)

**Scope:** S

---

#### Task T-10: `CLIBridge+Run` + `main.swift` narrow snapshot-only to Refresh

**Description:** Both dispatcher sites pass `tiers: [.refresh]` for
`.snapshotOnly` mode. Other modes pass the full set.

**Acceptance criteria:**
- [ ] `CLIBridge+Run.runNow` passes `tiers: [.refresh]` to `ReportEngine.collect` for `.snapshotOnly`
- [ ] `main.swift scheduledRunSingle` passes the same for `.snapshotOnly`
- [ ] Other modes (`.jamfCLIOnly`, `.jamfCLIFull`, `.csvAssisted`) pass `tiers: Set(CollectionTier.allCases)` (or omit the parameter)
- [ ] `Schedule.RunMode.snapshotOnly.displayDescription` updated again to reflect "runs only the Refresh tier (cheap commands for Overview + Trends)"
- [ ] PR-20's `testNativeSingleWriteRoundTripsAllRunModes` still passes
- [ ] New test: `testSnapshotOnlyOnlyFetchesRefreshTier` — given a temp workspace, snapshot-only collects only commands in the Refresh tier set

**Verification:**
- [ ] `swift test` — full suite green
- [ ] Manual: snapshot-only run in dummy profile produces `jamf-cli-data/{overview,security,inventory-summary,patch-status,policy-status}` only

**Dependencies:** T-9

**Files likely touched:**
- `app/Sources/JamfReports/Services/CLIBridge+Run.swift`
- `app/Sources/JamfReports/App/main.swift`
- `app/Sources/JamfReports/Models/Models.swift` (displayDescription)
- `app/Tests/JamfReportsTests/UXPolishQ4Tests.swift` (description test)
- `app/Tests/JamfReportsTests/SnapshotOnlyTierTests.swift` (new)

**Scope:** S

---

### Phase 5: Pacing

#### Task T-11: `pace_seconds` honored between commands

**Description:** After each successful fetch, sleep
`config.collectCadence?.paceSeconds ?? 0` before the next command.
Resolved from preset by `CadenceResolver`. Tests use a fixed-zero
pace to keep the suite fast; one slow test confirms a 1s pace
actually waits.

**Acceptance criteria:**
- [ ] Successful fetches followed by another command sleep `paceSeconds` (resolved from preset or override)
- [ ] Failed fetches do **not** sleep (no value in waiting after an error)
- [ ] Pace of 0 means no sleep — preserves current behavior for cloud-default users
- [ ] Test: a fixture with `pace_seconds: 1` and two commands takes ≥1s; with `0` takes <100ms

**Verification:**
- [ ] `swift test --filter CollectPacingTests`

**Dependencies:** T-8

**Files likely touched:**
- `app/Sources/JamfReports/Engine/ReportEngine.swift`
- `app/Tests/JamfReportsTests/CollectPacingTests.swift` (new)

**Scope:** S

---

### Phase 6: Migration

#### Task T-12: `collect_skip` → `per_report: never` migration

**Description:** On config load, if `jamf_cli.collect_skip` is set,
synthesize equivalent `per_report: <name>: never` entries in
`CollectCadenceConfig`. Legacy key is read for the migration window
but never written back — first GUI save in PR-23 will erase it.

**Acceptance criteria:**
- [ ] `ConfigLoader.load` reads `jamf_cli.collect_skip` and merges its entries into `collect_cadence.per_report` (as `.never`)
- [ ] In-memory `CollectCadenceConfig` has the migrated entries; the on-disk YAML is **not** modified by load (preserves observability of the legacy key for the user)
- [ ] When both `collect_skip` and `per_report: <same name>` are set, the explicit `per_report` wins (legacy key is older)
- [ ] Hyphen and underscore variants in `collect_skip` (e.g., `patch_device_failures` vs `patch-device-failures`) normalize the same way they do today (PR-16 invariant preserved)

**Verification:**
- [ ] `swift test --filter CollectSkipMigrationTests`
- [ ] Existing `collect_skip` integration tests still pass

**Dependencies:** T-3, T-7

**Files likely touched:**
- `app/Sources/JamfReports/Services/ConfigLoader.swift`
- `app/Tests/JamfReportsTests/CollectSkipMigrationTests.swift` (new)

**Scope:** S

---

#### Task T-13: Migration log line

**Description:** Log `[migrate] collect_skip → per_report: <name>:
never` on first load when migration kicks in. Once per process.

**Acceptance criteria:**
- [ ] Log line appears in `AppLogger.engine.info` for each migrated entry
- [ ] In scheduled-run output, lines stream to the run log
- [ ] Log is suppressed on subsequent loads in the same process (track via static flag or `Set<String>` of already-logged profiles)

**Verification:**
- [ ] `swift test --filter CollectSkipMigrationTests` (extends T-12 tests)

**Dependencies:** T-12

**Files likely touched:**
- `app/Sources/JamfReports/Services/ConfigLoader.swift`

**Scope:** XS

---

### Phase 7: Integrity

#### Task T-14: Include state files in snapshot manifest

**Description:** Per the ADR's "Costs" section, state files can be
tampered to defer expensive fetches indefinitely. Include them in
the snapshot manifest (PR-7 territory) so a tampered `.last` is
caught by manifest verification.

**Acceptance criteria:**
- [ ] State files (`<state-dir>/*.last`) are hashed into `jamf-cli-data/manifest.json` on the same schedule as snapshot JSONs
- [ ] Manifest verification (strict mode + audit view) flags tampered or missing state files
- [ ] Backward compat: pre-PR-22 workspaces with no state files do **not** fail strict-mode preflight (state-file entries are optional in the manifest schema)

**Verification:**
- [ ] `swift test --filter StateFileManifestTests` (new)
- [ ] Existing `ManifestTests` still pass
- [ ] Manual: tamper a `.last` file, run audit, expect a flagged finding

**Dependencies:** T-5

**Files likely touched:**
- `app/Sources/JamfReports/Engine/SnapshotManifest.swift`
- `app/Tests/JamfReportsTests/StateFileManifestTests.swift` (new)

**Scope:** S

---

### Checkpoint: PR-22 ready to ship

- [ ] Full `swift test` suite green
- [ ] CHANGELOG entry under `### Added` (per-report cadence) and `### Changed` (snapshot-only narrows)
- [ ] `BACKLOG.md` `CONSIDER (closed by PR-22)` item removed
- [ ] Manual: dummy profile with `update-status: never` shows no `update-status` calls in the run log
- [ ] Manual: snapshot-only run produces only Refresh-tier directories
- [ ] **Review with human before opening PR**

---

## PR-23: GUI layer

### Phase 1: Dead code removal

#### Task T-15: Delete `TieredLaunchAgentWriter` + `ScheduleTier`

**Description:** No-callers cleanup. `TieredLaunchAgentWriter` is
unused in any view; `ScheduleTier.hot/warm/cold` is used only by
`RefreshCoordinator` (T-16 retargets it).

**Acceptance criteria:**
- [ ] `app/Sources/JamfReports/Services/TieredLaunchAgentWriter.swift` deleted
- [ ] `ScheduleTier.hot/warm/cold` enum removed from `app/Sources/JamfReports/Services/CollectionTier.swift` (the renamed file now hosts the new `CollectionTier` from T-1)
- [ ] `RefreshPolicy.swift` updated to key off `CollectionTier` instead of `ScheduleTier`
- [ ] No compiler errors; no remaining references via grep

**Verification:**
- [ ] `rg "ScheduleTier|TieredLaunchAgentWriter" app/` returns no hits
- [ ] `swift build` clean

**Dependencies:** T-1, T-16 (delete after retarget)

**Files likely touched:**
- delete `TieredLaunchAgentWriter.swift`
- modify `RefreshPolicy.swift`
- modify `CollectionTier.swift` (drop old enum)

**Scope:** S

---

#### Task T-16: `RefreshCoordinator` retargets to `.refresh` tier

**Description:** The profile-switch debounce currently calls
`refreshIfStale(profile: newProfile, tier: .hot)`. Retarget at
`.refresh` (the new tier name) — same intent (cheap, frequent),
different name.

**Acceptance criteria:**
- [ ] `RefreshCoordinator.refreshIfStale(profile:tier:)` signature now takes `CollectionTier`
- [ ] `WorkspaceStore+Refresh.swift` calls `refreshIfStale(profile: profileSlug, tier: .refresh)` on profile switch
- [ ] Staleness threshold for `.refresh` resolves from active preset's cadence × 1.5 (ADR Q1)
- [ ] Tests in `RefreshCoordinatorTests` updated to use the new tier names
- [ ] Backfill behavior unchanged: opening a profile whose Refresh tier is overdue triggers a single backfill collect (calls `ReportEngine.collect` with `tiers: [.refresh]`)

**Verification:**
- [ ] `swift test --filter RefreshCoordinatorTests`
- [ ] Manual: switch profiles in the GUI; observe `[info]` line indicating refresh tier collect started

**Dependencies:** T-1, T-9

**Files likely touched:**
- `app/Sources/JamfReports/Services/RefreshCoordinator.swift`
- `app/Sources/JamfReports/Services/WorkspaceStore+Refresh.swift`
- `app/Tests/JamfReportsTests/RefreshCoordinatorTests.swift`

**Scope:** S

---

### Phase 2: Schedules form tier picker

#### Task T-17: Tier picker UI in `NewScheduleSheet`

**Description:** Add a multi-select tier picker to the Schedule form,
default-populated based on selected mode. User can override.

**Acceptance criteria:**
- [ ] New row in `NewScheduleSheet`: "Tiers" multi-select with three checkboxes (Refresh / Inventory / Scan)
- [ ] Default state derived from mode (per ADR mode → tier-set table)
- [ ] Mode change updates the default selection (preserves user manual override via a `userTouchedTiers` flag)
- [ ] Selected tiers stored in `ScheduleFormState.tiers: Set<CollectionTier>`
- [ ] `Schedule` model gains `tiers: Set<CollectionTier>?` (optional for backward compat with legacy plists)
- [ ] Visual verification: the picker renders correctly at `PageScaffold.minSupportedWidth` (per CLAUDE.md anti-churn rules on SwiftUI layout primitives)

**Verification:**
- [ ] `swift test --filter ScheduleFormStateTests`
- [ ] Manual: open New Schedule sheet, verify checkboxes; switch modes, verify defaults shift; uncheck a tier, switch modes, verify user override persists

**Dependencies:** T-1

**Files likely touched:**
- `app/Sources/JamfReports/Views/SchedulesView.swift`
- `app/Sources/JamfReports/Models/Models.swift`
- `app/Tests/JamfReportsTests/ScheduleFormStateTests.swift` (new)

**Scope:** M

---

#### Task T-18: `LaunchAgentWriter` writes `--tiers <csv>`

**Description:** Persist the tier set in `ProgramArguments`. Comma-
separated rawValues for atomic CLI parsing.

**Acceptance criteria:**
- [ ] `LaunchAgentWriter.nativeSingleWrite` includes `--tiers <csv>` in `ProgramArguments` when `schedule.tiers != nil`
- [ ] Omits the flag for `nil` (backward compat — legacy plists default to all tiers in `main.swift`)
- [ ] `nativeMultiWrite` includes the same flag
- [ ] Trust-check (`multiProgramArgumentsAreTrusted`) accepts the new arg layout
- [ ] Comment block updated to document the arg layout

**Verification:**
- [ ] `swift test --filter LaunchAgentWriterTests` (extend existing round-trip test)

**Dependencies:** T-17

**Files likely touched:**
- `app/Sources/JamfReports/Services/LaunchAgentWriter.swift`
- `app/Tests/JamfReportsTests/LaunchAgentWriterTests.swift`

**Scope:** S

---

#### Task T-19: `LaunchAgentService.parse` reads `--tiers`

**Description:** Inverse of T-18. Parse `--tiers` back into
`Schedule.tiers`. Default `nil` when absent.

**Acceptance criteria:**
- [ ] `LaunchAgentService.parse` extracts `--tiers <csv>` and decodes into `Set<CollectionTier>`
- [ ] Invalid tier names in csv are dropped with a warning (don't fail the parse)
- [ ] Round-trip test: write schedule with tiers `{.refresh, .scan}`, parse back, assert equal

**Verification:**
- [ ] `swift test --filter LaunchAgentServiceTests`

**Dependencies:** T-18

**Files likely touched:**
- `app/Sources/JamfReports/Services/LaunchAgentService.swift`
- `app/Tests/JamfReportsTests/LaunchAgentServiceTests.swift`

**Scope:** S

---

#### Task T-20: `main.swift --scheduled-run` parses `--tiers`

**Description:** The headless dispatcher passes the tiers through to
`ReportEngine.collect`. Default when missing matches PR-22's `tiers`
parameter default (all).

**Acceptance criteria:**
- [ ] `main.swift scheduledRun` parses `--tiers <csv>` and converts to `Set<CollectionTier>`
- [ ] Missing flag → all tiers (matches legacy plist behavior)
- [ ] `scheduledRunSingle` accepts `tiers` parameter and passes to `ReportEngine.collect`
- [ ] Test (CLI integration): legacy plist with no `--tiers` still completes successfully

**Verification:**
- [ ] Manual: trigger a scheduled run with `--tiers refresh`; only Refresh-tier directories see new snapshots
- [ ] Existing `CLISubcommandTests` pass

**Dependencies:** T-19

**Files likely touched:**
- `app/Sources/JamfReports/App/main.swift`

**Scope:** S

---

### Checkpoint: Schedules tier picker round-trips

- [ ] Create a schedule with custom tier set in the GUI
- [ ] Reopen the Schedules list — tier set persists
- [ ] Run the schedule manually — only selected tiers fetch
- [ ] Delete and recreate; legacy plists (no `--tiers`) still work
- [ ] Visual verification of the form at minSupportedWidth (CLAUDE.md anti-churn)

---

### Phase 3: Settings preset chooser

#### Task T-21: `Settings → Performance` pane

**Description:** New tab/section in SettingsView. Per-profile preset
picker (radio buttons: On-prem / Cloud / Custom). Shows the resolved
cadences as informational text.

**Acceptance criteria:**
- [ ] New pane accessible from SettingsView
- [ ] Three-way radio: On-prem / Cloud / Custom
- [ ] Preview text shows resolved cadences for the selected preset (read from `CadencePreset`)
- [ ] Selection writes `collect_cadence.preset` via `ConfigService` for the active profile
- [ ] Switching presets shows a confirmation modal warning that scheduled runs will adopt the new cadences

**Verification:**
- [ ] `swift test --filter SettingsPerformancePaneTests`
- [ ] Manual: switch presets, observe YAML write, observe Schedules form preview update

**Dependencies:** T-2, T-3

**Files likely touched:**
- `app/Sources/JamfReports/Views/SettingsView.swift`
- `app/Sources/JamfReports/Services/ConfigService.swift`
- `app/Tests/JamfReportsTests/SettingsPerformancePaneTests.swift` (new)

**Scope:** M

---

#### Task T-22: `ConfigService` writes `collect_cadence.preset`

**Description:** Inverse of T-3 — write the preset selection back to
`config.yaml` via `YAMLCodec`. Atomic write.

**Acceptance criteria:**
- [ ] `ConfigService.setCadencePreset(profile:preset:)` writes the new value atomically
- [ ] Round-trip: write, read, assert equal
- [ ] If `collect_cadence` block didn't exist, it's created
- [ ] Legacy `jamf_cli.collect_skip` is removed from the file on the same write (migration finalization)

**Verification:**
- [ ] `swift test --filter ConfigServiceCadenceTests`

**Dependencies:** T-3

**Files likely touched:**
- `app/Sources/JamfReports/Services/ConfigService.swift`
- `app/Tests/JamfReportsTests/ConfigServiceCadenceTests.swift` (new)

**Scope:** S

---

#### Task T-23: Custom mode per-report editor

**Description:** When preset is `.custom`, expose a per-report
table in Settings → Performance: report name, current tier (picker),
cadence (numeric in seconds or "Never"). Pre-populated with the
on-prem defaults the first time a user switches to custom.

**Acceptance criteria:**
- [ ] Per-report rows for every command in `ReportEngine.collect`'s list
- [ ] Tier picker per row (Refresh / Inventory / Scan / Never)
- [ ] Cadence numeric editor (seconds) with human-readable display ("1d", "12h", "1w")
- [ ] Initial population uses on-prem defaults when switching from on-prem; cloud defaults when switching from cloud
- [ ] Persists via `ConfigService.setCustomCadence(profile:perReport:)`

**Verification:**
- [ ] `swift test --filter CustomCadenceEditorTests`
- [ ] Manual: switch to Custom, edit a report, save, reload, verify persistence

**Dependencies:** T-21, T-22

**Files likely touched:**
- `app/Sources/JamfReports/Views/SettingsView.swift`
- `app/Sources/JamfReports/Services/ConfigService.swift`

**Scope:** M

---

### Phase 4: Onboarding integration

#### Task T-24: Preset prompt during profile creation

**Description:** OnboardingFlow's profile-creation step gains a "Is
this an on-prem or cloud Jamf Pro?" question. Pre-selects On-prem
(conservative). Result written to the new workspace's `config.yaml`
before first collect.

**Acceptance criteria:**
- [ ] New step in `OnboardingFlow`: preset selection (radio: On-prem / Cloud)
- [ ] Custom is not exposed in onboarding (users opt in via Settings later)
- [ ] Selection persisted to `config.yaml` before workspace-init completes
- [ ] Default is On-prem — most conservative and matches CBP-style deployments
- [ ] Subtitle text under each option ("Recommended for self-hosted Jamf Pro" / "Use for jamfcloud.com tenants")

**Verification:**
- [ ] `swift test --filter OnboardingFlowTests`
- [ ] Manual: onboard a new profile, verify `collect_cadence.preset` is set in the generated config

**Dependencies:** T-3, T-22

**Files likely touched:**
- `app/Sources/JamfReports/Services/OnboardingFlow.swift`
- `app/Sources/JamfReports/Views/OnboardingView.swift`
- `app/Tests/JamfReportsTests/OnboardingFlowTests.swift`

**Scope:** S

---

### Phase 5: Migration UX

#### Task T-25: Settings banner — `collect_skip` migration notice

**Description:** First time SettingsView opens after upgrade, if
`collect_skip` was migrated, show a one-time banner explaining the
change. Click to dismiss; persists dismissal in `@AppStorage`.

**Acceptance criteria:**
- [ ] Banner appears at top of SettingsView when `UserDefaults` flag is unset AND `collect_skip` migration was logged this session
- [ ] Banner text: "Migrated `jamf_cli.collect_skip` to the new per-report cadence model. Check Settings → Performance to review."
- [ ] Dismiss button hides the banner permanently for that user
- [ ] Doesn't appear on fresh installs (no migration was needed)

**Verification:**
- [ ] `swift test --filter SettingsMigrationBannerTests`
- [ ] Manual: install with legacy config containing `collect_skip`, verify banner; dismiss, verify it stays dismissed across launches

**Dependencies:** T-12, T-21

**Files likely touched:**
- `app/Sources/JamfReports/Views/SettingsView.swift`
- `app/Tests/JamfReportsTests/SettingsMigrationBannerTests.swift` (new)

**Scope:** S

---

### Checkpoint: PR-23 ready to ship

- [ ] All tests pass
- [ ] CHANGELOG entry under `### Added` (preset chooser + tier picker) and `### Removed` (dead code)
- [ ] `BACKLOG.md` `DECISION required — TieredLaunchAgentWriter is dead code` item removed
- [ ] Manual: end-to-end onboarding flow with new profile picks preset; Settings shows resolved cadences; Schedules form gains tier picker
- [ ] Visual verification of new Settings pane and Schedules form rows at `PageScaffold.minSupportedWidth`
- [ ] **Review with human before opening PR**

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Snapshot-only behavior change surprises cloud users who relied on it as "full refresh" | Medium | CHANGELOG entry + PR description call out; default cloud preset has 2x daily Refresh so Overview KPIs still update reasonably fast |
| State files in manifest break existing workspaces that already have a manifest | Medium | Make state-file entries optional in manifest schema (T-14 acceptance criterion); existing manifests verify cleanly |
| `RefreshCoordinator` rewrite breaks profile-switch flow | Low | T-16 explicitly preserves behavior; tests cover the debounce + backfill path |
| Custom-mode users get `.never` for unconfigured reports (silent skip) | Low | Document in tooltips on the Custom editor row — "unconfigured reports won't be fetched"; the `[skip]` log line is explicit |
| Pacing test (T-11) is slow (deliberately ≥1s) | Low | Mark with `XCTSkipIf(ProcessInfo.processInfo.environment["FAST_TESTS"] != nil)` so dev runs skip but CI runs the slow check |
| Tampered `<report>.last` could be used to extend skip window | Medium | T-14 puts state files in the manifest; strict-mode verification flags tampering |

---

## Resolved decisions (2026-05-19)

The four open questions blocking T-1 were resolved in the
2026-05-19 review session. Locked answers below; any future revisit
should be explicit.

1. **Cloud Inventory cadence: 2 days (172_800 s).** T-2 hardcodes
   this value in the `.cloud` preset's Inventory cadence. Picked
   over 3 days for predictable scheduling (runs on the same hour
   every other day).
2. **Legacy plist tier default: all tiers.** When `--tiers` is
   absent from `ProgramArguments`, `main.swift` runs all tiers.
   Preserves pre-PR-23 verbatim behavior so users on existing
   schedules don't see a silent narrowing on first scheduled fire
   after upgrade.
3. **Manifest schema version: bump.** T-14 increments the manifest
   schema version when adding optional state-file entries. Pinned in
   tests so a future addition that forgets to bump fails CI. Bump
   even though additive changes are backward-compatible — the
   security-audit log line that names the schema version is more
   useful when it accurately reflects "this run produced a v2
   manifest, with state-file coverage."
4. **Settings → Performance pane placement: new tab.** T-21 adds a
   "Performance" tab to SettingsView rather than crowding existing
   sections. Decision can be revisited during T-21 if the empty new
   tab looks awkward with only the preset chooser + custom editor.

---

## Parallelization Opportunities

Within PR-22:

- **Phase 1 (T-1, T-2, T-3) can run in parallel.** No dependencies between them; all foundation types.
- **T-5 + T-6 can run in parallel** with T-7. State machinery and resolver are independent.
- **T-9 + T-10 (snapshot-only narrow) can run in parallel** with T-11 (pacing) and T-12+T-13 (migration). All sit on top of T-8.
- **T-14 can run in parallel** with the migration tasks.

Within PR-23:

- **T-17 (form UI) and T-21 (Settings pane)** can run in parallel — different views, both depend only on T-1/T-2/T-3 from PR-22.
- **T-18, T-19, T-20** must be sequential (writer → parser → dispatcher).
- **T-24 (onboarding) and T-25 (migration banner)** are independent.

If multiple subagents are available, T-1/T-2/T-3 in parallel saves a half-session.

---

## Suggested Implementation Strategy

For a single session attacking PR-22:

1. Open Plan mode; re-read this doc + the ADR; resolve open questions 1-3 (5 min).
2. Implement T-1 through T-4 in sequence (foundation; small files; ~30 min). Checkpoint.
3. Implement T-5, T-6 (state machinery; ~15 min).
4. Implement T-7 (cadence resolver; ~15 min).
5. Implement T-8 (the big integration; ~45 min). Checkpoint — manual run on dummy profile.
6. Implement T-9, T-10 (snapshot-only narrow; ~30 min).
7. Implement T-11 (pacing; ~15 min).
8. Implement T-12, T-13 (migration; ~30 min).
9. Implement T-14 (manifest integration; ~30 min). Final checkpoint.
10. Run full test suite, draft CHANGELOG, push, open PR. (~15 min)

Estimated: 3-4 hours of focused work for PR-22 if all goes well; 5-6 hours with reasonable rework. PR-23 is similar — 3-4 hours of focused GUI work, more if SwiftUI layout iteration is needed.

For a multi-session approach: each phase checkpoint is a natural session boundary. Push WIP commits between phases for visibility.

---

## Verification Before Starting

- [x] ADR cadence numbers confirmed by human — 2 days for Cloud Inventory (resolved 2026-05-19)
- [x] Open Q2 (legacy plist tier default) resolved — all tiers
- [x] Open Q3 (manifest schema version) resolved — bump
- [x] Open Q4 (Settings pane placement) resolved — new tab
- [ ] BACKLOG entries linked from this plan
- [ ] CHANGELOG slot reserved for PR-22 and PR-23
- [ ] Branch strategy confirmed: feature branch off `emdash/spotty-eels-shock-ngj6f` for each PR (per PR-15-19 pattern)
