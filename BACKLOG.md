# Backlog — Deferred Findings

Findings deferred from in-progress work that are out of the current session's
scope. Items here are valid but not blocking the current change; they should
be picked up in a follow-up PR.

Each item lists: **source** (where it came from), **severity**, **file:line**
(approximate at time of capture — verify before fixing), and a short summary.

When fixing an item, remove it from this file in the same commit.

---

## Security & correctness (cross-review)

### From PR-A diagnostic-bundle session (2026-05-16)

- **SHOULD-FIX — `test_generate_from_committed_cached_jamf_cli_data` date-rollover failure.**
  Discovered while running the full Python suite during PR-A. The test
  asserts that the Update Status sheet contains a `"No Data"` row, but
  on 2026-05-16 (~30 days after the committed jamf-cli fixtures were
  captured on 2026-04-13) the row no longer renders. Pre-existing
  failure — not introduced by PR-A. Root cause is likely a staleness
  threshold inside `CoreDashboard.writeUpdateStatus()` that uses
  `datetime.now()` rather than a frozen fixture clock. Fix: either
  freeze `datetime.now()` in the test via `monkeypatch`, regenerate
  the fixture set with newer timestamps, or change the assertion to
  match the current rendered shape. Affects only
  `tests/test_generate_cached_jamf_cli.py::test_generate_from_committed_cached_jamf_cli_data`;
  all 28 new PR-A tests + 291 other tests pass.

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
- **CONSIDER — Tripwire test gap: case-deletion not caught.**
  `testEveryShippingTemplateIsExplicitlyCovered` in
  `TemplateApplierTests.swift` catches "added a template, forgot to
  update TemplateApplier" but NOT "deleted a `case "x":` arm while
  `"x"` still ships in `TemplateResolver.allTemplates`." Closing this
  gap requires per-template behavioral assertions (extend
  `testApplyExecutiveTemplate` / `testRecommendedStaleDays` /
  `testEAKeywords` to be exhaustive across all 6 templates). PR-8
  hunter SHOULD-FIX, deferred because reviewer noted the asymmetry
  is consistent with the `default:` arm's documented load-bearing
  safety design.
- **CONSIDER — C-13 (`SummaryJSONParser` wrapper struct) is disputed.**
  REPORT.md flagged the 30-line struct as over-engineered. Investigation
  during PR-8 found it provides a useful namespace for `dateFormatter`
  (consumed at 8 callsites in `AccessibilityDescriptors`, `TrendsView`)
  plus two static methods (`parse`, `parseDirectory`) called from
  `FleetOverviewView` and `Sidebar`. Inlining would either pollute the
  global namespace or require verbose renames at every callsite. Leave
  alone unless a stronger reason surfaces.

### From PR-7 review (2026-05-15)

- **CONSIDER — `patch-managed` doc says "Jamf Pro v2 API" — the actual endpoint is v1.**
  `CLAUDE.md` / `AGENTS.md` per-command paragraph for `patch-managed`
  describes the operation as using the "Jamf Pro v2 API." The
  underlying jamf-cli command is `pro computers-inventory patch`
  (`jamf-reports-community.py:4161`), which maps to the
  `/v1/computers-inventory-detail/{id}` REST v1 endpoint. Low impact
  — the operation still works as described — but the version label
  is wrong. Reviewer CONSIDER #5.
- **CONSIDER — Dead argparse flag `--base-profile` is unused outside metadata.**
  `jamf-reports-community.py:18005` defines `--base-profile` with
  help text "UI base profile for generated multi LaunchAgents
  (metadata only)" but no dispatch site reads `args.base_profile`.
  Either wire it into `multi-launchagent-run`'s metadata as
  intended or drop the flag.

### From PR-6 review (2026-05-15)

Two follow-up items from the silent-failure-hunter / pr-review-toolkit
review gates that PR-6 deferred per the per-PR scope rules.

- **CONSIDER — Silent-return-on-empty-array branch of the eight Protect/Platform writers has no positive test.**
  PR-6 covers `loadLatestJSON` throwing on absent directories
  (`testProtectComputersThrowsWhenNoCachedData`). The other empty-path —
  fixture file exists, decodes to `[]`, writer hits `guard !items.isEmpty
  else { return }` and silently returns — is not exercised. Pattern is
  identical across `writeComplianceDevices`, `writeComplianceRules`,
  `writeDDMStatus`, `writeBlueprintStatus`, and the four Protect writers.
  One representative test (`testProtectComputersSilentReturnOnEmptyArray`)
  that writes `protect-computers/empty.json` containing `[]` and asserts
  `XCTAssertNoThrow` + no sheet added would cover the spirit. Hunter
  finding 2 sibling.
- **CONSIDER — Helper-created temp dirs across `CoreDashboardTests` are never cleaned up.**
  `tempDataDir(copying:)`, `tempDataDir(copyingRenamed:)`, and the new
  `tempDataDir(seeding:fromFixture:)` all create per-test directories
  under `FileManager.default.temporaryDirectory` and don't `defer`
  removal. Pre-existing pattern (~32 callsites); macOS cleans
  `temporaryDirectory` on logout, so this is hygiene rather than
  correctness. Either add `defer` to each helper's return value (would
  require an API change) or switch to `XCTestCase.setUp`/`tearDown`
  with a per-test dir stored in an ivar. Reviewer CONSIDER #2.
- **CONSIDER — Decoder tests assert via field values rather than negative key-mapping cases.**
  Each decoder test asserts on the decoded struct's field values. PR-6
  verified failing-test-first by perturbing
  `PolicyFinding.policyId = "policy_id"` and observing `keyNotFound`,
  then reverting. Future tests could lift the keyNotFound case into an
  explicit `XCTAssertThrowsError` negative assertion alongside the
  positive case. Pre-existing pattern across the decoder test file;
  low priority. Reviewer CONSIDER #3.

### From PR-6 test-coverage work (2026-05-15)

While adding inline-JSON decode smoke tests for `JamfCLIDecoder.swift`, two
fixtures were found to contain data of the wrong shape for their directory.
Both directories are loaded by their writers and would crash or silently
discard rows on a real run with this data — but currently the writers gate
on `loadLatestJSON` returning `[[String: Any]]`, so the bad fixtures
manifest only as decoder-side `keyNotFound` when consumed by typed code.

- **SHOULD-FIX — `tests/fixtures/jamf-cli-data/patch-device-failures/patch-device-failures.json` contains PatchStatusRow rows, not PatchFailureRow rows.**
  Real `pro report patch-status --scan-failures --output json` emits
  rows with `policy`, `policy_id`, `device`, `device_id`, `status_date`,
  `attempt`, `last_action`, `serial`, `os_version`, `username`. The
  committed fixture has `compliance_pct`, `id`, `latest`, `on_latest`,
  `on_other`, `title`, `total` — that's the patch-status shape, not the
  patch-failure shape. Capture from a tenant with active patch policies
  and replace.
- **SHOULD-FIX — `tests/fixtures/jamf-cli-data/update-device-failures/update-device-failures.json` is a 503 error envelope, not an UpdateFailuresReport.**
  Content is `{"httpStatus": 503, "errors": [...]}` rather than
  `[{"total": ..., "status_summary": [...], "error_devices": [...]}]`.
  Likely captured from a tenant that had Managed Software Update Plans
  toggled off. Recapture from a tenant with the feature enabled.

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

### From PR-2 review (2026-05-15)

Code-reviewer flagged three additional `jamf-cli` spawn sites that
bypass the M-01 codesign gate. None are in REPORT.md M-01's named
list (which scoped to `CLIBridge.swift`), so PR-2 ships narrow and
these are tracked here for a follow-up PR. Risk profile is lower
than the routine `collect`/`audit`/`backup` paths: each is a single
spawn at a well-defined moment (startup, install/upgrade, sidebar
load) protected by the install-time + onboarding-time gates.

- **SHOULD-FIX — `Provenance.captureJamfCLIVersion` spawns `jamf-cli --version` without codesign gate.**
  `app/Sources/JamfReports/Engine/Provenance.swift:78`.
  Reads the version string once per report-generation provenance
  block. Apply the same `JamfCLIIdentity.ensureVerifiedJamfCLI`
  gate pattern used by `CLIBridge.run`.
- **SHOULD-FIX — `JamfCLIInstaller.installedVersion(at:)` spawns `jamf-cli --version` without codesign gate.**
  `app/Sources/JamfReports/Services/JamfCLIInstaller.swift:263`.
  Called during install/upgrade flow to determine whether the
  current binary is current. Lower exposure (single spawn during
  an admin operation) but the gate is cheap to add.
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

- **SHOULD-FIX — `DeviceLookupIndex` has no direct test coverage.**
  `app/Sources/JamfReports/Services/DeviceLookupIndex.swift:62,123,185`.
  Add tests for newest-JSON selection, `.partial` filtering, envelope vs
  bare-array decoding, ordering, kind filtering.

- **SHOULD-FIX — `generateAll` lacks failure-branch test coverage.**
  `app/Sources/JamfReports/Services/CLIBridge+Generation.swift:39`. Cover
  collect failure branching, unauthorized short-circuit, partial success,
  permission/rate-limit fallback.

- **CONSIDER — Force unwraps in production-safe contexts.**
  `app/Sources/JamfReports/Services/DeviceInventoryService.swift:195`,
  `app/Sources/JamfReports/Services/LaunchAgentWriter.swift:528`. Replace
  with `guard let` / `if let` to match the repo convention.

### From Google Gemini 3 security-review (2026-05-12)

- **MEDIUM — Pin Python dependency hashes.** `requirements.txt` currently
  has version pins but no hashes. Add `--require-hashes` workflow (generated
  via `pip-compile --generate-hashes` or equivalent) to mitigate supply-chain
  tampering.

- **MEDIUM — SHA-256 digest JSON snapshots at collection, verify at
  generation.** Detect tampering of cached `jamf-cli-data/*.json` between
  collection and report generation. Threat-model T-2.

- **LOW — Add automated tests with malicious payloads for sanitization
  invariants.** XSS strings and formula-injection strings must round-trip
  through `_safe_write` and `HtmlSectionFormatters.escapeHTML` unchanged in
  meaning. Threat-model T-3 / T-4.

- **LOW — UI banner when last successful live collection is significantly
  older than the expected interval.** Currently the staleness threshold is
  in code but not surfaced in the UI. Threat-model T-8.

### From WCAG 2.2 AA accessibility audit (2026-05-15)

Two-surface audit covering the SwiftUI app and the HTML report
(`HtmlReport` in `jamf-reports-community.py`). Findings categorized by
severity; SwiftUI items reference Apple HIG accessibility APIs, HTML items
cite WCAG 2.2 Success Criteria.

**SwiftUI — MUST-FIX**

- **Chart descriptors defined but not applied.**
  `app/Sources/JamfReports/Theme/AccessibilityDescriptors.swift` defines
  five `AXChartDescriptor` types (Trend / MultiLine / Sector / Bar /
  Stacked) but only ~6 of 16 `Chart {}` blocks attach one via
  `.accessibilityChartDescriptor(...)`. Unattached sites:
  `Views/UpdatesView.swift:326,615`,
  `Views/CompliancePostureView.swift:254,449`,
  `Views/SecurityPostureView.swift:397,478`,
  `Views/ExtensionAttributesView.swift:346,548`,
  `Views/TrendsView.swift:1037`. VoiceOver Audio Graph is silent on
  those charts. PNG-export-only renderers can use
  `.accessibilityHidden(true)` instead.

- **Icon-only buttons rely on `.help(...)` only.** `.help` is a hover
  tooltip; VoiceOver does not read it. Add `.accessibilityLabel(...)`
  (state-aware where relevant): `Views/Titlebar.swift:16-23` (sidebar
  toggle), `Views/AppToolbar.swift:187-195` (demo-mode toggle),
  `Views/CustomizeView.swift:42-49` (dismiss banner),
  `Views/SourcesView.swift:230-244` (per-row ellipsis menu).

- **Severity icon distinguishable by color only.**
  `Views/AuditView.swift:457-464` returns the same
  `exclamationmark.triangle.fill` glyph in three colors for
  Critical/Warning/OK. Adjacent `Pill` text mitigates, but the icon
  viewed alone fails SC 1.4.1. Vary the SF Symbol per severity
  (`octagon.fill` / `triangle.fill` / `checkmark.circle.fill`) or set
  `.accessibilityLabel(severity)` on the `Image`.

**HTML report — MUST-FIX**

- **No headings or landmarks.** `jamf-reports-community.py:15102-15278`.
  Zero `<h1>`–`<h6>` elements; zero `<header>`/`<main>`/`<nav>`/
  `<footer>`. SR users can't navigate by structure (SC 1.3.1). Wrap
  topbar, page, and footer in landmarks; promote `.topbar-brand` →
  `<h1>`, `.section-block-title` → `<h2>`, `.section-title` → `<h3>`.

- **Tables missing `scope` and `<caption>`.**
  `jamf-reports-community.py:13595,13645,14400,14475,14517,14563-14564`.
  All `<th>` lack `scope="col"`; no `<caption>` on any data table.
  Cells aren't programmatically associated with column headers
  (SC 1.3.1).

- **Security status cells color-coded with no text differentiator.**
  `jamf-reports-community.py:14454-14457,14544-14548`. FileVault / SIP
  / Firewall cells convey pass/fail via `val-ok` (green) vs `val-err`
  (red) CSS classes — cell text is identical. Fails SC 1.4.1.
  Prepend ✓ / ✗ glyph or `[OK]`/`[FAIL]` text.

- **Trend SVG has no text alternative.**
  `jamf-reports-community.py:13473` (`_render_line_chart_svg`). Only a
  generic `aria-label="Trend chart"`; data exists solely as SVG
  geometry. OS distribution chart at `:13594-13597` already does this
  correctly (paired visually-hidden `<table>`) — mirror the pattern
  (SC 1.1.1).

- **Click-bound `<div>`s and untyped tablists.**
  `jamf-reports-community.py:14286-14289` `.cat-toggle` is a `<div>`
  with onclick — no `role`, `tabindex`, `aria-expanded`, no keyboard
  handler (SC 2.1.1). `.tree-tab` at `:14345` is a real `<button>` but
  missing `role="tab"`/`aria-selected`/`aria-controls`; `.tree-tabs`
  missing `role="tablist"`. Update JS handlers at `:14075-14083` and
  `:14085-14095`.

- **Contrast and focus-visible gaps.**
  `jamf-reports-community.py:13884-13888`. `--muted #64748b` on
  `--surface-2 #f8fafc` at 0.68rem ≈ 4.4:1 — fails 4.5:1 (SC 1.4.3).
  No `:focus-visible` rule anywhere — dark-mode toggle's default focus
  ring is invisible on `#004165` topbar. Darken `--muted` to slate-600
  / `#475569`; add `:focus-visible { outline: 2px solid var(--blue);
  outline-offset: 2px; }` plus a high-contrast topbar variant. Needs
  Stark/axe pass to confirm all dark-mode badge pairs.

**SwiftUI — SHOULD-FIX**

- **Reduce-motion not honored on Titlebar pulsing dot.**
  `Views/Titlebar.swift:67-72`. Pulsing breath animation on the "CLI
  missing" indicator doesn't gate on `accessibilityReduceMotion`.
  `Views/SecurityPostureView.swift:423-436` is the right pattern to
  copy.

- **Destructive write buttons missing hints.**
  `Views/SmartGroupApplySheet.swift:391-397` ("Create in Jamf Pro"),
  `Views/BackupsView.swift:195-200` (Delete backup),
  `Views/SourcesView.swift:390-399` (Full Admin scope elevation). Add
  `.accessibilityHint("...")` describing the side effect.

- **TextField placeholders aren't labels for VoiceOver.**
  `Views/SmartGroupApplySheet.swift:297-298,308`,
  `Views/BackupsView.swift:122-126`, `Views/AuditView.swift:141`.
  Add explicit `.accessibilityLabel(...)`. Also set `.defaultFocus`
  on the SmartGroupApplySheet name field.

- **SecureSecretField missing hint.**
  `Views/SecureSecretField.swift:35-36`. Has AppKit
  `setAccessibilityLabel("Client Secret")` but no
  `setAccessibilityHelp(...)`. Add hint noting credential is stored in
  the keychain and not displayed.

- **Composite candidate row not flattened.**
  `Views/DeviceLookupView.swift:168-203`. The Button wraps Pill + Text
  + Mono + chevron without `.accessibilityElement(children: .combine)`
  — VO reads each child separately.

- **Dynamic status text has no live-region trait.**
  `Views/RunsView.swift`, `Views/SchedulesView.swift`,
  `Theme/Components.swift:633` (`StatusBar`). "Running…" /
  "Collecting…" updates won't be announced. Add
  `.accessibilityAddTraits(.updatesFrequently)`.

- **Hit target below WCAG 2.5.8 floor.**
  `Theme/Components.swift:286` (`PNPButton.size = .sm` at 22pt high),
  `:328` (`PNPToggle` 36×22pt). Raise minimum to 24pt or expand
  `.contentShape(...)` hit area.

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

- **CONSIDER — Stale ADR reference.**
  `app/Sources/JamfReports/App/JamfReportsApp.swift:16` and
  `app/Sources/JamfReports/App/CheckForUpdatesView.swift` both cite
  `ADR-W23-sparkle-integration.md`, which does not exist in the worktree.
  Either commit the ADR or remove the reference.

- **CONSIDER — `${BASH_SOURCE[0]}` in a `#!/bin/zsh` script.**
  `app/scripts/sparkle-appcast.sh:27`. zsh's bash-compat handles it today but
  it's not idiomatic. Switch to `${(%):-%x}` or document the dependency.

- **CONSIDER — WHAT-comments in build scripts.** A handful of restate-the-code
  comments (e.g. `# Notarize when: ...` immediately above the conditional that
  expresses the same thing). Drop on next pass through the scripts.

- **CONSIDER — Symmetric `codesign --verify --strict` step in `build-dmg.sh`.**
  `app/build-pkg.sh` verifies the signature post-signing via
  `pkgutil --check-signature`. `build-dmg.sh` does not have an equivalent
  `codesign --verify` step after `codesign --sign`. Add for consistency and
  to close the same silent-failure shape.

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
