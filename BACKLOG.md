# Backlog — Deferred Findings

Findings deferred from in-progress work that are out of the current session's
scope. Items here are valid but not blocking the current change; they should
be picked up in a follow-up PR.

Each item lists: **source** (where it came from), **severity**, **file:line**
(approximate at time of capture — verify before fixing), and a short summary.

When fixing an item, remove it from this file in the same commit.

---

## Security & correctness (cross-review)

### From post-PR-8 review batch (2026-05-16)

Findings deferred from the multi-agent review batch that ran after PR-8
landed. PR-9 closed five MUST-FIX items (api_key/apikey free-text
redaction in both LogRedactors, M-01 4th codesign-gate site at
`isTrustedJamfCLIExecutable`, `_emit_summary_json` CSV-path `patchPct`
false-zero, `LaunchAgentService.checkSummaryFileForPartialStatus` test
coverage, and dead-code docstring on the summary.json branch). The items
below are valid follow-ups.

- **MEDIUM-1 — `AuditView` drift diff silently treats previous-snapshot
  decode failure as "no previous".** `AuditView.swift:565`. Use explicit
  `try/catch` with `AppLogger.app.warning`.
- **MEDIUM-2 — `HtmlReport+Sections.swift:1001` Protect-insights JSON
  parse silently returns `[]`.** Add an explicit guard + warning. Family:
  N-07.
- **CONSIDER-1 — `MigrationBanner.onDismiss: {}` no-op leaves
  `legacyWorkspaces`/`legacySchedules` populated in `@State`.** Pass a
  closure that clears both arrays.
- **CONSIDER-2 — `main.swift:95` diagnostic prints `0` for unreadable
  directory, same as empty.** Split try/catch so an unreadable dir is
  not silently equivalent to an empty one.
- **CONSIDER-3 — `_emit_summary_json:2420-2430` swallows both
  `JSONDecodeError` and `ValueError` in a single catch.** Split so the
  parse-failure path can emit a distinct warn line.
- **SHOULD-FIX (upgrade) — `runDeviceDetailProcess` codesign-gate
  rejection is `AppLogger`-only.** The existing entry from "From PR-2
  review (2026-05-15)" (the first CONSIDER) is now upgraded to
  **SHOULD-FIX** based on the post-PR-8 review's HIGH-1 finding. The
  per-device-detail path produces a silent failure with no Runs-feed
  diagnostic, and the upgrade reflects that the silent-failure cost is
  higher than originally assessed.
- **CONSIDER — Codesign-gate happy-path test missing.** All three PR-6
  gate tests (`ProvenanceCodesignGateTests`,
  `JamfCLIInstallerCodesignGateTests`, `ProfileServiceCodesignGateTests`)
  and PR-9's `testIsTrustedJamfCLIExecutableEnforcesCodesignGate`
  exercise the rejection path. None confirm the gate accepts a properly
  signed binary. Add a happy-path test pinned to a known signed system
  binary (e.g., `/usr/bin/codesign` itself) under a stub `expectedTeamID`.
- **CONSIDER — `DeviceLookupView` `staleSince` wiring assumes a
  non-nil snapshot timestamp.** Audit the `snapshotMTime` path for the
  "no manifest, no cache" first-launch state; the view should not crash
  or render a NaN relative-time when both inputs are absent.

### From PR-1 cleanup (2026-05-16)

- **CONSIDER — `LaunchAgentService.parse()` reads CLI flags the current writer no longer emits.**
  PR-1 closed the `--base-profile` orphan (writer stopped emitting it
  in commit 9aa5124, May 9; parser + tests removed in PR-1's `a2296ed`).
  Discovered during that cleanup: the parser at
  `app/Sources/JamfReports/Services/LaunchAgentService.swift` still
  reads `--mode`, `--multi-filter`, `--multi-profiles`,
  `--multi-sequential`, and the `multi-launchagent-run` subcommand
  keyword from existing plists, but the current `nativeMultiWrite`
  (in `LaunchAgentWriter.swift`) only emits `--scheduled-run`,
  `--profile`, `--all-profiles`. Same shape as the closed orphan:
  writer stopped, parser still reads. Won't break anything today
  (no current plist contains those flags), but the inconsistency is
  the same class of bug. Audit each orphan parser arm and either
  remove or document why it's load-bearing for pre-9aa5124 plists.

### From PR-A review gates (2026-05-16)

Three deferred items from the security-reviewer + silent-failure-hunter
gates on PR-A. The four MUST-FIX findings landed in the same PR
(workspace path leak, on-prem hostname coverage, dead config-keys set,
username/device-name flag coupling). These are out-of-scope.

- **CONSIDER — `_PII_JSON_KEYS` missing extra device/identity keys.**
  Security-reviewer B-1. Current set covers `serial`, `serialNumber`,
  `computerName`, `hostname`, `email`, `username`, etc. Misses `device`,
  `name`, `realName`, `ipAddress`, `udid`, `managementId`, `position`,
  `room`, `building`, `department`. Not a live leak in the current
  bundle scope (only `summaries/` and `automation/logs/` are collected;
  raw jamf-cli-data is excluded). Becomes a live leak if (a) the bundle
  scope expands to include jamf-cli-data, OR (b) `LogRedactor` gets
  reused for `RunHistoryService` log redaction (the deferred Gemini
  finding). Close before either change.
- **CONSIDER — `workspace_tree.txt` does not run through the redactor.**
  Security-reviewer B-1. Tree entries currently use timestamp-based
  filenames (low PII risk), but if users add custom CSV files with
  device names or serials in the filename, those leak. Wire the
  redactor through `_bundle_collect_workspace_tree` so filenames go
  through `redact_text`.
- **CONSIDER — `client_id` shorter than 16 chars bypasses the alphanumeric branch.**
  Security-reviewer S-3. Jamf Pro generates UUID client_ids (36 chars
  with dashes — always matched by the first branch), so this is a
  narrow gap. If a user has a manually-configured shorter client_id,
  it would leak. Lower the floor to 8 chars OR add a comment
  explaining the deliberate tradeoff.

### From PR-8 council (2026-05-15)

`/council` ran on the S-06 Templates refactor (the budgeted judgment-call
invocation for the 10-PR sequence). All three external voices (Skeptic,
Pragmatist, Critic) aligned 3-1 against landing the refactor as REPORT.md
describes. Key load-bearing dissent: Critic surfaced that `TemplateApplier
.apply()` is `@MainActor` to guard `WizardState` mutation, and moving the
four switches onto a `Sendable` protocol would force either viral
`@MainActor` annotation or silent loss of the isolation guarantee — a
Swift 6 strict-concurrency regression. Council also rejected C-13 as
misdiagnosed (`SummaryJSONParser` is a useful namespace, not over-
engineering). Items routed here:

- **CONSIDER (S-06 deferred) — Audit whether each of `TemplateApplier`'s 4 switches is actually per-template, or per-*category*.**
  Skeptic's challenge: `keepLatestRuns` and `recommendedStaleDays` may
  not vary by template — they may vary by audience-category (executive
  vs operational vs auditor) and could collapse to a single default +
  override map for outliers. If true, the right move is **deletion** of
  1-2 switches, not relocation. Spike before any future refactor.
- **CONSIDER — C-13 (`SummaryJSONParser` wrapper struct) is disputed.**
  REPORT.md flagged the 30-line struct as over-engineered. Investigation
  during PR-8 found it provides a useful namespace for `dateFormatter`
  (consumed at 8 callsites in `AccessibilityDescriptors`, `TrendsView`)
  plus two static methods (`parse`, `parseDirectory`) called from
  `FleetOverviewView` and `Sidebar`. Inlining would either pollute the
  global namespace or require verbose renames at every callsite. Leave
  alone unless a stronger reason surfaces.

### From PR-6 review (2026-05-15)

Two follow-up items from the silent-failure-hunter / pr-review-toolkit
review gates that PR-6 deferred per the per-PR scope rules.

- **CONSIDER — Decoder tests assert via field values rather than negative key-mapping cases.**
  Each decoder test asserts on the decoded struct's field values. PR-6
  verified failing-test-first by perturbing
  `PolicyFinding.policyId = "policy_id"` and observing `keyNotFound`,
  then reverting. Future tests could lift the keyNotFound case into an
  explicit `XCTAssertThrowsError` negative assertion alongside the
  positive case. Pre-existing pattern across the decoder test file;
  low priority. Reviewer CONSIDER #3.

### From PR-5 review (2026-05-15)

Three scope-adjacent items surfaced during the zero-warnings +
fixture cleanup PR. PR-5 itself addressed S-05, S-07, C-01 fully;
these are pre-existing patterns the review gates noticed in the
touched files.

- **SHOULD-FIX — `OutputValidatorTests.writeTempFile` silently swallows write failures.**
  `app/Tests/JamfReportsTests/OutputValidatorTests.swift:281`.
  Helper uses `try? content.write(to:atomically:encoding:)` so a
  filesystem error during test setup produces a misleading
  XCTSkip or wrong-path assertion rather than a clear test
  failure. Replace with `try` + a descriptive XCTFail on error.
- **CONSIDER — Programmatic XLSX tests don't round-trip through the production writer.**
  `app/Tests/JamfReportsTests/OutputValidatorTests.swift:185-206`.
  `testProgrammaticXLSXPassesValidation` builds a synthetic XLSX
  via the test helper, not via `XLSXWriter`. The original golden
  fixture would have caught writer regressions; the programmatic
  variant only catches validator regressions. Add a round-trip
  test: generate via production writer, validate, assert no
  errors.
- **CONSIDER — `fixtureData(kind:)` picks `files.first` with undefined directory ordering.**
  `app/Tests/JamfReportsTests/Engine/CoreDashboardSecurityTests.swift:39`.
  Single fixture per kind today; if a kind grows a second file
  (the update-status variants dir is the canonical example), the
  test could pick the wrong one non-deterministically. Either
  sort lexicographically before `.first` or accept a filename
  parameter.

### From PR-3 review (2026-05-15)

silent-failure-hunter flagged two scope-adjacent items during the
S-03 (dotted-profile rejection) review. PR-3 closed the structural
bug at both the writer and parser; these items are about how the
migration is *surfaced* to the user, not whether the bug is closed.

- **CONSIDER — `LaunchAgentService.removeAgents(profile:)` silently returns `[]` for dotted legacy profile names.**
  `app/Sources/JamfReports/Services/LaunchAgentService.swift:55-56`.
  The guard `ProfileService.isValid(profile)` is correct for new
  operations but means programmatic cleanup of a legacy dotted name
  (e.g. during demo-mode teardown that pre-dated the fix) silently
  no-ops. Either log a warning when the guard rejects, or offer a
  separate `removeLegacyAgent(byLabel:)` API that operates on the
  full label string for migration cleanup. Plists from dotted-profile
  schedules continue to fire via launchd until manually `bootout`-ed.

### From PR-3 follow-up review (2026-05-16)

Review gates on the keyboard-navigation fix for PR-3's roving
tabindex flagged one CONSIDER item adjacent to the HTML tab markup.

- **CONSIDER — `.cat-toggle` disclosure buttons lack `aria-controls`.**
  `jamf-reports-community.py:14652`. The category disclosure buttons
  in the deployment-hierarchy tree panes set `aria-expanded` but the
  `.cat-items` panel they toggle has no `id` and no `aria-controls`
  pointer from the button. Widely tolerated for disclosure widgets so
  not a WCAG failure, but the ARIA APG recommends the association.
  Fix: give each `.cat-items` div a stable `id` (derive from the
  category label slug, scope-prefixed to avoid cross-tab collisions)
  and add `aria-controls="<panel-id>"` to the matching `.cat-toggle`.
  Touch in PR-4 polish.

### From PR-2 review (2026-05-15)

Code-reviewer flagged three additional `jamf-cli` spawn sites that
bypass the M-01 codesign gate. None are in REPORT.md M-01's named
list (which scoped to `CLIBridge.swift`), so PR-2 shipped narrow and
PR-6 closed the three SHOULD-FIX items below. Risk profile is lower
than the routine `collect`/`audit`/`backup` paths: each is a single
spawn at a well-defined moment (startup, install/upgrade, sidebar
load) protected by the install-time + onboarding-time gates.

- **CONSIDER — `runDeviceDetailProcess` codesign-gate rejection is `AppLogger`-only.**
  `app/Sources/JamfReports/Services/CLIBridge.swift:1515-1525`.
  No `onLine` consumer at this layer so the Runs feed doesn't
  surface a `[fatal] jamf-cli signature verification failed`
  message for the per-device-detail path. Users see a silent
  failed lookup. Thread an optional `onLine` parameter through
  `singleDeviceDetail` → `runDeviceDetailProcess` so the rejection
  reaches the same diagnostic feed as `run`/`runAndCapture`.
  Deferred from PR-6: callsite count is 6 across 3 non-CLI view
  files (`CustomizationWizard.swift`, `DeviceLookupView.swift`,
  `DevicesView.swift`), tripping the per-PR rule on parameter
  threading scope. Needs separate PR.
- **CONSIDER — Exit code `-1` is overloaded between codesign-gate rejection and process-launch failure.**
  `app/Sources/JamfReports/Services/CLIBridge.swift` (run, runAndCapture, runDeviceDetailProcess).
  User-facing `LogLine` text already distinguishes the two, but
  programmatic callers (tests, `runMulti` aggregation, future
  retry logic) can't differentiate gate rejection from a crash at
  launch. Consider a distinct sentinel (e.g. `-2`) or a typed
  error return. Deferred from PR-6: architectural change touches
  every spawn-site call path and downstream aggregator (runMulti,
  RunHistoryService classifier). Recommendation: introduce a typed
  `CLIBridgeError.codesignRejected(executable: URL)` thrown by a
  new `runOrThrow`/`runAndCaptureOrThrow` surface; keep the
  Int32-returning surface backward-compatible. Needs separate PR
  with an ADR.

### From python-reviewer audit of wave 1+2 (2026-05-14)

### From PR-8 (2026-05-16)

- **CONSIDER — Stale-data banner rollout to remaining 5 services.**
  PR-13 closed the caller-first half: shared `StaleDataBanner` component
  shipped at `app/Sources/JamfReports/Theme/StaleDataBanner.swift` with
  the `CacheSource` enum + `CacheSourceProviding` protocol seam at
  `app/Sources/JamfReports/Services/CacheSource.swift`, wired into
  `TrendsView` and `OverviewView` via `TrendStore.cacheSource`, and
  migrated `DeviceLookupView` to the shared component. The five
  remaining cached-data surfaces still render the most recent snapshot
  with no freshness indicator: `PolicyHealthService` →
  `PolicyProfileView`, `CompliancePostureService` →
  `CompliancePostureView`, `SecurityPostureService` →
  `SecurityPostureView`, `MobileFleetService` → `MobileFleetView`,
  `ProtectDashboardService` → `ProtectView`. Each service needs its
  Snapshot/Result struct to gain a `cacheSource: CacheSource` field
  (sourced from the underlying snapshot file's mtime), then a one-line
  `StaleDataBanner(source: snapshot.cacheSource)` insertion above the
  primary card on each view. ~15 lines per service. `PatchStatusService`
  and `UpdateStatusService` from the original PR-8 list dropped because
  they surface a "snapshot date" in their hero header already — verify
  before adding. Gemini threat-model T-8.

### From in-session bug fixes

- **SHOULD-FIX — `LaunchAgentWriter.nativeManualRunPlan` has no round-trip
  test.** A bug (fixed 2026-05-13) silently broke "Run now" by validating
  `StandardOutPath` against the wrong directory:
  `expectedMultiLogURL(label, "").deletingLastPathComponent()` strips the
  label folder. The functions involved (`manualRunPlan`,
  `nativeManualRunPlan`) are `private`; adding a regression test requires
  promoting one to `internal` or adding a `#if DEBUG` test seam. The right
  test writes a plist via `nativeSingleWrite` and round-trips it through
  the manual-run validator to confirm path agreement.

### From Codex GPT-5.5 security-best-practices review (2026-05-13)

- **SHOULD-FIX — Summary builders zero-fill on decode failure (Python side
  only — Swift side resolved 2026-05-13).** Python
  `jamf-reports-community.py:2465,2480,2507`. The Swift sites at
  `app/Sources/JamfReports/Engine/ReportEngine.swift:307,338,362` for
  `fileVaultPct` / `osCurrentPct` / `patchPct` were pulled out and fixed:
  fields are now `Double?`, decoder uses `decodeIfPresent`, ReportEngine
  initializes to `nil`, and consumers (`SecurityScoreCalculator`,
  `FleetOverviewView`) `guard`-unwrap. Python side still pending.

### From Google Gemini 3 security-review (2026-05-12)

### From WCAG 2.2 AA accessibility audit (2026-05-15)

Two-surface audit covering the SwiftUI app and the HTML report
(`HtmlReport` in `jamf-reports-community.py`). Findings categorized by
severity; SwiftUI items reference Apple HIG accessibility APIs, HTML items
cite WCAG 2.2 Success Criteria.


**HTML report — MUST-FIX**

_(All six MUST-FIX items resolved in PR-3 — landmarks/headings, table
scope/caption, security-cell glyphs, trend SVG data table, tablist
ARIA, and contrast/focus-visible.)_

**SwiftUI — SHOULD-FIX**

_(All items resolved in PR-4.)_

**HTML report — SHOULD-FIX**

- **Generic "Open" link text per row.**
  `jamf-reports-community.py:14442,14467`. Each row's "Open" reads
  identically in a SR links list. Add
  `aria-label="Open {device name} in Jamf Pro"` (SC 2.4.4).

- **Reflow on narrow viewports.** `jamf-reports-community.py:13790-13796`.
  `overview-table` and `mobile-inventory` aren't wrapped in
  `.table-wrap { overflow-x: auto }`. Only `.data-table` (flagged
  devices) is wrapped. Fails SC 1.4.10 on 320 CSS-px width.

- **Dark-mode toggle missing `aria-pressed`.**
  `jamf-reports-community.py:14070-14072`. Update in `applyDark()`.

- **Sortable headers missing `aria-sort`.**
  `jamf-reports-community.py:14472-14474`. Add to the `<th>` and
  update in JS sort handler at `:14163-14177`.

**CONSIDER**

- **Dynamic Type:** ~14 fixed `.font(.system(size: N))` calls in
  `Views/PatchView.swift`, `Views/OnboardingView.swift`,
  `Views/FleetOverviewView.swift`, `Views/ExtensionAttributesView.swift`,
  `Views/ConfigView.swift`. Migrate body/label content to semantic
  styles. Keep chart axis ticks fixed.

- **Reduce Motion gaps:** `Theme/Components.swift:323` (`PNPToggle`
  `withAnimation(.snappy(...))` unconditional).

- **HTML `prefers-reduced-motion`:** `.sec-bar-fill` transition at
  `jamf-reports-community.py:13873` and `.dark-toggle` at `:13761`
  animate unconditionally.

- **HTML print stylesheet:** `@media print` to hide toolbar buttons,
  dark toggle, and search inputs for PDF saves.

- **HTML skip-link:** sticky topbar + no skip-link makes keyboard
  navigation slow.

- **Theme contrast ratios:** `Theme/ThemeSemanticTokens.swift` defines
  opacity scales but no documented WCAG ratios. A pass with Stark / axe
  on every token pair (especially dark-mode badge variants) would let
  us cite numbers — the audit's contrast estimates are mental
  arithmetic, not tool output.

- **No accessibility tests:** project has good Swift test coverage but
  nothing asserting accessibility. Worth a XCTest pass that builds
  each Chart and asserts an `AXChartDescriptor` is wired up, or
  snapshot-tests VoiceOver labels for key components.

### From Google Gemini cross-review of design-review-3 (2026-05-14)

- **CONSIDER — Dynamic Type 300% audit on `OverviewView`.** Wave 1's
  Dynamic Type pass (commits `08148c1`, `17bfb63`, etc.) covered the
  font-token swaps but didn't verify the visual layout at 300% scale.
  Walk OverviewView with Larger Text bumped to maximum and confirm
  none of the critical KPI metrics truncate or clip into adjacent
  cards. Manual visual audit — no automatable test.

- **CONSIDER — Verify `dangerSoft` (`#FFA39A`) contrast against
  `codeBG` (`#0E0F12`).** The `dangerSoft` / `warnSoft` tokens added
  in wave 1 commit `3229dd1` were tuned for Pill backgrounds, then
  also used on the log-console surface (`Theme.Colors.codeBG`).
  Re-check contrast on the new background — if `dangerSoft` falls
  below AA Normal (4.5:1) against `codeBG`, choose a slightly
  brighter coral or bump `codeBG` toward fully black.

---

## Code hygiene (from in-session reviews — deferred)

- **CONSIDER — WHAT-comments in build scripts.** A handful of restate-the-code
  comments (e.g. `# Notarize when: ...` immediately above the conditional that
  expresses the same thing). Drop on next pass through the scripts.

### From PR-4 review gates (2026-05-16)

- **CONSIDER — DeviceLookupView chevron not `.accessibilityHidden(true)` after `.combine`.** `app/Sources/JamfReports/Views/DeviceLookupView.swift:~201`. After `.accessibilityElement(children: .combine)`, the `Image(systemName: "chevron.right")` and the Pill's internal icon may be appended to the combined label depending on SwiftUI version. Hide both with `.accessibilityHidden(true)`.
- **CONSIDER — SourcesView "Full Admin scope" hint is misleading.** `app/Sources/JamfReports/Views/SourcesView.swift:~402`. Current hint "Elevates API privileges to full admin access in Jamf Pro" reads as a server-side privilege grant; actual implementation writes a local UserDefaults key. Consider rephrasing to "Unlocks destructive app operations for this profile" or similar.
- **CONSIDER — HTML category slug collision within a tab pane.** `jamf-reports-community.py:14675`. Slug derivation via `re.sub(r'[^\w\-_]', '_', category.lower().strip())` collides for `"Mac Setup"` vs `"Mac/Setup"` etc. Append an enumerate counter when a slug has been seen in the same pane to satisfy HTML id-uniqueness.
- **CONSIDER — PNPToggle 24pt hit-area expands 2pt beyond 22pt visible capsule.** `app/Sources/JamfReports/Theme/Components.swift:~351`. Per CLAUDE.md anti-churn discipline, SwiftUI layout primitive changes need visual verification at `PageScaffold.minSupportedWidth`. Verify in a follow-up session that adjacent UI elements don't overlap the expanded hit zone.

### From PR-4 in-flight discovery (2026-05-16)

- **CONSIDER — RunsView dynamic status live-region trait — PR-4 closed the SchedulesView and StatusBar bullets but RunsView was not actually edited; needs a follow-up locate of the live status text site.** RunsView contains only static status pills (`.ok`, `.fail`) that don't update frequently, not live updating text like "Running…" or "Collecting…" that would warrant `.updatesFrequently` trait.
- **CONSIDER — `swift test` fails 21 `CoreDashboardTests` / `SchoolDashboardTests` only inside `.claude/worktrees/` paths.** Reproduces at the merge-base SHA (`56bfbe7`) inside the agent worktree path, but the same SHA passes 1349/1349 in `/Users/alyoung/emdash/worktrees/...` and `/tmp/pr4-validate`. Fixtures are byte-identical (md5 verified); no sparse checkout, no LFS, no symlinks. Likely culprit area: SwiftPM `#filePath`/sandbox interaction with `.claude/` parent path, or `FileManager.copyItem` silently truncating under that prefix. All 21 failures are `XCTAssertNoThrow failed: threw error "noCachedData(names: [...])"` from `loadLatestJSONData`. Not blocking — `swift test` from any non-`.claude/` worktree works fine, so CI is unaffected. Worth investigating before the next time subagents work in `.claude/worktrees/` to avoid silent false-negative test reports.

### From PR-5 in-flight discovery (2026-05-16)

- **CONSIDER — Mobile parser's `name` fall-back chain doesn't include top-level `name`.**
  `app/Sources/JamfReports/Services/DeviceLookupIndex.swift:172-176`.
  The mobile-device parser resolves `name` via `general.displayName →
  general.name → dict["displayName"] → rawID` — it does NOT read
  top-level `name`. The committed mobile-devices-list fixtures at
  `tests/fixtures/jamf-cli-data/mobile-devices-list/*.json` use top-level
  `name` exclusively (no `general` wrapper), so under those fixtures
  every mobile candidate gets `name == id`. Either (a) the fixtures
  reflect real jamf-cli output and the parser misses every mobile name,
  or (b) the fixtures are stale / over-sanitized and the parser is
  correct. Verify which shape `jamf-cli mobile-devices-list --output
  json` actually emits and fix whichever side is wrong. Surfaced during
  PR-5 Item 1 (DeviceLookupIndex tests).
- **CONSIDER — `generateAll` exit-5/exit-6 fallback and partial-success branches lack test coverage.** PR-5 covers the
  unauthorized short-circuit (exit 3) and the `GenerateAllResult` struct
  semantics via real-CLIBridge tests gated on `ExecutableLocator.locate("jamf-cli")`.
  The exit-5 (permission denied) and exit-6 (rate-limited) collect-fallback
  branches, and the partial-success path (one type succeeds, another fails
  with a non-3 exit code), need synthetic exit codes from `collect` /
  `generate` / `generateHTML` to exercise. Closing this gap requires a
  `CLIExecutor`-style protocol seam over those four `CLIBridge` methods —
  `CLIBridge` is currently `final` and routes them directly. The seam is
  real architectural scope (not a test-only change) and was deferred from
  PR-5 to keep that PR purely test-infrastructure.

### From PR-5 review gates (2026-05-16)

- **CONSIDER — `TemplateApplier` tripwire cannot discriminate cases that return the default value.** `app/Sources/JamfReports/Services/TemplateApplier.swift`. `recommendedThresholds.case "operational"` returns `(80, 90)` which equals the `default:` arm; `recommendedStaleDays.case "compliance"` and `case "executive"` both return 30 which equals the `default:` arm. Behavioral tests in `TemplateApplierTests.swift` cannot detect deletion of these named cases — the dispatched value is the same whether the case fires or fall-through hits default. The tripwire is sound for cases with distinguishing values; the limit is fundamental to behavioral testing and documented in the test method comments. Address via either (a) refactor switches to a tagged-return that always carries the source-case identifier, (b) source-level AST inspection in tests, or (c) accept the limit and rely on PR review for these specific cases. Tracking alongside the broader S-06 templates refactor the council deferred (see "From PR-8 council (2026-05-15)").
- **CONSIDER — Dead inline `defer` in `CompliancePostureTests.swift:86`.** `testCompliancePostureRendersWithFixtureData` does `let dataDir = try tempDataDir(copying: ...)` (helper that appends to `createdTempDirs`) and then `defer { try? FileManager.default.removeItem(at: dataDir) }`. The new `tearDown` already removes it; the inline `defer` is redundant. Six other `defer` sites in the same file ARE legitimate (direct-callsite `tmp`). Drop the line; no behavior change.
- **CONSIDER — `testNewestJSONWinsWhenMultipleSnapshotsExist` doesn't verify `name` parsing.** `app/Tests/JamfReportsTests/DeviceLookupIndexTests.swift:78-109`. Asserts the set of `id`s but never checks `name` — leaves the parser's `name` fall-back chain unverified for the bare-array computers path. The dedicated `testBareArrayDecodes` does pin name resolution for a single record, so the gap is narrow. Cheap to strengthen later by asserting both `id` and `name` in the multi-snapshot test.

### From PR-6 review gates (2026-05-16)

- **CONSIDER — PR-6 gate-rejection tests do not assert `AppLogger.cli.error` emission on rejection.** `app/Tests/JamfReportsTests/ProvenanceCodesignGateTests.swift`, `JamfCLIInstallerCodesignGateTests.swift`, `ProfileServiceCodesignGateTests.swift`. Each test only asserts the nil/fallback return. `CLIBridge.codesignGate` emits `AppLogger.cli.error(...)` on rejection (`CLIBridge.swift:1381`), and that log is the only forensic signal available post-incident on a security boundary. A regression that silences the log without breaking the return path would pass all three tests. Closing this gap needs a log-capture seam in the test target (more than 3 lines, touches test infra). Address alongside future security-test hardening.
- **CONSIDER — `onLine: { _ in }` no-op closure repeated at 3 new spawn sites.** `app/Sources/JamfReports/Engine/Provenance.swift`, `JamfCLIInstaller.swift`, `ProfileService.swift`. Mirrors the existing CONSIDER from "From PR-2 review (2026-05-15)" for `runDeviceDetailProcess` — non-Runs-feed spawn sites have nowhere to thread `LogLine`. Worth folding into the same future `onLine`-threading PR (or a typed-error PR per BACKLOG item 5) rather than three more separate fixes.
- **CONSIDER — Gate-rejected `jamf-cli` binary shows no UI version warning.** `app/Sources/JamfReports/Services/JamfCLIInstaller.swift:169-173`. When `installedVersion(at:)` returns nil due to a gate rejection, `isBelowMinimumSupported(nil)` returns false (guard returns early). Any UI surface that fires the "below minimum version" warning (Settings, onboarding) produces no warning. Existing design choice ("don't nag users when version detection itself failed") is reasonable, but the gate is now an additional reason version detection can fail and the user sees nothing. The only signal is `AppLogger.cli.error`. Consider a dedicated "verification failed" state in `currentInstallation()` that surfaces a Settings notice distinct from "version unknown".

### From PR-7 review gates (2026-05-16)

Six deferred items from the silent-failure-hunter, pr-review-toolkit, and
security-reviewer gates on PR-7. The critical (CR-1), must-fix (M-1, M-2,
M-3), and should-fix (S-1) items landed in-PR as separate commits; the
items below are valid but out of scope.

- **CONSIDER — Config-save error message includes raw `error.localizedDescription` which may expose filesystem paths.** `app/Sources/JamfReports/Views/CustomizationWizard.swift:376`, `app/Sources/JamfReports/Views/WorkspaceView.swift:84`. `NSError` from FileManager write failures typically includes the full destination path (e.g., `/Users/jdoe/Jamf-Reports/corp-prod/config.yaml`). On government workstations where screenshots are shared for troubleshooting, this leaks home directory + profile name. Map to a sanitized user message ("Could not save config.yaml in profile '<profile>'.") and log the full error via `AppLogger` at debug level only.
- **CONSIDER — Stale banner uses attacker-controllable file mtime.** `app/Sources/JamfReports/Views/DeviceLookupView.swift:464-468`. `snapshotMTime` reads `contentModificationDate` from the cache file, which `touch -t` can falsify. If T-2 (cache tampering) is in scope, the banner could be suppressed by an attacker. Mitigation: extend the manifest schema to include a `generated_at` timestamp; banner reads from the manifest, not mtime. Schema change deferred to a future PR.
- **CONSIDER — `_load_json_snapshots` (and `RunHistoryService.loadLog`) redact line-by-line; multi-line secrets evade the filter.** A token split across newlines would survive both Python trend redaction and Swift run-log redaction. Extremely low probability for jamf-cli structured output (single-line JSON lines) but technically present.
- **CONSIDER — `CLIBridge.deviceDetail` / `mobileDeviceDetail` wrappers preserved alongside `*WithProvenance` variants.** `app/Sources/JamfReports/Services/CLIBridge.swift:651,683`. Wrappers are real callers (`DevicesView.swift:891`, `CustomizationWizard.swift:1283`), not orphans. Per CLAUDE.md "Replace, don't deprecate" — migrate those 2 callsites to the provenance-aware methods in a future PR and delete the wrappers.

### From design-review-fixes-2.md triage (2026-05-17)

Captured before the source doc was deleted. Phases 1–3 of the original
design-review plan were substantially completed by the dev-app/2.0
work; the items below are the open residual from Phases 2, 3, and 5.

- **SHOULD-FIX — Systematize hardcoded `Color(hex:)` literals in non-Theme files (Phase 2.2).** 30+ inline hex color literals remain across `OnboardingView.swift`, `ProtectView.swift`, `GenerateSheet.swift`, `TrendsView.swift`, `ExtensionAttributesView.swift`. The Phase 2.1 severity ramp (`Theme/ThemeSemanticTokens.swift:145-184`) is wired and usable; the cleanup to route all remaining hardcoded hex through Theme tokens has not been systematic. Visual consistency risk across light/dark surfaces. Legitimate-remaining hex is in export-only views and data-driven `band.colorHex`/`tier.colorHex` paths; those are out of scope for this cleanup.
- **SHOULD-FIX — Migrate hand-rolled tables to SwiftUI `Table` (Phase 3.5).** `PolicyProfileView.findingsCard`, `PolicyProfileView.profileStatusCard`, `UpdatesView.failedPlansCard`, `UpdatesView.errorDevicesCard` still use custom `DataTableHeader` / `DataTableRow` HStack rows. VoiceOver semantics are compromised — table columns not announced as table headers. `PatchView.patchTitlesCard` already uses native `Table` and is the reference. Migration also unifies the table look and removes ~200 lines of bespoke table code.
- **CONSIDER — Generalize Increase Contrast support beyond Pill/Sidebar (Phase 5.1).** Only `Pill`, `StatTile`, `EmptyStateView`, and `Sidebar` read `colorSchemeContrast`. `Card`, `Button`, `SegmentedControl`, and 25+ Views do not. The Phase 5.1 proposal called for `Theme.Text.tertiary(contrast:)` accessor functions; those don't exist. Full rollout requires: (a) add Theme accessor functions, (b) thread contrast through ~20 consumer views, (c) audit actual contrast ratios post-bump. Substantial scope; worth a dedicated PR.
- **CONSIDER — Complete Dynamic Type migration (Phase 5.5).** ~40–60% of non-display text still uses `.system(size: N)` pinned sizes instead of semantic fonts (`.callout` / `.footnote` / `.caption`). Remaining sites: most of `ConfigView`, `SettingsView`, `PolicyProfileView`, `ProtectView` data cells, `TrendsView` axis labels, chart numeric labels in multiple dashboards. Pinned serif/mono for display (H1, kicker, metrics) correctly preserved. Largest consumer is ProtectView (~12 instances). Current state is usable; full migration aids users with system Larger Text enabled. Batch into a single pass rather than piecemeal PRs.
- **CONSIDER — `MobileFleetView` uses `"Showing \(N)"` instead of `"Showing N of M"` pattern (Phase 3.3).** Other paginated views (`ProtectView`, `PolicyProfileView`) standardized on "Showing 50 of N"; MobileFleetView is the last holdout. Trivial copy alignment for consistency.

### From post-PR-8 review batch threat model refresh (2026-05-17)

T-11..T-15 from the post-PR-8 review batch are now formally integrated
into `docs/architecture/jamf-reports-community-threat-model.md`
(§6, §7 priority summary). T-16..T-20 cover external-distribution
horizons (notarized DMG + PKG installer) per §11 annex. The doc
includes "Highest-Value Next Actions" recommending T-11 / T-12 / T-13
closure as the top three. Items below are the BACKLOG-tracked code
work to back those recommendations:

### From PR-12 CI run (2026-05-17)

- **CONSIDER — `CLISubcommandTests.testCheckMissingWorkspaceExits1` flaked on PR-12 CI run id `25995830106` (push event), passed in the parallel `pull_request` run on the same SHA `3779fa60`.** Test generates `no-such-workspace-<UUID8>` and asserts exit-1 from `checkConfigForProfile`. Re-run cleared on second attempt. Same SHA producing both PASS and FAIL points at an environmental race (runner home-dir state from a prior run, parallel test interleaving, or a global `~/Jamf-Reports/<profile>` artifact). Worth a defensive guard in `checkConfigForProfile` test harness OR an explicit setUp that nukes any pre-existing workspace dir matching the generated slug.

### From PR-11 security review (2026-05-17)

- **CONSIDER — Cross-run manifest re-hash from disk inherits PR-7 attack window.** `jamf-reports-community.py:670-671`. `_rewrite_snapshot_manifest` re-hashes unpinned existing files from disk when rewriting the manifest. Each `_emit_summary_json` (daily) or `_emit_per_log_summary_json` call rewrites the summaries manifest, causing OTHER existing per-log summaries to be re-hashed from disk at that point. An attacker who tampers a per-log summary between two legitimate writes (e.g., between hot-tier runs ≥15 min apart) gets their tampered content blessed into the manifest on the next sibling run — converting a `.mismatch` into `.verified` for that file. Same residual attack pattern as PR-7's `_save_snapshot` and accepted there. Address with a "pin all known files from a per-run-context cache" approach OR document as accepted residual in the threat model. Inherited from PR-7.

### From post-PR-21 architecture review (2026-05-18)

Items surfaced while answering "does the Swift app replicate the tiered
collection pattern from the Python/zsh reference deployment?" Design
work captured in `docs/architecture/tiered-collection-adr.md`.

- **FEATURE (PR-23) — GUI layer for per-report collection cadence.** PR-22
  landed the engine (CollectionTier, CadenceResolver, StateFileStore,
  `collect_cadence` config, `collect` filtering). PR-23 adds the GUI:
  Schedules-form tier picker, Settings → Performance preset chooser,
  custom-mode per-report editor, onboarding preset prompt, migration
  banner. See `docs/architecture/tiered-collection-plan.md` Phases 2–5.
- **CONSIDER (PR-23 T-16 finding) — `RefreshCoordinator` has no production caller.** `app/Sources/JamfReports/Services/RefreshCoordinator.swift`. `observeProfileSwitch`, `registerForegroundRefresh`, and `WorkspaceStore.triggerRefresh` are not invoked from any View, the app entry point, or `WorkspaceStore`'s profile-switch path — the whole backfill subsystem is unwired. Pre-existing (predates PR-22). T-16 retargeted it to `CollectionTier` per the plan so `ScheduleTier` could be deleted, but did not wire it. ADR Q1 envisions `RefreshCoordinator` as the "backfill if overdue" mechanism — wiring `observeProfileSwitch` into the sidebar profile chip and `registerForegroundRefresh` into app launch is the natural follow-up. Until then, `RefreshCoordinator` + `RefreshPolicy` + `RefreshCoordinatorTests` exercise code nothing calls.

---

## Process

Add to this file:
- Any review finding (LLM, human, tooling) that is valid but out of scope for
  the current change.
- Anything you'd otherwise track in scattered TODO comments.

Remove from this file:
- When fixing an item, delete its bullet in the same commit that fixes it.
- When a finding is determined invalid on closer review, delete it with a
  one-line note in the commit message explaining why.

Do not:
- Use this as a long-term issue tracker — items should be either fixed or
  rejected within a few PRs. If it lives here for a quarter, it's not a
  backlog item, it's a decision deferred.
