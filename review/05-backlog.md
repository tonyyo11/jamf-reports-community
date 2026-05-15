# Sequenced PR Backlog — `dev-app/2.0` Post-Review Fixes

Execution ledger for the 10-PR sequence proposed in `review/REPORT.md` §8.
`REPORT.md` is the immutable source-of-truth for findings; this file
tracks execution state. Status values: `pending` / `in_progress` /
`done` / `deferred`.

**Dependency conflicts surfaced in Phase 0:**

1. **PR-2 expands `JamfCLIIdentity.swift`; PR-8 (C-11) wanted to inline
   and delete it.** REPORT.md M-01 remediation says "cache the verified
   fingerprint in `JamfCLIIdentity` so per-command re-verification is
   cheap" while C-11 calls it a "28-line two-constant file ... Inline."
   After PR-2 lands, the file is no longer a vestigial two-constant
   file. **PR-8 drops C-11 from scope.**
2. **REPORT path drift on S-01:** `CachedDataFallback.swift` lives in
   `Engine/`, not `Services/`. Using the actual path
   `app/Sources/JamfReports/Engine/CachedDataFallback.swift`.

No other file overlaps that force re-ordering. PR-7 updates the
"## CLI commands" section of CLAUDE.md; the foundation commit added a
new "## Anti-churn discipline" section — separate sections, no
conflict.

---

## PR-1 — Correctness fixes (M-02 + S-01)

- **status:** `done` (merged via PR #56, commit cd9eae3, 2026-05-15)
- **finding ids:** [M-02, S-01]
- **files it touches:**
  - `app/Sources/JamfReports/Views/OverviewView.swift` (lines 365, 716, 973, 983, 1025, 1028)
  - `app/Sources/JamfReports/Models/DemoData.swift` (add `totalDevices` constant for demo denominator)
  - `app/Sources/JamfReports/Services/CLIBridge.swift` (line 926 — atomic write; lines 114-117 — JSON validity probe on production read path)
  - `app/Sources/JamfReports/Engine/CachedDataFallback.swift` (validity probe + I/O-error preservation on the fallback library path — defense-in-depth even though it is currently test-only callable)
  - `app/Tests/JamfReportsTests/OverviewViewFleetCountTests.swift` (new) — AgentCardView pct math
  - `app/Tests/JamfReportsTests/CachedDataFallbackCorruptionTests.swift` (new) — library-side corruption rejection
  - `app/Tests/JamfReportsTests/CLIBridgeCachedSnapshotCorruptionTests.swift` (new) — production read-path corruption rejection
  - `app/Tests/JamfReportsTests/Engine/CLIBridgeFallbackTests.swift` (fixture update — non-JSON payload now correctly rejected by the validity probe)
- **depends on:** none (first PR after foundation)
- **acceptance criteria:**
  - `AgentCardView` percentages compute from the live device count
    (`DeviceInventoryService` snapshot already feeds adjacent tiles) —
    100-device tenant reads "47 / 100", not "47 / 502".
  - `CLIBridge.saveJSONSnapshot` writes with `options: [.atomic]`.
  - **Production read path** (`CLIBridge.cachedJSONSnapshots`,
    consumed by AuditView, HealthCheckView, CustomizationWizard)
    rejects truncated/partial JSON so corrupted snapshots don't render
    as empty/missing data with no warning.
- **pre-fix tests required:**
  - Failing test: `AgentCardView` (or the underlying view model) computes
    `pct = installed / fleetCount` against an injected `fleetCount=100`,
    asserts a specific string output that proves `502` is gone.
  - Failing test: drop a truncated JSON snapshot in a temp workspace,
    invoke `CLIBridge.cachedJSONSnapshots`, assert the corrupted file is
    filtered and a valid older snapshot is returned.
- **judgment-call?** `false`
- **threat-model-touch?** `false`
- **mid-PR scope correction (2026-05-15):** silent-failure-hunter
  surfaced that REPORT.md S-01 named
  `CachedDataFallback.swift:128-153` as the read-side remediation site,
  but `CachedDataFallback.loadFromCache` has **zero production
  callers**. The actual production read path is
  `CLIBridge.cachedJSONSnapshots`. PR-1 was expanded to add the JSON
  validity probe to both locations and a dedicated test against the
  production path. The acceptance criterion above was rewritten to
  reflect the corrected diagnosis.

---

## PR-2 — Codesign on routine paths (M-01 + S-02)

- **status:** `done` (merged via PR #57, commit eb683cc, 2026-05-15)
- **finding ids:** [M-01, S-02]
- **files it touches:**
  - `app/Sources/JamfReports/Services/CLIBridge.swift` (lines 123 `run`, 127 env default, 181 `runAndCapture`, 181 env default)
  - `app/Sources/JamfReports/Services/JamfCLIIdentity.swift` (extend with verified-fingerprint cache keyed on path + size + mtime)
  - `app/Sources/JamfReports/Services/CodeSignVerifier.swift` (already exists; called at install / onboarding only — likely just consumed, possibly extended with a cache-friendly entry point)
  - `app/Tests/JamfReportsTests/Services/CLIBridgeCodesignTests.swift` (or new)
- **depends on:** PR-1 (both touch `CLIBridge.swift`; sequencing PR-1 first keeps the diffs from colliding)
- **acceptance criteria:**
  - Every `process.run()` in routine command paths
    (`collect`, `audit`, `backup`, `deviceDetail`, `validateConnection`,
    `groupHygiene` — i.e. anything routing through `run` /
    `runAndCapture`) re-verifies `jamf-cli` codesign + Team ID before
    spawning.
  - Verified-fingerprint cache short-circuits repeat verifications when
    the binary's `(path, size, mtime)` is unchanged.
  - `CLIBridge.run()` `environment` parameter default is
    `environmentForJamfCLI()` not `nil`; callers passing `nil` no longer
    inherit `DYLD_INSERT_LIBRARIES` / `SSL_CERT_FILE` / etc.
- **pre-fix tests required:**
  - Failing test: stub a `CodeSignVerifier` that records calls; invoke
    `CLIBridge.run(.audit, ...)`; assert verifier was called before
    process spawn.
  - Failing test: invoke `CLIBridge.run()` without passing
    `environment:`; assert the resulting process environment matches
    `environmentForJamfCLI()` (not the parent env).
- **judgment-call?** `false`
- **threat-model-touch?** `true` (M-01 is the supply-chain trust-boundary
  finding; touches `jamf-reports-community-threat-model.md`)

---

## PR-3 — Profile-slug regex tighten (S-03)

- **status:** `done` (merged via PR #58, commit 0d8b3f4, 2026-05-15)
- **finding ids:** [S-03]
- **files it touches:**
  - `app/Sources/JamfReports/Services/ProfileService.swift` (`isValid` regex)
  - `app/Sources/JamfReports/Services/LaunchAgentWriter.swift` (line 362 label construction)
  - `app/Sources/JamfReports/Services/LaunchAgentService.swift` (line 150 `profileAndSlug(from:)` parser)
  - `app/Tests/JamfReportsTests/Services/ProfileServiceTests.swift` (regex assertions)
  - `app/Tests/JamfReportsTests/Services/LaunchAgentParsingTests.swift` (or `LaunchAgentServiceTests.swift` extension) — collision case
- **depends on:** none (no file overlap with PR-1/PR-2)
- **acceptance criteria:**
  - `ProfileService.isValid` rejects profile slugs containing `.`
    (recommended) OR label construction switches to an unambiguous
    separator. Choose one and stick with it.
  - Existing profiles with dots are flagged via a migration check on
    workspace discovery rather than silently breaking.
  - `LaunchAgentService.profileAndSlug(from:)` can no longer parse a
    dotted-profile label ambiguously.
- **pre-fix tests required:**
  - Failing test: a dotted profile name like `dummy.prod` with slug
    `daily` produces label `com.jamfreports.dummy.prod.daily`; current
    parser splits this as `profile=dummy`, `slug=prod.daily` (or
    similar). Assert the *desired* behavior (rejected at validation,
    or unambiguously parsed) which today fails.
- **judgment-call?** `false`
- **threat-model-touch?** `true` (S-03 touches the LaunchAgent label
  parsing trust boundary; threat model section on
  workspace/LaunchAgent isolation needs update)

---

## PR-4 — SmartGroup integration safety (S-09)

- **status:** `done` (merged via PR #59, commit 3868293, 2026-05-15)
- **finding ids:** [S-09]
- **files it touches:**
  - `app/Sources/JamfReports/Services/SmartGroupApplyService.swift` (line 189 default)
  - `app/Sources/JamfReports/Views/SmartGroupApplySheet.swift` (line 333 consumer — likely no change needed, just verify rendering)
  - `app/Tests/JamfReportsTests/Services/SmartGroupApplyServiceTests.swift` — `testDecodeResultAbsentCreatedDefaultsFalse`
- **depends on:** none (PR-2's CodeSign work touches Services/ but a different file)
- **acceptance criteria:**
  - When the jamf-cli `created` flag is absent from the decode payload,
    `SmartGroupApplyService` defaults to `false` (was `true`).
  - UI no longer renders "Smart group created" for what may be an
    update during PR #205 contract drift.
- **pre-fix tests required:**
  - Failing test: `testDecodeResultAbsentCreatedDefaultsFalse` — decode
    a payload with no `created` field; assert `result.created == false`.
- **judgment-call?** `true` (REPORT.md §7 explicitly flags this for
  council deliberation given PR #205 contract instability; council
  brief uses REPORT.md's framing: "A false 'updated' is silent; a
  false 'created' is actively misleading.")
- **threat-model-touch?** `false`

---

## PR-5 — Zero-warnings + skipped-fixture cleanup (S-05, S-07, C-01)

- **status:** `done` (merged via PR #60, commit b79eb64, 2026-05-15)
- **finding ids:** [S-05, S-07, C-01]
- **files it touches:**
  - `app/Sources/JamfReports/Services/PDFExporter.swift` (line 190 `WKNavigationDelegate` near-match)
  - `app/Sources/JamfReports/Services/RiskScoringService.swift` (line 183 deprecated `scanDouble`)
  - `app/Tests/JamfReportsTests/Engine/CoreDashboardSecurityTests.swift` (line 211 — reshape the update-status fixture OR add a BACKLOG entry)
  - `app/Tests/JamfReportsTests/Engine/OutputValidatorTests.swift` (line 19 — ship `golden_workbook.xlsx` OR remove perpetually-skipped tests)
  - `tests/fixtures/jamf-cli-data/update-status/*.json` (possibly — if fixture reshape chosen)
- **depends on:** none
- **acceptance criteria:**
  - `swift build` exits 0 with **zero** warnings (down from 2).
  - The `CoreDashboardSecurityTests.testWriteUpdateStatusFromFixture`
    skip is either eliminated (fixture reshaped to a valid
    `UpdateStatusReport` shape) or moved to BACKLOG with a tracked
    entry.
  - The two perpetually-skipped `OutputValidatorTests` either run (with
    `golden_workbook.xlsx` shipped) or are removed.
- **pre-fix tests required:**
  - Build/warning count regression: assert `swift build 2>&1 | grep -c warning:` returns 0. (Can be a CI step rather than a test.)
  - For S-07: if the fixture is reshaped, the reshape itself proves the test no longer skips. If deferred, the BACKLOG addition is the artifact.
  - For C-01: similar — fix proves itself, or removal proves itself.
- **judgment-call?** `false`
- **threat-model-touch?** `false`

---

## PR-6 — Decoder + dashboard test coverage (S-10, S-11)

- **status:** `pending`
- **finding ids:** [S-10, S-11]
- **files it touches:**
  - `app/Tests/JamfReportsTests/Engine/JamfCLIDecoderTests.swift` (extend with ~18 inline-JSON smoke tests)
  - `app/Tests/JamfReportsTests/Engine/CoreDashboardTests.swift` (extend with 8 sheet-writer fixture-backed tests — `writeComplianceDevices`, `writeComplianceRules`, `writeDDMStatus`, `writeBlueprintStatus`, `writeProtectOverview`, `writeProtectAlerts`, `writeProtectComputers`, `writeProtectInsights`)
  - `tests/fixtures/jamf-cli-data/` (existing fixtures only — no new fixture creation)
- **depends on:** none (pure addition, no production code change)
- **acceptance criteria:**
  - Every `Decodable` struct in `JamfCLIDecoder.swift` (currently 27+,
    of which ~9 covered) has at least one inline-JSON decode smoke
    test. Specifically named in REPORT.md: `ComplianceDeviceRow`,
    `ProtectAlertRow`, `MobileDeviceListRow`, `BlueprintStatusRow`, …
  - The 8 sheet writers using raw `[String: Any]` access each have a
    fixture-backed writer test following the existing
    `writeSmartGroups` pattern.
- **pre-fix tests required:**
  - This **is** the test PR. Each new test is its own failing-test
    boundary — confirm each fails for the right reason (e.g., remove
    a key from the fixture, assert the writer produces blank column /
    decoder produces nil, then put the key back and assert the
    expected populated state).
- **judgment-call?** `false`
- **threat-model-touch?** `false`

---

## PR-7 — Documentation drift (S-08, C-02, C-04)

- **status:** `pending`
- **finding ids:** [S-08, C-02, C-04]
- **files it touches:**
  - `CLAUDE.md` (CLI commands section — currently lists 10, actual is 19. Adds: `export-reports`, `backup`, `workspace-init`, `launchagent-setup`, `launchagent-run`, `multi-launchagent-run`, `capabilities`, `device`, `patch-managed`)
  - `AGENTS.md` (mirror)
  - `BACKLOG.md` (line-number drift: `LaunchAgentWriter:500` → `:528`; verify `DeviceInventoryService:195` `raw!` still there)
  - `app/Sources/JamfReports/Engine/Provenance.swift` (line 15 docstring: rename `"cbp-prod"` to a generic slug like `"prod"`)
- **depends on:** none (the just-committed anti-churn additions sit in a
  separate CLAUDE.md / AGENTS.md section; this PR touches "## CLI
  commands" only)
- **acceptance criteria:**
  - `CLAUDE.md` (and `AGENTS.md` mirror) "## CLI commands" section
    enumerates all 19 current subcommands of
    `jamf-reports-community.py`.
  - BACKLOG line-number references in the relevant entries match
    current HEAD line numbers.
  - `Provenance.swift:15` no longer contains internal-vocabulary
    `"cbp-prod"`.
- **pre-fix tests required:**
  - Not test-driven in the unit-test sense. The acceptance criteria
    are documentation invariants verified by reading the file. A
    sanity script (`python3 jamf-reports-community.py --help` lists
    all 19; diff against CLAUDE.md enumeration) is acceptable as a
    proxy for "test".
- **judgment-call?** `false`
- **threat-model-touch?** `false`

---

## PR-8 — Templates simplification + dead-code removal (S-06, C-09, C-10, C-12, C-13)

- **status:** `pending`
- **finding ids:** [S-06, C-09, C-10, C-12, C-13]
- **NOT in this PR:** C-11 (`JamfCLIIdentity.swift`) — PR-2 expanded it
  with the fingerprint cache; it is no longer dead code. Dropped from
  scope per Phase 0 conflict resolution.
- **files it touches:**
  - `app/Sources/JamfReports/Engine/Templates/*.swift` (S-06: collapse
    `TemplateApplier` into protocol-required computed properties on
    each `ReportTemplate`)
  - `app/Sources/JamfReports/Engine/SectionRegistry.swift` (C-09: inline 70-line single-call dispatcher into `HtmlReport`)
  - `app/Sources/JamfReports/Services/CLISuggester.swift` (C-10: delete dead private `relevanceScore` method at lines 67-94)
  - `app/Sources/JamfReports/Services/WorkspaceMigration.swift` (C-12: simplify over-engineered result structs at lines 62-78)
  - `app/Sources/JamfReports/Services/SummaryJSONParser.swift` (C-13: inline 30-line wrapper struct at lines 150-196)
  - Test files touching the above (renames or no-ops; verify all pass)
- **depends on:** PR-2 (PR-2 expands `JamfCLIIdentity.swift` which C-11
  originally proposed deleting; C-11 dropped from this PR)
- **acceptance criteria:**
  - `Templates/` ecosystem dispatches via protocol-required computed
    properties; `TemplateApplier` is deleted and its callers updated.
  - `SectionRegistry.swift` is deleted; its single use site inlined.
  - `CLISuggester.relevanceScore` is deleted.
  - `WorkspaceMigration` result structs collapsed to the minimum the
    one-shot caller needs.
  - `SummaryJSONParser` wrapper struct deleted; two stateless functions
    moved to call site or a one-line helper.
  - All existing tests pass; no new warnings.
- **pre-fix tests required:**
  - This is refactoring with no behavior change. The existing test
    suite is the regression net. Add a failing test only if a code
    path the refactor touches isn't already covered (e.g., the
    `template.identifier` dispatch path — verify each template still
    resolves correctly).
- **judgment-call?** `true` (REPORT.md §7 flags S-06 for council: is
  the Templates ecosystem genuinely static-table-as-polymorphism, or
  is it deliberate room-for-extension? Council brief surfaces
  REPORT.md's reading and asks for one round of devil's advocate.)
- **threat-model-touch?** `false`

---

## PR-9 — Trivial CONSIDER cleanup (C-15, C-16, C-17)

- **status:** `pending`
- **finding ids:** [C-15, C-16, C-17]
- **files it touches:**
  - `app/Sources/JamfReports/Engine/JamfCLIDecoder.swift` (lines 604-610, 616-628 — remove redundant identity-mapped `CodingKeys`; line 368 — one-line comment on INTEGER → percentage heuristic)
  - `app/Sources/JamfReports/Engine/ReportEngine.swift` (line 68 — collapse `let allFailures = coreFailures` to `return coreFailures`)
- **depends on:** none for file overlap. Logically last because it's
  trivial cleanup.
- **acceptance criteria:**
  - No-op `CodingKeys` blocks removed; existing decoder tests still
    pass (Swift synthesizes the same coding keys automatically).
  - `ReportEngine.swift:68` dead `let` indirection collapsed.
  - One-line comment added at `JamfCLIDecoder.swift:368` documenting
    the INTEGER → percentage assumption.
- **pre-fix tests required:**
  - Existing decoder tests are the regression net for C-15. If PR-6
    has landed, C-15 is even safer since the decoder coverage is
    substantially better.
- **judgment-call?** `false`
- **threat-model-touch?** `false`

---

## PR-10 — Deferred: regression-test infrastructure (Phase 4c)

- **status:** `deferred`
- **finding ids:** (Phase 4c blind-spot tests, not in main M-/S-/C- list)
- **rationale:** REPORT.md §8 marks this as "Backlog only — these are
  blind-spot coverage rather than current bugs". Adds `MockTenantFixture`
  builder + 5 paired tests (whole-workbook parity, archive/rotation,
  in-flight Process write across profile switch, atomic-write fallback,
  profile-name-with-dots collision).
- **depends on:** PR-1 (atomic-write fallback test concept overlaps
  with PR-1's S-01 regression test — verify scope doesn't duplicate)
- **acceptance criteria:** TBD when this is picked up.
- **judgment-call?** `false`
- **threat-model-touch?** `false`

---

## Phase 0 sign-off

- PR-2 → PR-1 dependency confirmed (CLIBridge.swift).
- PR-8 drops C-11 due to PR-2 expanding JamfCLIIdentity.swift.
- PR-7 doc-drift updates do NOT collide with the foundation commit's
  anti-churn section.
- PR-5 (S-07, CoreDashboardSecurityTests.swift) does NOT collide with
  PR-1 (S-01 regression test lives in CLIBridge / CachedDataFallback
  tests, not CoreDashboardSecurityTests).
- Council invocations planned: PR-4 (S-09) and PR-8 (S-06) only.
- Threat-model-touch PRs: PR-2 (M-01) and PR-3 (S-03). End-of-flow
  comprehensive sweep also planned per the prompt default.
- Threat-model cadence locked: per-PR for M-01 + S-03, comprehensive
  sweep at end. No alternating.

Total PRs: 9 to execute (1-9) + 1 deferred (10). All ≤ ~100 lines
production code except PR-6 (~400 lines of tests) and PR-8 (~285 lines
net deletion).
