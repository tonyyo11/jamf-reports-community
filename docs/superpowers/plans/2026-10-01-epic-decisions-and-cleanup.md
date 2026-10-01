# Epic decisions and unused-code cleanup

Owner decisions (2026-10-01) on items the epics held open, plus the cleanup that followed the
churn review. Epic item text is in `issue207-body.md`, `issue207-comments.md`,
`issue226-body.md` and `issue226-comments.md` under
`.superpowers/sdd/2026-10-01-epics-207-226-mechanical-items/` in the controller's worktree
(absolute path given in each dispatch). Line numbers in the issues are stale; locate code with `rg`.

## Global Constraints

- Work only inside your worktree. Do not push, open a PR, or edit GitHub issues.
- Do not edit `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` or `BACKLOG.md`; put the proposed
  CHANGELOG line and any CLAUDE.md sentence your change makes stale in your report.
- Before the first edit of each file, run `git log --oneline origin/main..HEAD -- <path>` and
  put the count in your report. At 3 or more, state why your change does not undo that work.
- One commit per logical change. Subject `<type>(<scope>): <imperative, ≤72 chars>`, body names
  the epic item (`#226 5c`). No attribution or co-author trailers. Do not use: critical,
  crucial, essential, significant, comprehensive, robust, elegant.
- Test first where behaviour changes. A test that needs jamf-cli output uses an existing
  fixture under `app/Tests` or a shape documented in `CLAUDE.md`; never invent a shape. Tests
  never read the real `~/Jamf-Reports`, never run `jamf-cli`, clean up `UserDefaults` keys
  with a per-test `defer` (no `tearDown` override on a `@MainActor` test class), and a test
  class for a SwiftUI `View` type carries class-level `@MainActor`.
- Swift 6 strict concurrency; CI compiles with Swift 6.1. No force-unwrap in production code,
  functions ≤100 lines, lines ≤100 columns, no new package dependency, no new
  Service/View/Model file without a caller in the same commit.
- Do not change SwiftUI layout primitives unless the task says so.
- New scripts are zsh, follow `~/.claude/rules/shell.md`, and must run on a stock GitHub macOS
  runner (git, grep, sed, awk, zsh only; no ripgrep, no Homebrew tools).
- Delete files with `git rm`; never `rm -rf`.
- Gate before each commit, from `<worktree>/app`:
  `swift build --build-tests 2>&1 | grep "error:" || echo OK`, then
  `swift test --filter '<SuiteA>|<SuiteB>'` for the suites you touched. Report actual counts.
- If something does not reproduce or a task would pass ~300 changed source lines, stop and
  report instead of building it.

## Task 1: Delete code only tests reference

Verified on 2026-10-01 to have no caller in `app/Sources` beyond its own declaration. For each,
re-verify with `grep -rnw <name> app/Sources` before deleting; if you find a production caller,
leave it and say so.

- `CLIBridge.runNow(profile:mode:)` (`Services/CLIBridge+Run.swift`) and its tests
  (`CLIBridgeRunNowTests.swift` and any other test that calls it). Keep
  `CLIBridge.newestCSV(in:)` and anything else in that file that has production callers; if
  the file is left empty, delete it.
- Decodable structs in `Engine/JamfCLIDecoder.swift` that only tests decode:
  `SoftwareInstallRow`, `AppStatusRow`, `CheckinStatusRow`, `HardwareModelRow`, `AuditItem`,
  `GroupAnalysisRow`, `PackageRow`, `EnvStatsReport`. `GroupRow` was reported unused but a word
  search finds other references: check it precisely (`grep -rnw 'GroupRow'`) and delete it only
  if nothing in `app/Sources` uses that exact type.
- `ReportEngine.writeEvidenceBundle`, `OnboardingFlow.slugify`,
  `HtmlSectionFormatters.renderPercentBar`, the `ConfigEAAdopter.adoptEAs` shim,
  `JamfCLIInstaller.defaultDirectInstallDirIsOnPATH`, `HtmlReport.buildCSSPublic`.

Delete the tests that exist only to exercise the deleted code (whole files when nothing else
is in them; individual test functions otherwise). Do not rewrite surviving tests. Report the
line counts removed from `app/Sources` and `app/Tests` separately.

## Task 2: CI guard against test-only symbols

Files: new `app/scripts/check-test-only-symbols.zsh`, new
`app/scripts/test-only-symbols.allow`, `.github/workflows/ci.yml`, `.githooks/pre-push`.

1. The script lists every type (`struct`, `class`, `enum`, `actor`, `protocol`) and every
   `func` declared in `app/Sources` whose name (a) is at least 6 characters, (b) is declared
   exactly once in `app/Sources`, (c) appears as a whole word nowhere else in `app/Sources`,
   and (d) appears as a whole word at least once in `app/Tests`. Those are symbols only tests
   use. Names in the allow-list file (one per line, `#` comments, each with a reason) are
   skipped.
2. Exit 0 with a one-line summary when clean. Otherwise print each symbol as
   `path:line: <name> is referenced only from app/Tests` followed by one line naming the
   allow-list file, and exit 1.
3. Run it against the tree after Task 1. Every symbol it reports is either a deliberate test
   seam (add it to the allow-list with a one-line reason) or unused code (list it in your
   report; do not delete it in this task).
4. Wire it into the existing CI lint job (keep job and required-check names unchanged) and
   into `.githooks/pre-push` before the build step. It must finish in under 30 seconds on this
   repo; say how long it took.
5. A test for the script: `app/scripts/test-check-test-only-symbols.zsh` builds a temporary
   tree with one test-only type, one used type and one allow-listed symbol, and asserts the
   exit code and output. Add it to CI next to `test-versioning.zsh`.

## Task 3: "Refresh finished with warnings" toast

Files: `Services/WorkspaceStore+Refresh.swift`, tests.

After a GUI collect, the toast says "Data refreshed" even when a source did not land. When
`CollectHonestyWatcher.incomplete` is set for that run, the toast text is
"Refresh finished with warnings — see Run History" and uses the warning style the toast
system already has (no new style). A stand-down and a clean run keep today's text. Every GUI
collect path that posts the toast (`runTierRefresh`, `runHeavyTierRefresh`, `runFirstCollect`,
and any other caller you find) goes through one helper that picks the text. Test the helper.

## Task 4: GUI collects take the tick lock (#226 5c)

Files: `Services/WorkspaceStore+Refresh.swift`, `Services/TickLock.swift` (or where `TickLock`
lives), `App/Tick.swift`, tests.

Today `automaticCollectMustWait` stands the GUI's automatic collects down while a tick runs,
but manual collects (`runTierRefresh`, `runHeavyTierRefresh`, `runFirstCollect`,
`initializeWorkspace`) take no on-disk lock, so a manual refresh beside a tick runs two
fan-outs against one profile.

1. Manual GUI collect paths acquire the tick lock for the duration of the collect, with the
   same keep-alive refresh the tick uses (`keepingAlive`, 5-minute refresh, 6-hour ceiling).
2. If the lock is held by another live process when a manual collect starts, the collect does
   not start; the user sees a toast "A scheduled run is in progress — try again when it
   finishes". Nothing is queued.
3. A tick that finds the lock held by the GUI exits with the existing `queuedExitCode` path,
   exactly as it does when another tick holds it; its run-now markers stay for the next wake.
4. The lock is always released: normal completion, a thrown error, task cancellation. A GUI
   process that dies leaves a dead pid, which the existing takeover rule already handles; do
   not add a second rule.
5. `TickLock`'s ownership check must tell "held by me" from "held by another live process" so
   the app's own automatic collects do not stand down for the app's own manual collect in a
   way that deadlocks; `isCollectInFlight` already covers in-process overlap.
6. Tests against a temporary lock directory: acquire/release around a stub collect; refusal
   when a live foreign pid holds it (use the test process's parent pid or a spawned `sleep`);
   release on throw and on cancellation.

## Task 5: One mobile fetch (#226 section 1)

Files: `Engine/ReportEngine.swift` (collect command matrix, `knownCollectKinds`),
`Services/CollectionTier.swift`, `Services/MobileFleetService.swift`,
`Engine/CoreDashboard.swift` and `Engine/HtmlReport*.swift` (readers of the retired kind),
`Views/MobileFleetView.swift` (one string that names the kind), `WorkspaceStore.expectedKinds`,
tests and fixtures.

On jamf-cli 1.29+ `pro mobile-device-inventory-details` is an alias of `pro mobile-devices`,
so the app fetches the same payload twice per inventory run and never requests the sections
its readers use.

1. Collect mobile devices once: `pro mobile-devices list` (the pre-1.29 spelling where
   `specNames` is false, as the matrix does today) with
   `--section GENERAL --section HARDWARE --section SECURITY --section USER_AND_LOCATION`.
   APPLICATIONS is not requested; the managed-apps figure stays a dash.
2. Retire the `mobile-device-inventory-details` kind: remove it from the collect matrix,
   `knownCollectKinds`, `CollectionTier`, freshness expectations, and the view string. Readers
   take the rich fields from the `mobile-devices-list` snapshot. Old
   `mobile-device-inventory-details` snapshots on disk stay readable as a fallback for a
   workspace that has not collected since the change (newest of either kind wins, by filename
   stamp).
3. Decoders read `passcodeCompliant`, `activationLockEnabled`, `jailBreakDetected` and
   `dataProtected` from `security`, falling back to `general`; model and serial from
   `hardware`, falling back to `general`. (Wave A's G18 already did this for the workbook; do
   not duplicate it, extend the shared reader if one exists.)
4. Fixtures: the mobile fixture gains a `security` and a `userAndLocation` section using
   exactly those field names (source: Jamf Pro API `v2/mobile-devices/detail` schema). State in
   your report that the section layout on jamf-cli 1.18 was not verified.
5. Report every doc that names the retired kind (wiki, ADR, CLAUDE.md, AGENTS.md) so the
   controller can update them.

## Task 6: One patch-compliance definition (C1)

Runs after the security-policy work has merged (it edits the same summary writer).

Files: `Engine/ReportEngine.swift` (summary builder's patch figure),
`Engine/CoreDashboard.swift` (`averagePatchCompliancePct`), `Services/TrendStore.swift`,
`Services/PatchStatusService.swift` if it has its own figure, tests.

Patch compliance is device-weighted everywhere: `Σ on_latest / Σ total` over titles with
`total > 0`, as a percentage. Today `summary.json`/Trends use an unweighted per-title average
and the workbook's average keeps zero-device titles, so three surfaces disagree.

1. One function computes it; the summary builder, the workbook and the Patch screen's fleet
   figure call it. Delete the other computations.
2. History: when Trends loads summaries, a day whose summary was written under the old
   definition is recomputed from that day's dated `patch-status` snapshot when one exists
   (newest snapshot stamped that local day; same sync-conflict filter as the other pickers),
   off the main actor, the way `backfillMobileCounts` works. A day with no snapshot keeps its
   recorded value. To tell old from new, the summary writer adds `patchPctBasis: "device"` to
   `summary.json` (lenient decode; absent means the old basis).
3. A `drops_more_than` alert on `patch_pct` is skipped when the two compared summaries differ
   in basis, the same rule `complianceIsProxy` uses.
4. Tests: the function on a three-title fixture where weighted and unweighted differ; the
   recompute; the alert skip.

## Task 7: An empty `sheets.only` means no restriction

Files: `Engine/ConfigDecoder.swift` (`SheetsConfig.applyTo`), `app/scripts/README.md`, tests.

Found during the build-script work: `config.example.yaml` ships `sheets: only: []` with the
comment "When non-empty, only the named workbook tabs are written", but `applyTo` builds a set
from `only` whenever it is non-nil, so an empty list filters out every sheet.

1. First establish whether it reaches users: write a test that decodes the shipped
   `config.example.yaml`'s `sheets` block and applies it to a two-sheet plan. If the YAML
   loader already turns `[]` into nil, or the default generate path never calls `applyTo` with
   this value, say so, keep the test, and change nothing else.
2. Otherwise: an empty `only` list is treated as absent. Test both an empty and a one-name list.
3. `app/scripts/README.md` still says `package-dmg.sh`'s first argument is required; it is now
   optional and checked against the built app's version. Correct that sentence.
