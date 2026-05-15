# Phase 3 — Regression / Invariant Audit

## 3a. Tests deleted or skipped

- **Tests deleted on branch: 0** (`git diff --diff-filter=D` empty for `tests/*.py`
  and `app/Tests/**/*.swift`).
- **Tests added: +8 Python, +134 Swift**. Net massive addition.
- **Skipped on this CI run: 12 (Swift), 0 (Python)**. All 12 are
  conditional skips with explicit messages:
  - `jamf-cli` presence/absence skip pairs (2 each in `CLIBridgeBackupTests`,
    `FailureModeTests`, `CLIBridgeAuthGuardTests`)
  - Environment-gated perf tests (`PerformanceRegressionTests`, gated by
    `JRC_PERF=1`)
  - Fixture-availability skips (`OutputValidatorTests` for `golden_workbook.xlsx`,
    `CoreDashboardSecurityTests` for an out-of-spec update-status fixture)
  - One debug-vs-release skip (`CLICommandTests.testArgvReturnsEmptyForInvalidProfile` —
    `assertionFailure` fires only in debug)

**Finding R-01 (SHOULD-FIX)** — Out-of-spec fixture skip should be tracked.
`Engine/CoreDashboardSecurityTests.swift:211` (`testWriteUpdateStatusFromFixture`)
skips with reason "update-status fixture is not a valid `UpdateStatusReport`
shape". No `BACKLOG.md` entry tracks this. Either re-shape the fixture or
add a backlog entry.

**Finding R-02 (CONSIDER)** — `OutputValidatorTests` skips when the
`golden_workbook.xlsx` fixture isn't in the test bundle. If it's never
checked in, the tests never run anywhere — they're effectively dead.
Either ship the fixture or remove the tests.

Otherwise: no unconditional skips. **No skip regressions.**

---

## 3b. CHANGELOG truth-checking

Spot-checked nine claims in `## [Unreleased]` against HEAD:

| claim | file/symbol | verified? |
|---|---|---|
| "Nine new dashboards: Security Posture, Compliance Posture, Patch, Updates, Policy/Profile, Extension Attributes, Outreach, Protect, Mobile Fleet" | 9 view files in `app/Sources/JamfReports/Views/` | ✓ all present |
| "EmptyStateView shared component at `Theme/EmptyStateView.swift`" | `app/Sources/JamfReports/Theme/EmptyStateView.swift` | ✓ |
| "DataTableHeader / DataTableRow / DataTableColumn in `Theme/Components.swift`" | grep finds all 3 symbols | ✓ |
| "build-pkg.sh distribution installer" | `app/build-pkg.sh` (186 lines) | ✓ |
| "build-dmg.sh consolidated DMG builder" | `app/build-dmg.sh` (200 lines) | ✓ |
| "docs/GLOSSARY.md vocabulary reference" | exists at top | ✓ |
| "Configurable Security Score via Config → Scoring tab; persisted in `config.yaml`" | `SecurityScoreCalculator.swift`, `@AppStorage("securityScoreWeights")`, `ScoringConfig` | ✓ matches CLAUDE.md description |
| "AXChartDescriptor attached" | `Theme/AccessibilityDescriptors.swift` exists but BACKLOG R-W documents 10 chart sites missing `.accessibilityChartDescriptor(...)` | ⚠ partial — BACKLOG flags this honestly |
| "Acknowledgements menu item" | `App/AcknowledgementsView.swift` | ✓ |

CHANGELOG references to removed waste (`JamfProtectSnapshotService` etc.) checked:
`grep -niE "(JamfProtectSnapshot|JamfSchoolSnapshot|PlatformBenchmark|UnifiedHistory)" CHANGELOG.md` → **0 hits**. The removed dead-code waste isn't documented in CHANGELOG as ever shipping — correct, since it never landed on `main`.

**No phantom features found in CHANGELOG.**

---

## 3c. BACKLOG hygiene

`BACKLOG.md` is 350 lines. Spot-checked 4 items still unresolved in HEAD:

| backlog item | path | still present? |
|---|---|---|
| "Partial runs render as `.ok`" — `RunHistoryService.swift:49–52` | parseLogTail at line ~49 | ✓ still unresolved |
| "Config saves swallowed in user paths" — `CustomizationWizard.swift:356` | line ~356 | ✓ try? still used |
| "Force unwraps: `DeviceInventoryService.swift:195`, `LaunchAgentWriter.swift:500`" | grepped !\\. | only 1 force-unwrap remains in `app/Sources/` (per invariant audit below) — at least one was fixed without backlog update |
| Multiple WCAG 2.2 AA findings | various | ✓ unresolved, accurate file:line refs |

**Finding R-03 (CONSIDER)** — BACKLOG line numbers for force-unwrap sites
have drifted with file edits. `DeviceInventoryService.swift:195` still has
`raw!` (after safe `?.isEmpty == false` guard — invariant-safe but flagged
in the convention). `LaunchAgentWriter.swift:500` no longer has a
force-unwrap — that line is now a switch-case message; the force-unwrap
moved to `LaunchAgentWriter.swift:528` (`tokens.last!` inside
`parseHHMM`). Update the BACKLOG line numbers to `:195` and `:528`.

Beyond those two backlog entries, the broader Swift force-unwrap surface
in production paths is ~10 sites including `CoreDashboard.swift:2155`,
`ChartRenderer.swift:519`, `OOXMLWriter.swift:775`,
`CLISuggester.swift:140,141`, `JamfCLIInstaller.swift:655,658`,
`WorkspaceStore.swift:174`, plus the `DemoData.swift:21,25` date
constructions. Most are guarded; the `.first!` patterns in CLISuggester
and JamfCLIInstaller are the riskier ones if their inputs ever go empty.

---

## 3d. Swift build + tests (background-run)

- `swift build` — **exit 0**.
- 2 distinct warnings (deduped from 48 raw output lines due to multi-target builds):
  - `PDFExporter.swift:190` — `webView(_:decidePolicyFor:decisionHandler:)`
    nearly matches optional requirement of `WKNavigationDelegate`. Likely an
    async/callback variant mismatch. **R-04 (SHOULD-FIX)** — violates the
    CLAUDE.md "zero-warnings policy".
  - `RiskScoringService.swift:183` — `scanDouble` was deprecated in macOS
    10.15; project targets macOS 14+. **R-05 (SHOULD-FIX)** — same policy
    violation; trivial fix (use `scanDouble(into:)` or `Double.init`).
- `swift test` — **exit 0**. 1,268 tests, 12 skipped (see 3a), 0 failures.

---

## 3e. Python compile + tests

- `python3 -c "import py_compile; py_compile.compile('jamf-reports-community.py', doraise=True)"` — **OK**.
- `pytest -q` — **265 passed, 3 warnings, 0 failures** in 9.23s.
- Warnings are matplotlib legend warnings ("No artists with labels found")
  during chart generation in test fixtures — non-critical.

---

## 3f. CLI smoke

All 19 subcommands enumerate via `--help` without error. The set in HEAD is:

```
generate, html, collect, inventory-csv, export-reports, backup,
workspace-init, launchagent-setup, launchagent-run,
multi-launchagent-run, capabilities, scaffold, check, device,
patch-managed, school-generate, school-collect, school-scaffold,
school-check
```

**Finding R-06 (CONSIDER) — CLAUDE.md CLI doc-drift.** CLAUDE.md "CLI
commands" section lists only 10 commands (`generate`, `html`, `collect`,
`inventory-csv`, `scaffold`, `check`, `school-generate`, `school-collect`,
`school-scaffold`, `school-check`). The 9 missing — `export-reports`,
`backup`, `workspace-init`, `launchagent-setup`, `launchagent-run`,
`multi-launchagent-run`, `capabilities`, `device`, `patch-managed` — are
real operator surface used by the Swift app. CLAUDE.md should be updated.

Unknown commands print usage and exit non-zero (expected). No subcommand
crashes on `--help`. **No CLI regression.**

---

## 3g. App build sanity

`./build-app.sh release` was **not run** because it hard-fails without the
`SU_PUBLIC_ED_KEY` env var and would attempt to invoke `xcrun notarytool
submit --wait` against Apple's notary service (side-effect / external
network). Equivalent local verification:

- `swift build` (debug) — exit 0, 2 warnings ✓
- `swift build -c release` not run separately; the SwiftPM target compiles
  warning-free apart from the two flagged above. Release config requires
  `SU_PUBLIC_ED_KEY` (Sparkle pubkey) — out of scope for review.

**Finding R-07 (CONSIDER)** — `build-app.sh` couples release-build to Sparkle
pubkey + notarization. A `--no-notarize` / dry-run mode would let reviewers
verify the bundle layout without the env-var dance. (Already partially
addressed by `SKIP_NOTARIZE=1`; would need to also relax the
`SU_PUBLIC_ED_KEY` `:?` guard for true dry-run.)

---

## 3h. View existence audit

CLAUDE.md "Key views" enumerates 17 core, 7 utility, and 9 v3.5-port dashboard
view names. Cross-checked all 33 against `app/Sources/JamfReports/Views/`:

- All **17 core views** present (`Sidebar`, `Titlebar`, `OverviewView`,
  `FleetOverviewView`, `DevicesView`, `DeviceLookupView`, `TrendsView`,
  `ReportsView`, `BackupsView`, `SchedulesView`, `RunsView`, `ConfigView`,
  `CustomizeView`, `SourcesView`, `AuditView`, `OnboardingView`,
  `SettingsView`)
- All **9 dashboard views** present (`SecurityPostureView`,
  `CompliancePostureView`, `OutreachView`, `PatchView`, `UpdatesView`,
  `PolicyProfileView`, `ExtensionAttributesView`, `MobileFleetView`,
  `ProtectView`)
- All **7 utilities** present (`AppToolbar`, `WhatsNewBanner`,
  `DashboardChartExport`, `GenerateSheet`, `SecureSecretField`,
  `WorkspaceView`, `HealthCheckView`)

Two extras present not enumerated in CLAUDE.md: `CustomizationWizard.swift`,
`SmartGroupApplySheet.swift`. Both compile and ship.

`grep -rE "fatalError\(|preconditionFailure\(|// TODO: not implemented" app/Sources/JamfReports/Views/` returned 0 hits — no view has a known "not implemented" path.

**No view regressed off main**, and **no view body lost compile-cleanliness**
(otherwise `swift build` would fail).

---

## 3i. Invariant audit

### Python CLI

| invariant | check | result |
|---|---|---|
| `_safe_write` for all CSV-sourced cell writes | `grep -c "_safe_write("` = 496. Direct `ws.write(` = 5, all confirmed labels/empty-state markers. | ✓ |
| No hardcoded column names | `grep "Computer Name"` returns 6 hits — all OUTPUT-side (writing a column called "Computer Name" in generated CSVs / wide-inventory exports), not INPUT-side. Spirit of the invariant is preserved (input is config-driven via `ColumnMapper`). | ⚠ literal-violation, spirit-preserved — flagged as R-08 CONSIDER |
| No CBP / org-specific values | `grep -in "cbp\|dhs.gov\|borderprotection"` returns 0 in Python | ✓ |
| `jamf-cli` calls gated on `is_available()` | 12 gates present | ✓ |
| `matplotlib` gated on `HAS_MATPLOTLIB` | 7 guards present | ✓ |
| Single-file | `find . -maxdepth 2 -name "*.py" -not -path "./tests/*"` returns only `jamf-reports-community.py` | ✓ |

### Swift app

| invariant | check | result |
|---|---|---|
| No `!` force-unwraps in production paths | A broader regex `[A-Za-z0-9\)\]]!([^=!]|$)` finds ~10 production force-unwrap sites including `CLISuggester.swift:140,141` `.first!`, `JamfCLIInstaller.swift:655,658` `.last!`/`.first!`, `WorkspaceStore.swift:174` `real.first!.name`, plus guarded ones. BACKLOG flags 2; line numbers stale (LaunchAgentWriter:500 → :528). | ⚠ R-03 |
| All paths via `ProfileService.workspaceURL` / `WorkspacePaths` | spot-checked `LegacyHistoryImporter.defaultHistoryURL` (commit `0455344` routes through Paths). The `..` patterns I found are UI loading dots (`Generating...`), not path strings. | ✓ |
| No new SwiftPM deps without justification | Two new: **Sparkle 2.6.0** (W23 auto-update, documented in `build-app.sh` and CLAUDE.md as "ADR-W23-sparkle-integration.md"), **ZIPFoundation 0.9.19** (used in `Engine/OOXMLWriter.swift` and `Engine/Validators/XLSXValidator.swift` — needed for xlsx output, which is a zip container). Both justified. | ✓ |
| No `sudo` / LaunchDaemons | grep returns 0 hits | ✓ |
| No CBP / org-specific values | only hit: `Engine/Provenance.swift:15` docstring example `"cbp-prod"` — illustrative only, not active org reference. | ✓ acceptable; flagged R-09 CONSIDER |

---

## Summary of Phase 3 findings

| id | severity | area | description |
|---|---|---|---|
| R-01 | SHOULD-FIX | tests | Out-of-spec update-status fixture skip lacks BACKLOG entry |
| R-02 | CONSIDER | tests | `golden_workbook.xlsx` fixture never shipped → both `OutputValidatorTests` tests perpetually skipped |
| R-03 | CONSIDER | docs/code | BACKLOG lists 2 force-unwrap sites; only 1 remains. Verify + prune the stale entry |
| R-04 | SHOULD-FIX | swift warn | `PDFExporter.swift:190` near-match warning on `WKNavigationDelegate` |
| R-05 | SHOULD-FIX | swift warn | `RiskScoringService.swift:183` uses deprecated `scanDouble` |
| R-06 | CONSIDER | docs | CLAUDE.md CLI section omits 9 of 19 subcommands |
| R-07 | CONSIDER | dx | `build-app.sh release` requires `SU_PUBLIC_ED_KEY`; dry-run mode would help review |
| R-08 | CONSIDER | invariant | Python: 6 output-side `"Computer Name"` literals; CLAUDE.md invariant wording too strict OR code should be config-keyed for output too |
| R-09 | CONSIDER | docs | `Provenance.swift:15` docstring uses `"cbp-prod"` as illustrative profile slug |

**No MUST-FIX regressions found by the structural / invariant audit.** Builds
green, tests green, all named views and CLI commands present. The two compiler
warnings (R-04, R-05) violate the "zero-warnings policy" and are the closest
thing to a hard regression — both are trivial line fixes.
