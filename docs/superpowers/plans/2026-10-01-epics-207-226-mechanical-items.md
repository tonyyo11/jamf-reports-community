# Epics #207 and #226 — mechanical items (wave A)

Base: `efae9496` (`v2.9.0-beta1`). Source: the 2026-10-01 triage of every unchecked item in
epics #207 and #226 against that commit and jamf-cli 1.31.1. This plan covers only the items
that need no owner decision and no on-screen layout check. Owner decisions (C1, #226 1b/3/5c,
the "Data refreshed" toast) and the chart roll-out (A3) are outside it, and so are the AI items
(G28, the Fleet Insight inversions), which wait for the insight-seam change.

No spec document: the epic issue text is the requirement. The full text of each item is in
`issue207-comments.md` and `issue226-comments.md` in this plan's workspace
(`.superpowers/sdd/2026-10-01-epics-207-226-mechanical-items/`); find an item with
`rg -n "G18" <file>`. Line numbers quoted in the issues and below are stale; locate code with `rg`.

## Global Constraints

- Work only inside your own worktree. Do not push, open a PR, or edit GitHub issues.
- Do not edit `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` or `BACKLOG.md`; put the proposed
  CHANGELOG line (plain language, what changed for the user) in your report instead.
- Before the first edit of each file, run `git log --oneline origin/main..HEAD -- <path>` and
  put the count in your report. At 3 or more, state why your change does not undo that work.
- One commit per item. Subject `fix(<scope>): <imperative, ≤72 chars>` (or `test`/`build`/`docs`),
  body names the item and the epic (`#207 G19`). No attribution or co-author trailers. Do not
  use: critical, crucial, essential, significant, comprehensive, robust, elegant.
- Test first: write the failing test, see it fail for the stated reason, then fix. A test that
  needs jamf-cli output uses an existing fixture under `app/Tests` or a shape documented in
  `CLAUDE.md` ("jamf-cli JSON Shapes"); never invent a shape. Say where each fixture came from.
- Tests never read or write the real `~/Jamf-Reports`, never run `jamf-cli`, and clean up any
  `UserDefaults` key they set with a per-test `defer` (no `tearDown` override on a
  `@MainActor` test class; Swift 6.1 on CI rejects it). A test class for a SwiftUI `View`
  type carries class-level `@MainActor`.
- Swift 6 strict concurrency; CI compiles with Swift 6.1, which is stricter about `@MainActor`
  than the local 6.4. No force-unwrap in production code, functions ≤100 lines, lines ≤100
  columns, no new package dependency, no new Service/View/Model file without a caller in the
  same commit.
- Match the surrounding code's comment density. Comments say why, in one or two lines.
- Do not change SwiftUI layout primitives (`HStack`, `VStack`, `frame`, `padding`, spacing,
  `layoutPriority`, `Spacer`) unless the item says so. If you must, put
  `DRAFT — needs visual verification` in that commit's body.
- No organisation-specific values anywhere (no real host names, tenant names, people).
- Delete files with `trash`, not `rm -rf`.
- Gate before each commit, from `<worktree>/app`:
  `swift build --build-tests 2>&1 | grep "error:" || echo OK`, then
  `swift test --filter '<SuiteA>|<SuiteB>'` for the suites you touched or added. Report the
  actual counts. Do not run the whole suite; the controller runs it at integration.
- If an item does not reproduce, or the fix would pass ~150 changed source lines, stop that
  item, leave the tree clean for it, and report what you found instead of building it.

## Task 1: Report correctness (G18, G19, G20, G21, G30)

Files: `Engine/CoreDashboard.swift`, `Engine/JamfCLIDecoder.swift`, `Services/MobileFleetService.swift`,
`Engine/HtmlReport.swift`, `Engine/OOXMLWriter.swift`, `Views/PatchView.swift`, tests.

- **G18** — The workbook's Mobile Fleet Summary (and the mobile device rows around
  `CoreDashboard.swift:1512-1610`) writes an unknown value as `0` or "Unmanaged" and reads model
  and serial from `general` when jamf-cli puts them under `hardware`, and activation lock,
  passcode compliance and jailbreak under `general` when they are under `security`. The app
  screens were fixed in 25d23cb and 18014f7 (`MobileFleetService`); make the workbook agree with
  them: read each field from the section that carries it (falling back to the old location),
  write an unmeasured value as an empty cell or "Unknown", never `0`, "Unmanaged" or "Clean",
  and do not put every device in one "Mobile" family when the family is known. Reuse
  `MobileFleetService`'s reading rather than adding a second one.
- **G19** — `HtmlReport`'s chart JSON embed escapes `</` only (`HtmlReport.swift:~1746`). Escape
  every `<` as `<` (and `>` and `&` as `>`, `&`) in JSON written into a `<script>`
  block. Test: a patch title containing `<!--` and `<script` leaves the report's later sections
  parseable (assert the raw sequences are absent from the script block).
- **G20** — `OOXMLWriter.stripControlCharacters` keeps U+FFFE and U+FFFF, which XML 1.0 forbids.
  Strip them (and unpaired surrogates if the function can see them). Test with a device name
  carrying U+FFFE: the sheet XML parses with `XMLParser`.
- **G21** — `asInt` (`HtmlReport.swift:~1713`, `CoreDashboard.swift:~3283`) traps on a Double
  outside `Int`'s range or a NaN from a corrupt snapshot. Use `Int(exactly:)` after rounding
  and return nil otherwise. Test with `1e300`, `-1e300`, `.nan`, `.infinity`.
- **G30** — Patch failure rows with no policy or device id all get the identity `"-"`
  (`JamfCLIDecoder.swift:~183`), so SwiftUI collapses them. Give a row without ids a stable
  identity built from its other fields plus its position; keep the id-based identity when ids
  exist.

## Task 2: Collect and tick honesty (G17, same-day retry on permanent causes, #226 5d, G31)

Files: `Engine/ReportEngine.swift`, `Services/ScheduledRunSignals.swift`, `App/main.swift`,
`App/Tick.swift`, `Services/ScheduledRunRecorder.swift`, `CLI/JamfReportsCLI.swift`, tests.

- **G17** — In `ReportEngine.collect`, `enforceCollectVerdicts` throws before
  `runDeviceScanPhase`, so a scan-tier run whose two matrix reports (`patch-device-failures`,
  `update-device-failures`) exit 0 with no data is declared dead and the per-device scan (which
  reads the cached `computers` snapshot) never runs. First reproduce it in a test through the
  `locateJamfCLI` seam (a stub not named `jamf-cli`). Required: a dead verdict that comes only
  from matrix kinds landing nothing must not veto the device scan; an auth-dead (exit 3) or
  outage verdict still aborts before it. The run's final verdict still reports the matrix
  failure as today. If it does not reproduce, report that and stop this item.
- **Same-day retry ignores permanent causes** (#207, 2026-09-26 comment) — `TickScheduler`
  retries a collect-mode schedule when `CollectHonestyWatcher.incomplete` is set
  (`main.swift:~626`), 1 h, 2 h, 4 h. A run whose only unlanded kinds carry a permanent recorded
  `FailureCause` (`isPermanent`) or exit 2/3/8 is retried although the retry cannot succeed.
  Required: such a run counts as complete for retry purposes only (same exclusion
  `DataFreshnessHealth` uses for self-remediation; reuse that predicate, do not copy it). Run
  History still shows it Partial. A run with at least one unlanded kind that is retryable still
  retries.
- **#226 5d** — Tick-level failures (a start or success stamp that cannot be written, a
  `tick-state.json` save failure) reach only stderr and OSLog (`Tick.swift:~146`). Record them
  through `ScheduledRunRecorder` under the tick's own label so Run History shows them. No new
  file; no change to which schedules run.
- **G31** — `jamf-reports school-scaffold` (a removed subcommand) or any unknown word opens the
  GUI, because `main.swift` routes only known subcommands to the CLI. Route any first argument
  that does not start with `-` to the CLI so ArgumentParser prints its unknown-command error and
  exits non-zero. Launch-services arguments (`-psn_…`, `-NS…`, `-Apple…`) start with `-` and
  must still open the GUI; `--tick` and `--scheduled-run` keep their own paths.
- **Stale comment** (G32 sub-item) — the Protect `data_dir` doc comment near
  `ReportEngine.swift:3112` describes a key removed in 2.8.1. Correct or remove it.

## Task 3: Overview and health strip (G15, G25, G16 with #226 5b, G27)

Files: `Services/SecurityAgentCoverage.swift`, `Services/OverviewLiveData.swift`,
`Views/OverviewView.swift`, `Services/RiskScoringService.swift`,
`Services/WorkspaceStore+Refresh.swift`, `Services/RefreshCoordinator.swift`,
`Services/WorkspaceStore.swift`, tests.

- **G15** — `ea-results` rows carry `ea_name, definition_id, device, value` and no device id
  (confirmed on jamf-cli 1.31.1), so coverage keys on the computer name: duplicate names
  collapse, and the count is divided by the security report's `total_devices`. Required: when a
  row has no id, count rows (not distinct names) and divide by the number of Macs reporting the
  attribute; keep the id-keyed path for data that has one. Also align the Devices risk check
  with coverage: a blank `connected_value` means "any value counts" in both
  (`SecurityAgentCoverage` since 38c5406; `RiskScoringService` still reads blank as unknown).
- **G25** — Overview live sections reload the whole inventory on every visit through a
  `Task.detached` that ignores `.task` cancellation (`OverviewView.swift:~885`). Make the load
  cancellable (structured task, `Task.checkCancellation` between section reads) and drop a
  cancelled load's result. Wording: "Across N active devices" must use the number of reporting
  Macs the section actually counted, and the agent card must not print "0 not installed".
  No layout changes.
- **G16 + #226 5b** — The scan tier's staleness probe reads one kind
  (`update-device-failures`). With `jamf_cli.collect_skip: [update-device-failures]` the prompt
  never clears, and without it the prompt can clear while `ddm-device-status` or
  `mdm-command-health` recorded failed. Required: a tier is stale when any of its kinds that
  the profile is expected to collect is stale, where "expected" goes through
  `WorkspaceStore.expectedKinds` (skip-expensive toggle, `collect_skip`, Platform-only kinds),
  so a kind the profile never collects cannot pin the prompt up. A tier whose expected set is
  empty is never stale.
- **G27 / G10** — In demo mode ⌘R's `reloadFromDisk` still calls `refreshToolStatus`, which
  runs `jamf-cli version`. Demo mode must not run jamf-cli: return early there. Onboarding's
  own jamf-cli check stays (it is by design).

## Task 4: Setup and onboarding (two 2026-09-29 setup-screen items, G22)

Files: `Views/ExistingCLISetupView.swift`, `Services/ExistingCLISetupFlow.swift` (or wherever the
setup flow's summary logic lives), `Services/CLIBridge.swift`, `Services/ConnectionCheck.swift`,
`Services/OnboardingFlow.swift`, tests.

- **Setup summary blames sign-in** — `completionSummary` (`ExistingCLISetupView.swift:~320`)
  says failed profiles "can re-collect from the Overview banner once jamf-cli auth is fixed"
  for any failure. Word it from the per-profile failures: mention sign-in only when a collect
  failed on credentials; when workspace initialization failed, name that cause. Put the wording
  decision in a pure function so it is testable without the view.
- **"Continue to dashboard" loops when nothing was created** — `finish()` (`:~379`) records setup
  as completed even when every selected profile failed to initialize, so ContentView shows a
  reset setup screen. When no workspace exists, do not record completion: keep the user on the
  setup screen with the causes shown and offer Skip instead of Continue. Text and button
  enablement only; no layout-primitive changes.
- **G22** — `CLIBridge.runAndCapture` has no timeout, and Validate's two `ConnectionCheck` calls
  cannot be cancelled. Add an optional `timeout:` parameter (default nil = today's behaviour,
  so collect paths are unchanged), terminate the child and return a distinguishable timed-out
  result when it elapses, and have `ConnectionCheck` pass 60 seconds. A timed-out check is
  "undecided", never "rejected ID". Test with a stub executable that sleeps (not named
  `jamf-cli`).

## Task 5: Settings, Protect and diagnostics (G38, G26, G23)

Files: `Views/SettingsView.swift`, `Views/ProtectView.swift`, `Views/ExtensionAttributesView.swift`,
`Services/DiagnosticBundleService.swift`, tests.

- **G38** — `SettingsView` removes a profile from `loadingTokenProfiles` in a `defer` inside the
  probe (`:~602`). When a profile switch cancels one `.task(id:)` and starts another, the
  cancelled task's `defer` can clear the new task's "checking…" flag. Skip the remove when the
  task was cancelled, and reset the set when a new task starts.
- **G26** — Protect shows Full Disk Access unknown (nil) as "No" (`booleanPill`,
  `ProtectView.swift:~659`); show "Unknown" in the neutral tone. Protect's timeline selection
  and the Extension Attributes selection survive a profile switch and a demo-mode switch, so a
  real host name can show on the demo screen: reset both selections when the profile or demo
  mode changes.
- **G23** — jamf-cli error text such as "Environment '<uuid>' not found" is logged by collect
  and reaches diagnostic bundles; `DiagnosticRedactor` has no rule for it. Seed the workspace
  profile's tenant ID and environment ID (from `jamf-cli config list` data the bundle service
  already has, or the profile's stored config) into the redactor as exact-match secrets, and
  add a general UUID rule only if it does not blank the bundle's own identifiers that readers
  need. Test: a log line carrying the seeded ID comes out with a placeholder.

## Task 6: Dashboard embed (G35, G36, G37)

Files: `Engine/HtmlReport+Dashboard.swift`, `Engine/ReportEngine+Dashboard.swift`,
`Tests/.../HtmlReportDashboardTests.swift` and the dashboard collect tests.

- **G35** — The embedded jamf-cli dashboard frame is sandboxed to `allow-scripts` but carries
  no Content-Security-Policy, so its scripts could make network requests. In
  `dashboardPageForEmbedding`, insert
  `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">`
  immediately after the page's opening `<head>` tag (case-insensitive, with or without
  attributes; if the page has no `<head>`, prepend one). Check a real jamf-cli 1.31 dashboard
  page for anything the policy would block (`rg -o 'src="[^"]*"|url\([^)]*\)|fetch\(|@import'`
  over a saved page under `~/Jamf-Reports/*/jamf-cli-data/dashboard/` if one exists — reading
  that one file is allowed for this check; do not copy its contents into the repo) and report
  what you found. Rendering in a browser is the controller's check.
- **G36** — The Protect retry finds its argument with
  `arguments.first(where: { $0.hasPrefix("--include-profile=") })`. A main profile literally
  named `--include-profile=…` (legal since 2.8.3) passed as `-p <name>` would match first and
  the fallback run would drop the `-p` value. Take the appended argument by position, or have
  `dashboardArguments` return it separately. Test with a main profile named
  `--include-profile=x`.
- **G37** — `HtmlReportDashboardTests`' "newest page wins" test writes the older-stamped page
  first, so file dates agree with filename stamps and a picker ordering by mtime would pass.
  Write the newer-stamped page first (or set mtimes explicitly so they disagree with the
  stamps) and add a `dashboard_… 2.html` sync-conflict copy that must not be picked.

## Task 7: Build scripts and config documentation (G32 rest, G34, G29, G8, G33)

Files: `.githooks/pre-push`, `.github/workflows/ci.yml`, `app/scripts/lib/versioning.zsh`,
`app/scripts/test-versioning.zsh`, `app/scripts/package-dmg.sh`, `app/build-pkg.sh`,
`app/build-app.sh`, the release script that hardcodes the DMG name (G8), `config.example.yaml`.
Shell conventions: zsh, match each script's existing style; run `zsh -n` and `shellcheck`
(where the script is already shellcheck-linted in CI) on every script you touch.

- **G32** — (a) the pre-push hook blocks on `error:` anywhere in the build output while CI
  matches `: error:`; make the hook match CI. (b) CI's failure listing reads only the test log;
  include the build log. (c) `jr_build_number` does not detect a shallow clone (commit count is
  wrong there); detect it (`git rev-parse --is-shallow-repository`) and fail with a message
  naming the fix, with a test in `test-versioning.zsh`. (d) `package-dmg.sh` names the DMG from
  `$1` without reading the built app's version; read the version from the app's `Info.plist`
  and fail if `$1` is given and disagrees. (e) `build-pkg.sh` defaults to a debug build but
  names the package like a release; make the name reflect the configuration or default to
  release — pick the smaller change and say which.
- **G34** — `build-app.sh` never prints the Swift toolchain. Print `swift --version` and the
  selected Xcode on every build. On `RELEASE=1` with a toolchain below Swift 6.4, print a
  warning that the build will have no AI Insights on macOS 27 (warn, do not fail).
- **G29** — `Info.plist` generation in `build-app.sh` sets `NSSupportsAutomaticTermination` and
  `NSSupportsSuddenTermination` to true, and nothing wraps GUI collect or generate in an
  activity, so macOS may terminate the app mid-run. Set both to false.
- **G8** — the release script hardcodes the release DMG name instead of using the versioning
  library; use the library's function.
- **G33** — keys the app reads but `config.example.yaml` does not document: `exceptions`,
  `sheets.order`, `compliance.framework`, `html.section_limits.*`, and nine `columns` keys.
  For each, confirm with `rg` that app code reads it (name the reader in your report) and
  document it in `config.example.yaml` in the file's existing commented style with its real
  default. Do not document a key nothing reads; list any such key in the report instead.
