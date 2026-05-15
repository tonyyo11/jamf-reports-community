# Backlog — Deferred Findings

Findings deferred from in-progress work that are out of the current session's
scope. Items here are valid but not blocking the current change; they should
be picked up in a follow-up PR.

Each item lists: **source** (where it came from), **severity**, **file:line**
(approximate at time of capture — verify before fixing), and a short summary.

When fixing an item, remove it from this file in the same commit.

---

## Security & correctness (cross-review)

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
  `app/Sources/JamfReports/Services/LaunchAgentWriter.swift:500`. Replace
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
