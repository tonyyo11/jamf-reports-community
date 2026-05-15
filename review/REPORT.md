# Branch Review — `dev-app/2.0` Lineage (origin/main..HEAD)

**Branch:** `emdash/spotty-eels-shock-ngj6f` (HEAD == `origin/dev-app/2.0` @ `cd3598e`)
**Scope:** 157 commits, 384 files changed, +89,797 / −767 lines (merge base `b04519d`)
**Date:** 2026-05-15
**Calibration source:** the user left `TODO` placeholders under each criterion
block in `.claude/prompts/branch-review.md`; the example values printed above
each `TODO` are treated as the operative calibration. Worth re-checking before
acting on these findings.
**Build / test state at review time:** `swift build` exits 0 with 2 warnings;
`swift test` 1,268 / 0 failures (12 conditional skips); `pytest -q` 265 / 0
failures.

---

## 1. Executive summary

1. **The branch is in good shape.** No MUST-FIX regressions in build, tests,
   or named feature surfaces. All 36 views named in `CLAUDE.md` exist; all 19
   CLI subcommands enumerate cleanly via `--help`. Net `−767` lines of
   deletion compared to massive growth indicates intentional, additive work.
2. **One material churn pattern: 2,171 lines of AI-scaffolded dashboards
   were deleted as "dead code" 3 days after landing** (`e52e88e` Apr 26 →
   `d4376a7` Apr 29). The current dashboard set was rewritten with smaller,
   differently-shaped services 17 days later via `c21f32e` (May 13
   carry-forward). Documented in `review/02-churn.md` F1.
3. **The strongest correctness defects on HEAD:** a hardcoded `502` fleet
   denominator in six locations in `OverviewView.swift` produces wrong
   percentages on any tenant whose fleet is not ~500 devices; and
   `CLIBridge.saveJSONSnapshot` at line 926 writes JSON non-atomically
   while every other JSON write in the file uses `.atomic` — a crash
   mid-write poisons the cached-fallback path with a truncated file.
4. **The strongest security defect on HEAD:** routine subprocess paths in
   `CLIBridge.swift` invoke `jamf-cli` **without** re-verifying its code
   signature. Verification happens only at install
   (`JamfCLIInstaller.swift:543`) and onboarding
   (`OnboardingFlow.swift:418`). On Homebrew installs `/opt/homebrew/bin/`
   is user-writable; a binary swapped after onboarding receives live API
   credentials.
5. **Documentation drift:** `CLAUDE.md` documents 10 of 19 actual Python
   CLI subcommands. `BACKLOG.md` line numbers have drifted (e.g.
   `LaunchAgentWriter:500` → now `:528`). Operator-facing CLI surface
   should be reconciled before the next release.

---

## 2. MUST-FIX (block merge / hold release)

| id | finding | file:line | introduced | remediation |
|---|---|---|---|---|
| **M-01** | `CLIBridge` invokes `jamf-cli` without codesign verification on routine paths (`collect`, `audit`, `backup`, `deviceDetail`, `validateConnection`, `groupHygiene`). Verification gated to install (`JamfCLIInstaller.swift:543`) + onboarding (`OnboardingFlow.swift:418`) only. Homebrew `/opt/homebrew/bin/` is user-writable; post-onboarding binary replacement receives live API credentials. | `app/Sources/JamfReports/Services/CLIBridge.swift:123` (`run`) and :181 (`runAndCapture`) — all routine command implementations call through these. | `b60ea69` (W0 scaffold) — never gated since. `7fb6543` (May 9) added codesign for credential passing in the **onboarding** path only. | Call `CodeSignVerifier.verify(url:expectedTeamID:)` before each `process.run()`; cache the verified fingerprint in `JamfCLIIdentity` so per-command re-verification is cheap. |
| **M-02** | `AgentCardView` displays security-agent coverage against a hardcoded fleet size of **502** in six places. A 100-device tenant sees "47 / 502 = 9.4%" when actual coverage is 47%. | `app/Sources/JamfReports/Views/OverviewView.swift:365, 716, 973, 983, 1025, 1028` | `c21f32e` (May 13 carry-forward) or earlier — demo-data leftover that crossed into production paths. | Thread the live device count from `DeviceInventoryService` snapshot (same source already feeds adjacent tiles). |

Both block the next release. M-01 is an authenticated-supply-chain risk; M-02 is a user-visible correctness regression versus the v3.5 script.

---

## 3. SHOULD-FIX (address before next release)

| id | finding | file:line | remediation |
|---|---|---|---|
| **S-01** | Non-atomic JSON write in `CLIBridge.saveJSONSnapshot`. Crash/OOM/full-disk mid-write produces a truncated `<type>_<ts>.json` that `CachedDataFallback` cannot distinguish from a valid snapshot — the next live-failure fallback loads partial data while the run renders green. Every other write in the file uses `.atomic` (lines 679, 1065, 1392). | `app/Sources/JamfReports/Services/CLIBridge.swift:926` | Add `options: [.atomic]` to the write call; add a decode-validity check on read in `CachedDataFallback.swift:128-153`. |
| **S-02** | `CLIBridge.run()` defaults `environment` to `nil`, causing `Process` to inherit the parent environment (`DYLD_INSERT_LIBRARIES`, `SSL_CERT_FILE`, etc.). All current callers pass `environmentForJamfCLI()` explicitly, so not exploitable today. | `app/Sources/JamfReports/Services/CLIBridge.swift:127, 181` | Change parameter default to `environmentForJamfCLI()`. |
| **S-03** | `ProfileService.isValid` regex `^[a-z0-9][a-z0-9._-]*$` permits dots. `LaunchAgentWriter` builds labels `com.jamfreports.<profile>.<slug>` and `LaunchAgentService.profileAndSlug(from:)` parses them by splitting on `.`. A `dummy.prod` profile with `daily` slug yields ambiguous `com.jamfreports.dummy.prod.daily`. Path-side `hasPrefix` checks protect dirs; label parsing does not. | `app/Sources/JamfReports/Services/ProfileService.swift` regex; `LaunchAgentWriter.swift:362`; `LaunchAgentService.swift:150` | Tighten regex to disallow `.` OR use `/` (or a non-overloaded separator) between profile and slug in label construction. |
| **S-04** | `OverviewView` `layoutPriority(1)` (added `fadc144` May 4 16:29) was reverted to `LazyVGrid` 75 minutes later (`c88fe03`). Same-day fix-your-own-PR pattern. Not a regression now (already fixed), but the W12 design-polish wave landed visual changes without verifying on narrow windows — flag the process gap. | `OverviewView.swift:207-230` (history) | Process change: visually verify polish-wave commits on a narrow window before merging. |
| **S-05** | Two Swift compiler warnings violate the CLAUDE.md "zero-warnings policy". `PDFExporter.swift:190` near-match on `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)`; `RiskScoringService.swift:183` uses deprecated `scanDouble`. | as listed | `PDFExporter`: rename to async variant or mark with explicit conformance; `RiskScoringService`: use `Scanner.scanDouble()` (no-arg) or `Double(scanner.scanCharacters(...))`. |
| **S-06** | `Templates/` ecosystem (`ReportTemplate` + `TemplateApplier` + `TemplateResolver` + 6 concrete files) is static-table-as-polymorphism — applier switches on raw `template.identifier` instead of dispatching through the protocol. | `app/Sources/JamfReports/Engine/Templates/*.swift` | Move per-template data (keywords, thresholds, stale days) into protocol-required computed properties; delete `TemplateApplier`. |
| **S-07** | Out-of-spec fixture skip in `CoreDashboardSecurityTests.testWriteUpdateStatusFromFixture` (`:211`) — "update-status fixture is not a valid UpdateStatusReport shape". No BACKLOG entry tracks it. | `app/Tests/JamfReportsTests/Engine/CoreDashboardSecurityTests.swift:211` | Either re-shape the fixture or add a `BACKLOG.md` entry. |
| **S-08** | CLAUDE.md `## CLI commands` section enumerates 10 commands; HEAD has **19** (extras: `export-reports`, `backup`, `workspace-init`, `launchagent-setup`, `launchagent-run`, `multi-launchagent-run`, `capabilities`, `device`, `patch-managed`). | `CLAUDE.md` | Update CLI commands section to list all current subcommands. |
| **S-09** | `SmartGroupApplyService.swift:189` defaults the `created` flag to **true** when absent — UI then renders "Smart group created" for what may be an update. PR #205 contract is unstable (`f80753b` shows drift was already discovered live). | `app/Sources/JamfReports/Services/SmartGroupApplyService.swift:189` consumed at `SmartGroupApplySheet.swift:333` | Flip default to `false`. A false "updated" is silent; a false "created" is actively misleading. Add `testDecodeResultAbsentCreatedDefaultsFalse`. |
| **S-10** | `JamfCLIDecoderTests.swift` has decode-test coverage for ~9 of 27+ `Decodable` structs. The 18+ uncovered (incl. `ComplianceDeviceRow`, `ProtectAlertRow`, `MobileDeviceListRow`, `BlueprintStatusRow`, …) silently produce empty/nil on field renames in future jamf-cli versions. | `app/Tests/JamfReportsTests/Engine/JamfCLIDecoderTests.swift` | Add one inline-JSON smoke test per struct using committed fixtures at `tests/fixtures/jamf-cli-data/`. |
| **S-11** | `CoreDashboardTests.swift` has no coverage for 8 sheet writers that use raw `[String: Any]` access: `writeComplianceDevices`, `writeComplianceRules`, `writeDDMStatus`, `writeBlueprintStatus`, `writeProtectOverview/Alerts/Computers/Insights`. A typo'd key renders blank columns silently. | as listed | Add fixture-backed writer tests following the existing `writeSmartGroups` pattern. |

---

## 4. CONSIDER (lower-priority cleanup)

| id | finding | file:line |
|---|---|---|
| **C-01** | `OutputValidatorTests` skips both golden-xlsx tests perpetually because `golden_workbook.xlsx` is not shipped in the test bundle. | `app/Tests/JamfReportsTests/OutputValidatorTests.swift:19` |
| **C-02** | BACKLOG line numbers drifted. `LaunchAgentWriter:500` no longer hosts a force-unwrap; the `tokens.last!` moved to `:528`. `DeviceInventoryService:195` `raw!` is still there (guarded but flagged). | `BACKLOG.md` |
| **C-03** | Two literal-duplicate "sync to jamf-cli v1.17.0" commits with identical session URLs both landed in HEAD. `8f44536` and `13f7fa3` apply the same 13-line patch from two different parents. Harmless but commit-history noise. | `8f44536` / `13f7fa3` |
| **C-04** | `Provenance.swift:15` docstring uses `"cbp-prod"` as illustrative profile slug. Internal-vocabulary leak (trivial). | `app/Sources/JamfReports/Engine/Provenance.swift:15` |
| **C-05** | Python output-side hardcodes `"Computer Name"` in 6 places (lines 2808, 2850, 7361, 8835, 10329 + 1 more). CLAUDE.md invariant says the string MUST NOT appear in script body. Spirit of the invariant preserved (input is config-keyed via `ColumnMapper`), but the wording is too strict OR output column names should be configurable. | `jamf-reports-community.py` various |
| **C-06** | `build-app.sh release` requires `SU_PUBLIC_ED_KEY` env var and may submit to Apple's notary service; no dry-run mode bypasses both. Hampers reviewer workflows. | `app/build-app.sh:17,290-315` |
| **C-07** | `LaunchAgentWriter` plist write umask race — atomic write at default 0644 before chmod to 0600. Sub-ms exposure of profile name + command path. | `app/Sources/JamfReports/Services/LaunchAgentWriter.swift:89, 419` |
| **C-08** | `SystemActions.canonicalize()` uses byte-for-byte `hasPrefix` — case-insensitive HFS+ collisions can bypass allow-list. | `app/Sources/JamfReports/Services/SystemActions.swift:57` |
| **C-09** | `SectionRegistry.swift` (70 lines) is a single-call dispatcher. Inline into `HtmlReport`. | `app/Sources/JamfReports/Engine/SectionRegistry.swift` |
| **C-10** | `CLISuggester.relevanceScore` is a dead private method. | `app/Sources/JamfReports/Services/CLISuggester.swift:67-94` |
| **C-11** | `JamfCLIIdentity.swift` is a 28-line two-constant file used only as default args in `OnboardingFlow.swift:416-417`. Inline. | `app/Sources/JamfReports/Services/JamfCLIIdentity.swift` |
| **C-12** | `WorkspaceMigration` result structs over-engineered for a one-shot. | `app/Sources/JamfReports/Services/WorkspaceMigration.swift:62-78` |
| **C-13** | `SummaryJSONParser` is a 30-line wrapper struct around two stateless functions. | `app/Sources/JamfReports/Services/SummaryJSONParser.swift:150-196` |
| **C-14** | `.claude/settings.local.json` emdash-notifications hook posts `$EMDASH_HOOK_TOKEN` over HTTP with `|| true` error suppression (AgentShield critical). Operator-side; consider scoped token + endpoint pinning. | `.claude/settings.local.json:8,18` |
| **C-15** | `JamfCLIDecoder.swift:604-610` declares no-op CodingKeys for `ComplianceDeviceRow` / `ComplianceRuleRow` (identity-mapped). Swift synthesizes these automatically. Remove the redundant block. | `app/Sources/JamfReports/Engine/JamfCLIDecoder.swift:604-610, 616-628` |
| **C-16** | `ReportEngine.swift:68` `let allFailures = coreFailures` is dead indirection — immediately returned, never mutated. Collapse to `return coreFailures`. | `app/Sources/JamfReports/Engine/ReportEngine.swift:68` |
| **C-17** | `JamfCLIDecoder.swift:368` maps EA type `"INTEGER"` → `"percentage"`. Reasonable heuristic but lossy (INTEGER is also used for counts, raw scores). Add a one-line comment documenting the assumption. | `app/Sources/JamfReports/Engine/JamfCLIDecoder.swift:368` |

---

## 5. Wasted-change inventory (Phase 2)

| id | within-branch waste | scope | commits |
|---|---|---|---|
| **F1** | 8 dashboards/services totalling ~2,171 lines added → "dead code"-deleted 3 days later | branch-only — never reached `main` | `e52e88e` Apr 26 (added) → `d4376a7` Apr 29 (deleted). Replaced 17 days later by smaller services in `c21f32e` May 13. |
| **F2** | `OverviewView` `layoutPriority(1)` added then reverted 75 min later | branch-only | `fadc144` May 4 16:29 → `c88fe03` May 4 17:43 |
| **F3** | Two literal-duplicate v1.17.0 sync commits both landed | branch-only | `8f44536` ≡ `13f7fa3` (same 13-line patch, same session URL) |
| **F4** | SchedulesView exit-code parser brittle at intro, replaced ~14h later (Gemini-review-driven) | branch-only | `2d9e661` May 13 18:07 → `7a698b4` May 14 09:02 |

**Total quantifiable waste:** ~2,250 lines AI-generated + reviewed + landed +
deleted within the branch. ~98% of which is F1; the remaining three are
small-cost iterations. The other 153 commits show intentional iteration —
scoped polish, CI-driven fixes, granular design phases — not Claude rewriting
itself. Detailed verdicts per-file in `review/02-churn.md`.

---

## 6. Regression inventory (Phase 3)

| id | finding | file:line | severity |
|---|---|---|---|
| **R-01** | Out-of-spec fixture skip lacks BACKLOG entry | `CoreDashboardSecurityTests.swift:211` | SHOULD-FIX (= S-07) |
| **R-02** | `golden_workbook.xlsx` not shipped → 2 tests perpetually skipped | `OutputValidatorTests.swift:19` | CONSIDER (= C-01) |
| **R-03** | BACKLOG force-unwrap line numbers drifted | various | CONSIDER (= C-02) |
| **R-04** | `PDFExporter.swift:190` near-match warning | as listed | SHOULD-FIX (= S-05a) |
| **R-05** | `RiskScoringService.swift:183` deprecated `scanDouble` | as listed | SHOULD-FIX (= S-05b) |
| **R-06** | CLAUDE.md CLI section omits 9 of 19 subcommands | `CLAUDE.md` | CONSIDER (= S-08) |
| **R-07** | `build-app.sh release` no dry-run mode | `app/build-app.sh` | CONSIDER (= C-06) |
| **R-08** | Python `"Computer Name"` output-side hardcodes (6 sites) | `jamf-reports-community.py` various | CONSIDER (= C-05) |
| **R-09** | `Provenance.swift:15` docstring `"cbp-prod"` | as listed | CONSIDER (= C-04) |

**No** test files deleted on this branch (`+8` Python, `+134` Swift, `0`
deletions). **No** unconditional skips introduced. **No** view named in
CLAUDE.md is missing from HEAD. **No** CLI subcommand listed in CLAUDE.md is
gone. The structural regression surface is clean.

---

## 7. Skill audit summary (Phase 4)

**4a — `code-reviewer` agent:** Returned 6 findings (3 SHOULD-FIX, 3
CONSIDER, 0 MUST-FIX). Strongest: `SmartGroupApplyService.swift:189`
defaults `created` flag to `true` (= S-09), misleadingly showing "Smart
group created" for updates. Also surfaced large test-coverage gaps in
`JamfCLIDecoderTests` (18+ uncovered structs = S-10) and
`CoreDashboardTests` (8 uncovered sheet writers = S-11). Three CONSIDER
findings consolidated as C-15/C-16/C-17. The agent focused on the
Engine/ diff per the brief; the Python additions to
`jamf-reports-community.py` are largely covered by the existing pytest
suite (265 tests passing).

**4b — `refactoring-specialist` agent:** 10 findings. **1 false positive
(4b.1)**: claimed the four `Engine/Validators/*.swift` files (755 lines) were
dead code — verification shows extensive test usage in `OutputValidatorTests`
and `EngineCorrectnessTests`. Keep them. The other 9 stand and are folded
into SHOULD-FIX/CONSIDER above. Net adjusted removable lines: ~285. Plus one
real correctness bug (4b.10 / M-02): hardcoded `502` device count.

**4c — `general-purpose` agent (regression blind spots):** 5 paired
test-recommendations identifying gaps the existing suites would not catch:
whole-workbook parity Swift↔Python, archive/rotation past `keep_latest_runs`,
in-flight Process write across profile switch, non-atomic JSON write
poisoning fallback (= S-01), profile-name-with-dots label collision
(= S-03). Recommended adding a shared `MockTenantFixture` builder to retire
~50 lines of setup boilerplate per test.

**4d — `test-driven-development` skill:** Deferred. Will run after 4a's
MUST-FIX findings (if any) are surfaced. Note: M-01 and M-02 from this
report should each get a failing test written before any fix lands.

**4e-i — `/security-scan` (harness audit):** AgentShield grade **A
(93/100)**. Operator-side findings only (one critical:
`EMDASH_HOOK_TOKEN` + curl in a hook with `|| true`). Not blocking the
review; folded into CONSIDER C-14.

**4e-ii — `security-reviewer` agent:** 4 findings (1 MUST-FIX, 1 SHOULD-FIX,
2 CONSIDER). MUST-FIX (= M-01) is the headline: routine CLIBridge paths
skip codesign re-verification. Clean surfaces also enumerated — formula
injection, HTML XSS, SSRF, Sparkle key handling, argv construction — all
audited and pass.

**4f — `/council`:** Not invoked — no genuine judgment call requires
deliberation. Every finding has a clear remediation; none warrant a
keep-vs-revert debate.

---

## 8. Recommended next actions (smallest viable PR first)

1. **PR #1 — Correctness fixes (~30 lines, blocks release).**
   Wire live device count into `AgentCardView` (= M-02) and add `.atomic`
   to `CLIBridge.saveJSONSnapshot` (= S-01). Both are tiny touches with
   visible user impact. Add one regression test per fix: a unit test
   asserting `AgentCardView` pct math against an injected fleet count, and
   a test that drops a truncated JSON snapshot and asserts the fallback
   path rejects it.
2. **PR #2 — Codesign on routine paths (~80 lines, blocks release).**
   Add `CodeSignVerifier` check to `CLIBridge.run` / `runAndCapture`
   (= M-01). Cache the verified fingerprint in `JamfCLIIdentity` keyed by
   binary path + size + mtime so per-command verification is amortized.
   Change the `environment` default to `environmentForJamfCLI()` (= S-02)
   in the same PR — same file, same theme.
3. **PR #3 — Profile-slug regex tighten (~40 lines).**
   Disallow `.` in `ProfileService.isValid` (= S-03), add a migration check
   for any pre-existing dotted profile names, add the failing test from
   4c.5 first.
4. **PR #4 — SmartGroup integration safety (~20 lines).**
   Flip the `created` default in `SmartGroupApplyService` to `false`
   (= S-09); add the missing absent-field test. This protects the next
   live tenant run from a misleading "created" message during W15
   contract drift.
5. **PR #5 — Zero-warnings + skipped-fixture cleanup (~50 lines).**
   Fix `PDFExporter:190` and `RiskScoringService:183` (= S-05); re-shape
   the update-status fixture or add a BACKLOG entry (= S-07); decide
   whether to ship `golden_workbook.xlsx` or remove the two perpetually-
   skipped tests (= C-01).
6. **PR #6 — Decoder/dashboard test coverage (~400 lines of tests).**
   Add inline-JSON decode tests for the 18+ uncovered `Decodable` structs
   (= S-10) and fixture-backed writer tests for the 8 uncovered sheet
   writers (= S-11). Pure addition, no production code changes.
7. **PR #7 — Documentation drift (~30 lines of docs).**
   Update CLAUDE.md CLI section to all 19 subcommands (= S-08); refresh
   BACKLOG.md line numbers for the force-unwrap entries (= C-02); rename
   `"cbp-prod"` in `Provenance.swift:15` (= C-04).
8. **PR #8 — Templates simplification (~285 lines net deletion).**
   Apply 4b.2/4b.3/4b.5/4b.6/4b.7/4b.8 — drop `TemplateApplier`,
   `SectionRegistry`, `JamfCLIIdentity`, `CLISuggester.relevanceScore`,
   `WorkspaceMigration` result structs, `SummaryJSONParser` wrapper. No
   user-visible behavior change.
9. **PR #9 — Trivial CONSIDER cleanup (~10 lines).**
   Remove no-op `CodingKeys` blocks (= C-15); collapse dead `let`
   indirection in `ReportEngine.swift:68` (= C-16); add the
   `INTEGER → percentage` comment (= C-17).
10. **Backlog only — Phase 4c regression-test infrastructure.**
    Add `MockTenantFixture` and the five tests in 4c. These are blind-spot
    coverage rather than current bugs — they belong on the regression
    roadmap, not in a hotfix.

**Do not roll all eight findings into one PR.** The split above keeps each
PR ≤100 lines except for the test/infrastructure PR, gives each change a
clear blast radius, and matches the project's preference (per CLAUDE.md)
for small, focused commits.

---

## 9. Constraint compliance

- **No fixes were written during this review** — diagnosis only, per the
  prompt's constraint.
- **No `BACKLOG.md` items were deleted.** Items appended would belong to
  follow-up PRs, not this review session. The items above that are not
  already in BACKLOG.md should be appended in the same PR that addresses
  them.
- **Branch state not modified.** No commits, force-pushes, or rebases
  during review.
- **`/ultrareview` not invoked** (separate user-triggered tool, per
  prompt constraint).
- **Time budget:** budget was "None"; this review completed in ~25 minutes
  wall-clock, parallelizing 4 agents + 1 skill + build/test/CLI smoke
  alongside Phase 1/2/3 git work.

---

## 10. Phase artifacts

- `review/01-commit-map.md` — wave-by-wave timeline + top-25 hot files
- `review/02-churn.md` — F1-F4 within-branch waste in detail
- `review/03-regressions.md` — R-01 to R-09 with invariant audit
- `review/04-skill-findings.md` — agent outputs verbatim + verification
- `review/REPORT.md` — this file
