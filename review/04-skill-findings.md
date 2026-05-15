# Phase 4 — Skill-Driven Audits

Four agent runs in parallel + one harness scan via `/security-scan`.
Briefs given to each agent included: diff range `origin/main...HEAD`,
file scopes named in the prompt, BACKLOG.md items to skip, and the
already-known compiler warnings + Phase-2 churn finding for context.

This file consolidates the agent outputs. Each agent's section is its
own deliverable inputs into the final REPORT.md.

---

## 4a. Code review (`code-reviewer` agent)

6 findings (3 SHOULD-FIX, 3 CONSIDER). No MUST-FIX from this agent.

### 4a.1 (SHOULD-FIX) — SmartGroupApplyService misleading default
**Verified.** `SmartGroupApplyService.swift:189`:
`let created = json["created"] as? Bool ?? true`. The sheet view at
`SmartGroupApplySheet.swift:333` renders "Smart group created" vs
"Smart group updated" from this flag. When jamf-cli's response omits
the field — possible given PR #205 contract drift (`f80753b`) — the
default falsely surfaces "created" for what may be an update. **Fix:**
flip default to `false`. A false "updated" is silent; a false
"created" is actively misleading.

### 4a.2 (SHOULD-FIX) — JamfCLIDecoderTests has 18 of 27 structs uncovered
Inline-JSON decode tests exist for `SecurityReportItem` and
`UpdateStatusReport`; missing for 18+ peers including
`ComplianceDeviceRow`, `ComplianceRuleRow`, `DDMStatusRow`,
`BlueprintStatusRow`, `MobileDeviceListRow`, `MobileConfigProfileRow`,
`SmartGroupRow`, `ProfileStatusRow`, `CheckinStatusRow`,
`HardwareModelRow`, `AuditItem`, `GroupAnalysisRow`, `PackageRow`,
`EnvStatsReport`, `ProtectAlertRow`, `ProtectComputerRow`,
`ProtectInsightRow`, `ProtectOverviewItem`. Field renames in future
jamf-cli will silently empty columns instead of erroring.

### 4a.3 (SHOULD-FIX) — CoreDashboardTests missing for 8 sheet writers
`writeComplianceDevices`, `writeComplianceRules`, `writeDDMStatus`,
`writeBlueprintStatus`, `writeProtectOverview`, `writeProtectAlerts`,
`writeProtectComputers`, `writeProtectInsights` use raw `[String: Any]`
access — a typo'd key renders blank columns with no compile-time or
runtime error. Add fixture-backed writer tests.

### 4a.4 (CONSIDER) — Redundant CodingKeys in ComplianceDeviceRow/ComplianceRuleRow
`JamfCLIDecoder.swift:604-610` declares identity-mapped CodingKeys
(`case deviceId = "deviceId"`) Swift would synthesize automatically.
Remove the no-op block for clarity.

### 4a.5 (CONSIDER) — Dead `let` indirection in ReportEngine
`ReportEngine.swift:68`:
`let allFailures: [SheetFailure] = coreFailures` is immediately
returned and never mutated. Collapse to `return coreFailures`.

### 4a.6 (CONSIDER) — INTEGER → percentage heuristic uncommented
`JamfCLIDecoder.swift:368` maps `"INTEGER"` EA type to "percentage".
Reasonable default but lossy — INTEGER is also used for counts and
raw scores. Add a one-line comment so the assumption is visible to
future contributors.

---

## 4b. Code simplification (`refactoring-specialist` agent)

Agent returned 10 findings totalling ~1,040 claimed deletable lines.
**One material false positive identified by verification (#1 below)** —
the rest are actionable.

### 4b.1 (REJECTED) — "Validators are dead code (755 lines)"
Agent claim: `HTMLValidator`, `XLSXValidator`, `PNGValidator`,
`PDFValidator` under `Engine/Validators/` have no production callers.

**Verification:** `grep -rn` shows extensive test usage in
`app/Tests/JamfReportsTests/OutputValidatorTests.swift` (38 references)
and `app/Tests/JamfReportsTests/Engine/EngineCorrectnessTests.swift`
(P10-B-38/39/42/44 tests). The validators are output-correctness tools
for the test suite (XLSX zip integrity, HTML parse, PNG IEND chunk,
PDF header). Keep all four.

### 4b.2 (VALID) — `Templates/` ecosystem is static-table polymorphism
`Engine/Templates/ReportTemplate.swift` (179 lines),
`TemplateApplier.swift` (110), `TemplateResolver.swift` (53) + six
concrete template files. Protocol promises polymorphism but the
applier switches on the raw string `template.identifier`. **Fix:**
move per-template data into protocol-required computed properties,
delete `TemplateApplier`.

### 4b.3 (VALID) — `SectionRegistry.swift` single-call dispatcher
70 lines mapping `SectionID` → closure, used at one site in
`HtmlReport`. Inline into the caller. (Compare with `SheetRegistry`,
which is justified — handles skip/fail/unimplemented across multiple
paths.)

### 4b.4 (VALID) — `CLISuggester.relevanceScore` dead private method
`Services/CLISuggester.swift:67-94`. Never called. Delete.

### 4b.5 (VALID) — `CLISuggester` forwarding layer
Lines 36-65 only rename + forward to `TemplateApplier`. Disappears
naturally if 4b.2 is applied.

### 4b.6 (VALID) — `JamfCLIIdentity.swift` two-constant file
28 lines, only used as default parameter values at
`OnboardingFlow.swift:416-417`. Inline.

### 4b.7 (VALID) — `WorkspaceMigration` result types over-engineered
`ProfileResult`/`RunResult` structs (lines 62-78) exist to describe a
one-shot migration whose only consumer logs failures. Replace with a
`Bool` return.

### 4b.8 (VALID) — `SummaryJSONParser` wrapper around 2 functions
Lines ~150-196. Make `parse` / `parseDirectory` static methods on
`DailySummary` or top-level functions.

### 4b.9 (VALID, low priority) — `RefreshPolicy` 1-instance struct
97 lines, only ever instantiated as `.default` in production. Keep
**only** if tests inject non-default values; otherwise inline.

### 4b.10 (VALID — REAL BUG) — `AgentCardView` hardcoded `502` literal
**Material defect.** `OverviewView.swift` lines 365, 716, 973, 983,
1025, 1028 — security agent coverage % uses **502** as the fleet
denominator. Six locations. A 100-device fleet renders "47 / 502 =
9.4%" when actual coverage is 47%. Likely a demo-data leftover. **Fix
required:** thread the live device count from the data source.

### Net adjusted total deletable lines
After excluding 4b.1: ~285 lines (Templates ecosystem +
SectionRegistry + JamfCLIIdentity + relevanceScore + MigrationResult
+ SummaryJSONParser wrapper). Plus 4b.10 is a correctness fix, not a
deletion.

---

## 4c. Regression blind spots (`general-purpose` agent)

Top 5 regressions the existing test suite would NOT catch:

### 4c.1 Whole-workbook parity drift Swift vs Python
Sheet writers tested individually; whole-workbook comparison missing.
KPI math (e.g. `SecurityScoreCalculator` denominator renormalization,
`ReportEngine.swift:307,338,362` `decodeIfPresent` changes) can produce
silently different cell values vs Python. Add Swift XCTest comparing
against a Python-generated golden xlsx for the same fixture.

### 4c.2 `cmd_generate` archive/rotation past `keep_latest_runs`
`test_automation.py:140-168` covers `keep_latest_runs=1`; no test runs
`cmd_generate` 11+ consecutive times with `keep_latest_runs=10`, so
`_archive_old_output_runs` resilience past the boundary and `.partial`
crash-rename behaviour at `jamf-reports-community.py:12277` are
untested.

### 4c.3 In-flight `CLIBridge.Process` writes to old profile after mid-collect switch
`RefreshCoordinator.swift:89-90` cancels the debounce `Task`, not the
running `Process`. `CLIBridge.saveJSONSnapshot` at line 897 resolves
`dataDir` at write-time. Switching profiles mid-flight can land
snapshots in the wrong workspace.

### 4c.4 Non-atomic JSON write → truncated cache poisons fallback path
**Strong finding.** `CLIBridge.swift:926` writes JSON with
`try data.write(to: file)` — not `.atomic`. Python equivalent writes
`tmp_path = out_path.with_suffix(".partial")` then renames.
`CachedDataFallback.swift:141,153` filters by filename suffix only, not
JSON validity — a truncated snapshot from a crash will be picked up by
the live-failure fallback and dashboards render half-loaded data while
the run appears green. **Fix:** use `[.atomic]` write option (or
write-tmp-then-rename); add validity test on read.

### 4c.5 Profile names containing dots collide in LaunchAgent label parsing
**Strong finding.** `ProfileService.isValid` regex
`^[a-z0-9][a-z0-9._-]*$` permits dots. `LaunchAgentWriter.swift:362`
builds labels `com.jamfreports.<profile>.<slug>` and parses back by
splitting on `.` (`LaunchAgentService.swift:150`). A `dummy.prod`
profile with `daily` slug yields `com.jamfreports.dummy.prod.daily`
which parses ambiguously. Path-side `hasPrefix` checks protect dirs;
label parsing does not. **Fix:** tighten regex to disallow `.` OR use
`/` or another separator between profile and slug in labels.

### Sandbox-mode recommendation

Add `app/Tests/JamfReportsTests/Fixtures/MockTenantFixture.swift` — a
builder that constructs a temp `~/Jamf-Reports/<profile>/` from
`tests/fixtures/jamf-cli-data/`, injects a `CLIExecutor` stub returning
fixture JSON, and exposes `runFullCycle() -> URL`. Tests 4c.1/4c.3/4c.4
all depend on this; building once retires ~50 lines of setup
boilerplate per test.

---

## 4d. TDD-driven failing tests (`test-driven-development` skill)

Run after 4a. Will populate after 4a's MUST-FIX findings arrive.

(deferred — will populate if 4a produces MUST-FIX findings)

---

## 4e. Security audit

Two surfaces audited:

### 4e-i. `.claude/` harness config (`/security-scan`)

`npx ecc-agentshield scan --path .claude` ran clean. **Grade A (93/100).**

| category | score |
|---|---|
| Secrets | 100/100 |
| Permissions | 93/100 |
| Hooks | 74/100 |
| MCP Servers | 100/100 |
| Agents | 100/100 |

Findings — all from `settings.local.json` (operator harness, not in the
codebase):

| severity | finding |
|---|---|
| critical | `settings.local.json:8` — hook combines `$EMDASH_HOOK_TOKEN` env access with `curl POST` (data-exfil pattern). Justifiable for emdash session-status notifications, but worth pinning the endpoint and ensuring the token has limited scope. |
| medium | No `permissions` block (relies on Claude Code defaults) |
| medium | Two `|| true` error-suppressing hook commands |
| medium | No `PreToolUse` security hooks configured |

These are local-operator harness items, not branch deliverables. The
emdash-notifications hook is the source of the critical finding and the
two `|| true` suppressions — it's expected for that integration to
silently tolerate missing tokens. Not blocking the review.

### 4e-ii. Code-side audit (`security-reviewer` agent)

Four findings: 1 MUST-FIX, 1 SHOULD-FIX, 2 CONSIDER.

#### S-01 (MUST-FIX) — CLIBridge skips codesign on routine paths
**Verified.** `CodeSignVerifier.verify(url:expectedTeamID:)` is called
only in `JamfCLIInstaller.swift:543` (install) and
`OnboardingFlow.swift:418` (onboarding). Every routine subprocess
invocation in `CLIBridge.swift` (`collect`, `audit`, `backup`,
`deviceDetail`, `validateConnection`, `groupHygiene`) launches
jamf-cli without re-verifying. On a Homebrew install,
`/opt/homebrew/bin/` is owned by user (not root) and writable to
group `admin`; a binary replaced after onboarding is invoked with
live API credentials in env / stdin. **Fix:** call `CodeSignVerifier`
before each `process.run()` in CLIBridge, with a TOFU-style
"verified-fingerprint" cache in `JamfCLIIdentity` to avoid
re-verifying every command.

#### S-02 (SHOULD-FIX) — `CLIBridge.run()` defaults environment to nil
**Verified.** `CLIBridge.swift:127`: `environment: [String: String]? = nil`.
When nil, `Process` inherits the full parent environment (including
`DYLD_INSERT_LIBRARIES`, `SSL_CERT_FILE`, any `JAMF_CLI_*` overrides).
All current call sites pass `environmentForJamfCLI()` explicitly, so
not exploitable today — but the default is unsafe. **Fix:** change
the default to `environmentForJamfCLI()` so safe behavior is the
path of least resistance. Same applies to `runAndCapture` at
line 181.

#### S-03 (CONSIDER) — LaunchAgent plist umask race window
`LaunchAgentWriter.swift:89,419` — `data.write(to:options:.atomic)`
creates the plist at umask-default (typically 0644), then a separate
`setAttributes` chmod to 0600 closes the read. Sub-millisecond window
where a co-tenant process can read profile name + command path.
**Fix:** set restrictive umask (`umask(0o177)`) before write, restore
after — eliminates the race rather than racing to close it.

#### S-04 (CONSIDER) — SystemActions HFS+ case-collision via `hasPrefix`
`SystemActions.swift:57` — `canonicalize()` uses byte-for-byte
`hasPrefix(parentPath + "/")`. On case-insensitive HFS+,
`~/Jamf-reports/` (lowercase 'r') resolves to the same dir as
`~/Jamf-Reports/` but mismatches the prefix check. A symlink placed
inside a mismatched-case clone could bypass the allow-list. **Fix:**
lowercase both sides before comparison, or use URL equality after
resolution.

#### Clean surfaces (no findings)
- `_safe_write` invariant holds for all 5 direct `ws.write()` calls
  in `jamf-reports-community.py` (all static literals)
- `HtmlReport` uses `html.escape(quote=True)` throughout
- Teams webhook SSRF: https-scheme enforced
- `build-app.sh` Sparkle key handling: three-layer guard (required
  env var + regex validation + PlistBuddy substitution +
  post-assertion)
- `CLICommand` argv construction: separate array elements, no shell

---

## 4f. Council deliberation

Reserved for genuine judgment calls surfaced by 4a / 4b. Not invoked
speculatively.
