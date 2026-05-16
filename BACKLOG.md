# Backlog — Deferred Findings

Findings deferred from in-progress work that are out of the current session's
scope. Items here are valid but not blocking the current change; they should
be picked up in a follow-up PR.

Each item lists: **source** (where it came from), **severity**, **file:line**
(approximate at time of capture — verify before fixing), and a short summary.

When fixing an item, remove it from this file in the same commit.

---

## Security & correctness (cross-review)

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

- **SHOULD-FIX — Migration warning for dotted legacy workspaces / agents is log-only.**
  `app/Sources/JamfReports/Services/ProfileService.swift` (discoverLocal) +
  `app/Sources/JamfReports/Services/LaunchAgentService.swift` (dottedLegacyAgents).
  Both helpers emit `AppLogger.engine.warning` listing the affected
  names. A user who upgrades to PR-3 and finds a profile or schedule
  missing has no in-app indication of why or what to do. Route the
  flagged names through a `WhatsNewBanner`-style first-launch
  surface, or a `Settings → Diagnostics` panel that lists "legacy
  workspaces needing rename" and "legacy schedules needing manual
  removal", with an "open in Finder" affordance for the workspace
  case.
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
list (which scoped to `CLIBridge.swift`), so PR-2 ships narrow and
these are tracked here for a follow-up PR. Risk profile is lower
than the routine `collect`/`audit`/`backup` paths: each is a single
spawn at a well-defined moment (startup, install/upgrade, sidebar
load) protected by the install-time + onboarding-time gates.

- **SHOULD-FIX — `ProfileService.discoverJamfCLIProfiles` spawns `jamf-cli config list` without codesign gate.**
  `app/Sources/JamfReports/Services/ProfileService.swift:143`.
  Single spawn at sidebar-profile-load time. Same fix pattern.
- **CONSIDER — `runDeviceDetailProcess` codesign-gate rejection is `AppLogger`-only.**
  `app/Sources/JamfReports/Services/CLIBridge.swift:1515-1525`.
  No `onLine` consumer at this layer so the Runs feed doesn't
  surface a `[fatal] jamf-cli signature verification failed`
  message for the per-device-detail path. Users see a silent
  failed lookup. Thread an optional `onLine` parameter through
  `singleDeviceDetail` → `runDeviceDetailProcess` so the rejection
  reaches the same diagnostic feed as `run`/`runAndCapture`.
- **CONSIDER — Exit code `-1` is overloaded between codesign-gate rejection and process-launch failure.**
  `app/Sources/JamfReports/Services/CLIBridge.swift` (run, runAndCapture, runDeviceDetailProcess).
  User-facing `LogLine` text already distinguishes the two, but
  programmatic callers (tests, `runMulti` aggregation, future
  retry logic) can't differentiate gate rejection from a crash at
  launch. Consider a distinct sentinel (e.g. `-2`) or a typed
  error return.

### From python-reviewer audit of wave 1+2 (2026-05-14)

- **SHOULD-FIX — Partial runs render as `.ok` in the Runs screen.**
  `app/Sources/JamfReports/Services/RunHistoryService.swift:49–52`.
  `parseLogTail` classifies a run by exit code: 0 → `.ok`, non-zero →
  `.fail`. Wave 2 introduced partial-success runs that exit 0 but write
  `status: "partial"` to `summary.json` and emit a `[partial]` log line.
  The Runs screen shows a green OK pill on a partial run, so an operator
  scanning the history won't see the data-quality issue. Surface the
  partial state by either (a) parsing the `[partial] Report written…`
  marker out of the log tail and adding a `.partial` case to
  `Schedule.LastStatus`, or (b) reading `summary.json` next to the log
  to determine the status. The first option matches the design-review
  pill-icon work for color-blind safety. (Discovered: python-reviewer
  audit, 2026-05-14.)

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

- **SHOULD-FIX — Device detail silently falls back to cached after live
  fetch failure with no stale indicator.**
  `app/Sources/JamfReports/Services/CLIBridge.swift:646`,
  `app/Sources/JamfReports/Views/DeviceLookupView.swift:356`. Surface
  "cached/stale" in the view.

- **SHOULD-FIX — Config saves swallowed in user paths.** `try?` instead of
  user-visible errors at
  `app/Sources/JamfReports/Views/CustomizationWizard.swift:356` and
  `app/Sources/JamfReports/Views/WorkspaceView.swift:64`.


### From Google Gemini 3 security-review (2026-05-12)

- **MEDIUM — Pin Python dependency hashes.** `requirements.txt` currently
  has version pins but no hashes. Add `--require-hashes` workflow (generated
  via `pip-compile --generate-hashes` or equivalent) to mitigate supply-chain
  tampering.

- **MEDIUM — SHA-256 digest JSON snapshots at collection, verify at
  generation.** Detect tampering of cached `jamf-cli-data/*.json` between
  collection and report generation. Threat-model T-2.

- **LOW — UI banner when last successful live collection is significantly
  older than the expected interval.** Currently the staleness threshold is
  in code but not surfaced in the UI. Threat-model T-8.

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

- **SHOULD-FIX — Log redaction layer for `RunHistoryService`.**
  Run logs surfaced by `RunsView` are read through
  `RunHistoryService.loadLog(_:)` and fed to clipboard exports and
  on-disk file exports without any sanitization pass. jamf-cli output
  is supposed to redact tokens, but a misbehaving subprocess or a
  future debug-mode flag could echo secrets to stderr. In a CBP /
  government context this is a real exfiltration path via accidental
  paste or shared log file. Design: add a redaction filter to
  `RunHistoryService.loadLog` (or a sibling `loadRedactedLog`) that
  scrubs known sensitive patterns (Bearer tokens, OAuth client
  secrets, Basic auth headers, anything that looks like a JWT). Apply
  the redacted form to both clipboard and file exports. Keep the raw
  file on disk untouched — admins still need to investigate runs.
  Need a policy doc on which patterns to match (false-positive cost
  matters) before implementing.

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
  brighter coral or bump `codeBG` toward fully black. Update
  `accessibility-audit.md` either way.

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
