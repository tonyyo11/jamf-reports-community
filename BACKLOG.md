# Backlog — Deferred Findings

Findings deferred from in-progress work that are out of the current session's
scope. Items here are valid but not blocking the current change; they should
be picked up in a follow-up PR.

Each item lists: **source** (where it came from), **severity**, **file:line**
(approximate at time of capture — verify before fixing), and a short summary.

When fixing an item, remove it from this file in the same commit.

---

## Security & correctness (cross-review)

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
