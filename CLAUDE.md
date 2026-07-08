# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This file orients AI coding assistants working on this project. Read it before making
any changes.

> **Note:** `AGENTS.md` is a mirror of this file for OpenAI-compatible agents. Keep them
> in sync when making changes here.

> **Note:** Deferred review findings out of scope for the current change are tracked as
> category-epic issues on GitHub; `BACKLOG.md` at the repo root is the index. Check the
> relevant epic before starting work — you may be picking up an item already triaged.
> When you fix an item, check it off in its epic issue and reference the issue in the
> commit. When you defer a new finding, add it to the matching epic rather than leaving
> a TODO.

---

## What This Project Is

This project is a native macOS app (`app/`) — a SwiftUI GUI (macOS 14+, Swift 6) for fleet
reporting against Jamf Pro and Jamf School. It collects data from `jamf-cli` (or a Jamf Pro
CSV export, or cached snapshots), generates multi-sheet Excel workbooks and self-contained
HTML reports, schedules unattended runs via LaunchAgents, tracks run history, and surfaces a
Historical Trends screen built on archived `summary.json` snapshots. It also generates Jamf
School reports from `jamf-cli school` data and/or Jamf School device CSV exports.

All report generation is performed by a native Swift engine (`ReportEngine`); there is no
Python in the report-generation path. Diagnostic bundles are produced natively by
`DiagnosticBundleService` and the in-app Settings → "Generate diagnostic bundle now" button.
The app is config-driven: users map their CSV column names to logical field names in
`config.yaml` (edited through the GUI), with no code changes needed for normal use. It is a
SwiftPM project (`app/Package.swift`), not a hand-rolled `.xcodeproj`.

The same binary also ships an included `jamf-reports` command-line interface (a recognized
subcommand runs headlessly; no arguments opens the GUI), so reports, collection, backups,
and diagnostics can be scripted. See **Included CLI** below.

Target audience: Mac/iPad admins at any organization running Jamf Pro or Jamf School.
The code must not contain any org-specific values.

---

## Anti-churn discipline

This branch absorbed substantial AI-assisted churn during its initial build,
including 2,171 lines of scaffolded dashboards deleted as "dead code" three
days after landing and a same-day SwiftUI layout self-revert 75 minutes
after merge. The rules below exist to keep that from recurring. Read them
before the first edit of every session.

**The GitHub epic issues (indexed in `BACKLOG.md`) are the authoritative live
inventory of valid-but-out-of-scope findings.** Read the relevant epic before
any change adjacent to a flagged area. Fix only items in the current PR's
scope; log all others to the matching epic issue per protocol. When you fix an
item, check it off in its epic issue and reference the issue in the commit.

**Branch-history check before edit.** Before editing any file, run
`git log --oneline origin/main..HEAD -- <path>` and state the count in
the conversation. If the file has ≥3 commits on this branch, articulate
explicitly: "I've touched this file N times on this branch. Today's
change is X. This is not undoing my prior work because Y." If you can't
write Y, reconsider whether the change is necessary. A `PreToolUse` hook
auto-surfaces this history for every `Edit`/`Write` call — don't ignore
the output.

**No scaffolding without wiring.** Do not add a new
Service/View/Model/Engine file unless a caller for it lands in the same
PR. A button, a tab, a route, or a test that exercises it — something
concrete. "I'll wire it up next session" is not acceptable scope. If the
natural change requires scaffolding ahead of consumption, split into two
PRs: caller-first (with stub or empty state), then the real
implementation.

**SwiftUI layout-primitive changes require visual verification.** Before
committing any change to `HStack`, `VStack`, `LazyVGrid`, `frame`,
`layoutPriority`, `Spacer`, padding, or spacing values, launch the app
or describe explicitly how you verified the layout at
`PageScaffold.minSupportedWidth`. "Looks reasonable in the code" is not
verification. If you can't visually verify in the session, mark the
commit body `DRAFT — needs visual verification` and ask the user to
verify before merging.

**No same-session self-reverts without explanation.** If you find
yourself editing a file you authored a commit on earlier in the same
session, stop. State why the prior commit was incomplete and why the
new approach won't repeat the cycle. Commit message bodies should
reference the SHA of the commit being revised.

---

## Architecture

The report engine and every workflow live in the native macOS app — see
**Swift App Architecture** below. The shared `config.yaml` schema is documented in the next
section.

---

## Config System — Critical Rules

`config.example.yaml` is the **canonical, working example** of the config structure — the
same key names the app reads, no extras. The app's config defaults and decoding
(`ConfigDecoder` and the per-service config readers in `app/Sources`) are the source of
truth for which keys exist and their defaults.

**Never add a key to `config.example.yaml` that is not read by the app.** Phantom keys
mislead users and are difficult to audit.

When adding a new config key:
1. Give it a sensible default in the app's config decoding/defaults.
2. Read it from config in the relevant service.
3. Document it in `config.example.yaml` with a comment.
4. Update `README.md` if it's user-facing.

### Actual key names (common source of confusion)

The config uses these names — use them exactly:

| Section | Key | Not |
|---------|-----|-----|
| `columns` | `operating_system` | `os_version` |
| `columns` | `last_checkin` | `last_contact` |
| `columns` | `email` | `assigned_user_email` |
| `jamf_cli` | `profile` | `jamf_profile` |
| `jamf_cli` | `allow_live_overview` | `live_overview` |
| `security_agents` | `connected_value` | `installed_value` |
| `compliance` | `failures_count_column` | `failed_count_column` |
| `compliance` | `failures_list_column` | `failed_list_column` |
| `custom_eas boolean` | `true_value` | `compliant_value` |
| `custom_eas percentage` | `warning_threshold` / `critical_threshold` | `high_threshold` |
| `custom_eas version` | `current_versions` (list) | `min_version` |
| `custom_eas date` | `warning_days` | `warn_within_days` |
| `thresholds` | `stale_device_days` | `inactive_device_days` |
| `output` | `output_dir` | `directory` |
| `output` | `keep_latest_runs` | `max_runs` |
| `charts` | `historical_csv_dir` | `snapshot_dir` |
| `charts` | `archive_current_csv` | `auto_archive` |

### jamf_cli config

```yaml
jamf_cli:
  data_dir: "jamf-cli-data"   # where JSON snapshots are stored
  profile: ""                 # jamf-cli -p/--profile name (for multi-tenant use)
  use_cached_data: true       # fall back to latest cached JSON on live failures
  allow_live_overview: true   # set false to force cached-only for Fleet Overview
  collect_skip: []            # report types to skip during `collect` (on-prem stall guard)
```

When using multiple Jamf Pro instances, set `data_dir` to a profile-specific path so
snapshots from different tenants don't overwrite each other.

`collect_skip` accepts any of: `patch-device-failures`, `profile-status`,
`update-status`, `update-device-failures`. These are the four per-device-heavy
queries known to stall on-prem Jamf Pro. Underscores and hyphens are
interchangeable. Core inventory commands always run.

### output config

```yaml
output:
  output_dir: "Generated Reports"
  timestamp_outputs: true        # append date/time to output filenames
  archive_enabled: true          # move older runs to archive_dir
  archive_dir: ""                # defaults to "archive" next to output file
  keep_latest_runs: 10           # how many timestamped runs to keep in output_dir
```

### notify config (v2.2.0 — opt-in webhook digest)

```yaml
notify:
  enabled: false        # OFF by default
  provider: "teams"     # teams | slack
  url: ""               # https:// incoming webhook URL
  detail: "full"        # full | minimal (2.6) — minimal sends event facts only
```

Read by `NotifyConfig` (the scheduled-run webhook digest). Editable in-app via
AutomationView's Notifications section (2.6), backed by
`NotifyConfigLoader`/`NotifyConfigWriter` — the AIConfigLoader/Writer pattern: a
scoped read/atomic write of ONLY the `notify:` top-level key, deliberately not
routed through `ConfigService`'s managed-key contract. Known limitation:
`AutomationTab` routes to AutomationView only in managed mode, so
unmanaged-mode (hand-built-schedule) operators must still edit the YAML. Report
*grouping* is NOT a config.yaml key — `report_groups` lives on the app-level
`AutomationPolicy` (`@AppStorage`), edited in `AutomationView`.

**Webhook egress discipline (2.6).** Cards never contain report files or
device-level rows — only aggregate metrics, statuses, and operational names.
`notify.detail: minimal` reduces every card to event facts (counts/statuses, no
values, no error text, no schedule names) for headless/high-security hosts. The
failure card's error text is `LogRedactor`+`DiagnosticRedactor`-scrubbed before
egress; all titles/facts pass `WebhookNotifier.sanitize` (Slack mention/link
escaping; Teams FactSet fields are inert to markdown). Fact assembly (and the
minimal-mode reduction) lives at the call sites (`main.swift`,
`WorkspaceStore+Automation`); the `WebhookNotifier` builders stay dumb formatters.

### retention config (v2.2.0 — admin-controlled snapshot lifecycle)

```yaml
retention:
  enabled: false           # OFF by default — raw snapshots kept indefinitely
  mode: "archive"          # archive (move to archive_dir) | delete
  snapshot_keep_days: 365  # age horizon (<=0 disables the age rule)
  snapshot_keep_count: 0   # newest-N floor per kind (0 = none)
  include_summaries: false # leave the durable trend summaries alone
  archive_dir: ""          # default <workspace>/_archive (distinct from output.archive_dir)
```

Raw `jamf-cli-data/<kind>/` snapshots are a reporting input (per-device
day-over-day history), so retention is **off by default** — nothing is removed.
When enabled, a file is kept if EITHER the age horizon or the count floor
protects it. Non-snapshot subdirs (`state`, `sofa`) and `_`-prefixed dirs are
never swept. Swift: `SnapshotRetentionService.sweepIfDue` runs at the top of
`ReportEngine.collect` (once/day via a `.retention-last` marker at the workspace
root, OUTSIDE the swept tree) — covering every collect path including headless
scheduled runs; the old RefreshCoordinator delete-at-90d sweep was removed.
**Behavior change:** existing app users move from auto-pruned-at-90d to keep-everything.
Per-device raw-history *rendering* (reading dated raw snapshots, not just
summaries) is a planned follow-up; retention makes the raw durable for it.

### security_agents format

`security_agents` is a **list**, not a dict. `connected_value` is a case-insensitive
substring match:

```yaml
security_agents:
  - name: "CrowdStrike Falcon"
    column: "CrowdStrike Falcon - Status"
    connected_value: "Installed"
```

### custom_eas format

`custom_eas` is a **list**, not a dict:

```yaml
custom_eas:
  - name: "FileVault Status"
    column: "FileVault 2 - Status"
    type: boolean
    true_value: "Encrypted"
```

### Custom EA type reference

| Type | Behavior | Key config fields |
|------|----------|-------------------|
| `boolean` | Pass/fail counts, optional "Unknown" row | `true_value` |
| `percentage` | Distribution table, color-coded rows | `warning_threshold`, `critical_threshold` |
| `version` | Version distribution, optional status coloring | `current_versions` (list) |
| `text` | Value frequency table | — |
| `date` | Days-until-expiry, color-coded by proximity | `warning_days` (or `thresholds.cert_warning_days`) |

### Charts config

```yaml
charts:
  enabled: true
  save_png: true
  embed_in_xlsx: true
  historical_csv_dir: "snapshots"   # dated CSV snapshots for trend charts
  archive_current_csv: true         # auto-copy current --csv into historical_csv_dir
  os_adoption:
    enabled: true
    per_major_charts: true          # one chart per major macOS version
  compliance_trend:
    enabled: true
    bands:                          # failure count buckets — customize labels/colors
      - {label: "Pass", min_failures: 0, max_failures: 0, color: "#4472C4"}
  device_state_trend:
    enabled: true                   # managed/unmanaged + stale counts over time
```

Charts require `columns.operating_system` (OS adoption) and
`compliance.failures_count_column` (compliance trend).

---

### Swift App Architecture

The macOS app lives in `app/` and is a SwiftPM executable target (`JamfReports`).
Build target: macOS 14+ (Sonoma), Swift 6 strict concurrency.

#### Key services

| Service | Purpose |
|---------|---------|
| `WorkspaceStore` | `@Observable` per-profile state. Sidebar chip switches the active profile; every screen re-routes to that workspace's data. |
| `CLIBridge` / `CLIBridge+Run` | `Process`-based async wrapper for `jamf-cli` and `ReportEngine`. Streams stdout/stderr live to the Runs screen. All report generation uses the native Swift engine; no Python subprocess calls. `runNow(profile:mode:)` is the canonical Schedule-mode dispatcher — see Schedule mode contract below. `explainExit(_:operation:)` (nonisolated static) maps a jamf-cli exit code to a plain-language cause + remediation (3→re-auth/401, 5→privileges/403, 6→throttled/429, 4→404, 1→network/per-command); used by every view that surfaces a non-zero exit instead of a bare number. |
| `WorkspacePaths` | Typed, profile-validated path constants under `~/Jamf-Reports/<profile>/`. All path construction goes through here. |
| `ProfileService` | Validates profile slugs (`^[a-z0-9][a-z0-9._-]*$`), resolves workspace URLs, discovers local profiles. |
| `LaunchAgentService` | Discovers and parses existing `~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist` jobs. |
| `LaunchAgentWriter` | Generates LaunchAgent plists and writes them atomically. |
| `OnboardingFlow` | Orchestrates first-run: jamf-cli auth via PTY-driven `stdin`, profile creation, workspace init, first collect/generate run. Supports four connection flows: Jamf Pro OAuth2 (`config add-profile`), Platform Gateway (`config add-profile --auth-method platform --tenant-id`), Jamf Protect (`protect setup`), Jamf School (`school setup`). Protect/School are optional "Add Products" additions (also reachable post-onboarding from SourcesView via `ProductConnectSheetView`); success wires `protect.enabled/profile` and `school_cli.enabled/profile` into config.yaml. Secrets: PTY stdin only, redacted output, cleared after use; `SecureSecretField` reports a has-text Bool (never content) so the Continue button enables while typing. |
| `ConfigService` | Reads and writes `config.yaml` within a profile workspace. Only rewrites managed top-level keys and re-reads the rest, so unrelated/unmanaged config is preserved verbatim (this is what makes additive merges/adoptions safe). Int-typed custom-EA keys (`warning_threshold`/`critical_threshold`/`warning_days`) are omitted when empty/non-numeric — never written as `key: ""`, which the report engine's `Int?` decode rejects. |
| `ConfigEAAdopter` | Appends CSV-detected columns into `config.yaml` as `custom_eas` and/or `security_agents` in one load/save (`adopt(eaProposals:agentProposals:connectedValues:)`); per-section case-insensitive column de-dup. `adoptEAs` is a shim over it. Backs the CSV → EA walkthrough's "Adopt as" picker. |
| `ScaffoldService` | CSV column detection + config writing. `writeConfig` (full regenerate) is used only for the initial onboarding scaffold; **re-scaffold uses the non-destructive `mergeColumns(existing:detected:csvHeaders:)`** — fills empty mappings, repairs mappings whose CSV column was renamed, keeps valid existing mappings, flags stale-unresolved ones (`ColumnMergeReport`). Per profile, via `ConfigService.save`, so agents/EAs/thresholds survive. |
| `TrendStore` | Loads `summary.json` snapshots from `snapshots/computers/summaries/`; feeds the Trends screen charts. |
| `DeviceInventoryService` | Reads cached device inventory JSON from the workspace. |
| `ReportLibrary` | Lists generated reports in `Generated Reports/`. |
| `RunHistoryService` | Reads run logs from `automation/logs/`. |
| `SnapshotArchiveService` | Manages dated CSV snapshot archives. |
| `SystemActions` | `NSWorkspace` file open/reveal, strictly bounded to allowed paths. A refused reveal/open (path outside the allow-list, or a non-web link) posts `.systemActionDenied` with a user-facing `userInfo["message"]`; `ContentView` observes it once and shows a toast, so a blocked action is never silently swallowed. |
| `YAMLCodec` | Minimal YAML reader/writer for `config.yaml` fields the GUI exposes. |
| `JamfCLIInstaller` | Auto-update check and installation via Homebrew. |
| `SecurityScoreCalculator` | v3.5-parity weighted Security Score (FV 15 + SIP 15 + Firewall 15 + CrowdStrike 10 + mSCP 20 + XProtect 5 + CVE 15 + Secure Boot 5). Drops missing metrics from the denominator and renormalizes so tenants without specific agent stacks still get a comparable score. Weights configurable via ConfigView → Scoring tab (backed by `@AppStorage("securityScoreWeights")` and `ScoringConfig`). |
| `RiskScoringService` | v3.5-parity 14-factor per-device risk scorer. Bands: Critical ≥20, High ≥15, Medium ≥10, Low >0, Clean = 0. Triggered factors carry remediation strings rendered in the DevicesView detail panel. |
| `ComplianceBandingService` | Buckets per-device failure counts into Pass / Low (1–10) / Med-Low (11–30) / Medium (31–50) / High (>50) / No Data. Reuses `ComplianceBand` from Models.swift. |
| `SecurityPostureService` | Reads `pro security report` snapshots into a single Snapshot the SecurityPostureView renders. |
| `CompliancePostureService` | Same data source as SecurityPostureService but derives per-device control-gap counts (0–4) for the compliance band donut. Honest "proxy for true mSCP failure count — configure an EA for full banding" callout in the view. |
| `PatchStatusService` | Reads `patch-status/` + `patch-device-failures/` snapshots; aggregates fleet compliance and groups failures by title for PatchView. `complianceCSV` renders a standalone Patch Compliance CSV matching the workbook sheet (formula-injection-neutralized). |
| `UpdateStatusService` | Reads `update-status/` snapshots (both summary-only and `--scan-failures` shapes). Provides plan-state donut data, error device list, failed plans list for UpdatesView. |
| `PolicyHealthService` | Reads `policy-status/` + `profile-status/`; surfaces config findings grouped by severity and profile assignment failures for PolicyProfileView. |
| `ExtensionAttributeService` | Reads `ea-results/` + `computer-extension-attributes/`; computes per-EA devices-reporting counts and top-10 value distributions (EA data is custom and often legitimately sparse — the UI shows neutral counts, never a coverage %). Returns `.empty` Snapshot for empty content, nil only when no input URLs given. |
| `StaleDeviceService` | Buckets DeviceInventoryService records into Recent (0–30d) / Offline (31–90d) / Inactive (91–180d) / Dormant (180d+) for OutreachView. |
| `ProtectDashboardService` | Reads `protect-overview/` + `protect-alerts/` + `protect-computers/` + `protect-insights/` + `protect-plans/`. `isDetected` flag is true when at least one file decoded successfully (even to an empty array) — distinguishes "tenant doesn't run Protect" from "tenant runs Protect, just no current data". Plans (`ProtectPlanRow`) decode from either a bare array or a `{nodes:[]}` GraphQL envelope and surface in the ProtectView "Plans" card. |
| `CLIDoctorService` | Runs `jamf-cli doctor --output json` for the active profile (v1.18+) and decodes `CLIDoctorReport` (resolved profile, credential-resolution state, HEAD connectivity probe). Derives a health verdict (healthy / credentials-unresolved / unauthorized / unreachable / no-profile). Mirrors `CapabilityService` (`@MainActor @Observable`, injected `CLIExecutor`, pure `nonisolated static parse`). Powers the SourcesView "Connection health" card. Distinct from `ConfigDoctorService`/`DoctorReport`, which diagnose `config.yaml`. |
| `MobileFleetService` | Reads `mobile-devices-list/` (light) + `mobile-device-inventory-details/` (rich) + `classic-ios-profiles/`. Surfaces iOS/iPadOS KPIs, OS distribution, compliance signals. |
| `LegacyHistoryImporter` | One-shot import from v3.5's `fleet_health_metrics_history.json` into the workspace's summaries dir. Translates snake_case + yyyyMMdd → camelCase + yyyy-MM-dd; idempotent unless overwriteExisting=true. Triggered from SettingsView. |
| `DiagnosticBundleService` | Native port of Python `cmd_diagnostic_bundle`. Stages recent logs, last-N summaries, redacted config, a workspace tree, and version metadata into a zip under `~/Jamf-Reports/<profile>/diagnostics/` (an allow-listed dir, so `SystemActions.reveal` accepts it). Never executes the bundled script. `DiagnosticRedactor` reproduces the Python redaction behavior: always-on credential patterns, exact-key JSON redaction, and HMAC-SHA256 `<kind>-<8hex>` PII placeholders (per-instance random salt — stable within one bundle only, by design). Also stages a redacted `doctor.json` (`collectDoctor` runs `jamf-cli doctor` for the workspace profile; pure `stageDoctorJSON` parses + redacts — the server hostname is the only PII, stripped via `redactJSON`; best-effort, skipped if the binary/profile is absent or the run fails). Powers SettingsView's "Generate diagnostic bundle now". |
| `ScheduledRunRecorder` | (v2.2.0) Writes the per-run artifacts the Run History screen and Schedules "Last Run" column read: `automation/logs/<label>.<timestamp>.log` + `automation/<label>_status.json`. Used by the headless `--scheduled-run` path, which both launchd and the GUI "Run now" button invoke. Prunes its own logs at 50 per workspace; never touches legacy `.out.log`/`.err.log` files. |
| `ExportNaming` | (v2.2.0) Single filename convention for exports and engine reports: `<kind>-<profile>-<yyyy-MM-dd_HHmmss>.<ext>`. Used by every CSV/PNG export site and `ReportEngine.resolveOutputURL` (reports become `report_<profile>_<timestamp>.xlsx`). |
| `BackupMaintenance` | (v2.2.0) Housekeeping for `backups/`: keeps the newest 10 scheduled backups (manual backups never pruned — identified by the `scheduled-` manifest label prefix) and sweeps abandoned `.tmp-*` staging dirs older than 24h. |
| `SnapshotFreshness` | Decides fresh / stale / no-snapshots for a data dir by newest-file mtime. Gates the Overview "skip collect when fresh" path and the launch freshness sweep. |
| `RefreshDebouncer` | Debounce helper extracted from the refresh path for testability. |
| `CSVFamilyDetector` | Detects whether a Jamf Pro CSV export contains computers or mobile devices via family-unique discriminator headers (`COMPUTER_CSV_DISCRIMINATORS` / `MOBILE_CSV_DISCRIMINATORS`). Used by ScaffoldService and the CSV sheet routing. |
| `SOFAFeedService` | Reads/writes the shared `jamf-cli-data/sofa/` cache (URLSession fetch, atomic writes). Feeds the OS Currency sheet/section, UpdatesView latest-version card, and ReportEngine.collect (refresh tier; kinds `sofa` + `patch-release-dates` in knownCollectKinds). |
| `PatchReleaseDateService` | Reads the merged `patch-release-dates` snapshot (`[{title_id, title, latest_version, release_date}]`, written by the engine's collect). Latest-definition matching: exact version → absoluteOrderId 0 → first. Feeds Patch Compliance sheet + PatchView Released/Days Behind columns. |
| `MSCPComplianceService` | (v2.2.0; rule-count bound + `crossCheck` added 2.5.0) Derives real per-device mSCP/STIG compliance band distributions from `ea-results` snapshots. Reads per-baseline failure counts, buckets devices into Pass/Low/Med-Low/Medium/High/No Data bands, and computes pass percentage. A failure count above the baseline's configured `rule_count` is treated as invalid data (No Data), not a real High band. `crossCheck` cross-references the failure-count column against a configured failures-list column and flags devices where the two disagree, feeding the Config Doctor's "Data accuracy" family. Replaces the four-control proxy when configured via `compliance.baselines`. Used by CompliancePostureView donut and MSCPChartDataBuilder for trend charting. |
| `MSCPChartDataBuilder` | (v2.2.0; per-baseline series added 2.5.0) Builds historical mSCP/STIG compliance band time-series — one independent series PER baseline, never summed across frameworks — by merging dated `ea-results` snapshots and `summary.json` daily mscpBands. Matches a summary to a baseline by exact name first, then by stable EA-column identity (so renaming a baseline's display name doesn't fork its history), then a single-baseline lone-key coalesce. Feeds TrendsView's compliance band stackplot AND the baseline picker (shown only when more than one baseline is configured). Removing a baseline from `compliance.baselines` stops it being charted going forward — the underlying `ea-results`/`summary.json` data on disk is untouched. |
| `CollectRouter` | (v2.2.0) Dispatches a collect run to the right engine function(s) by profile **product type** (`ProfileProductType.detect` from config): Jamf School → `ReportEngine.schoolCollect`; Jamf Pro → `ReportEngine.collect`, then `protectCollect` if `protect.enabled` (Protect augments Pro; its failure is non-fatal). Closures default to the real statics; tests inject spies. The scheduled-run path and catch-up-on-wake both route through it. |
| `ManagedAutomation` | (v2.2.0) Owns the global "managed" all-profiles LaunchAgents derived from `AutomationPolicy`. `reconcile` is declarative and scoped to a **reserved EXACT label set** (`managed-freshness`/`-scan`/`-reports`/`-backup` → `<prefix>.multi.managed-*`); `owns(_:)` is exact membership, NEVER a prefix match, so a user's hand-built multi-schedule can't be removed. Pure `desiredSchedules`/`plan`/`owns` are unit-tested; the thin `reconcile` executes through injectable install/remove closures (no real `launchctl` in tests). Idempotent (signature-skips unchanged), force-reinstalls, and tears agents down when `isManaged` flips off. Called from `WorkspaceStore.reconcileManagedAutomation` on app launch (no-op in demo / when unmanaged). |
| `WebhookNotifier` | (v2.2.0) Opt-in scheduled-run webhook digest. Pure Teams adaptive-card and Slack Block Kit payload builders + a thin best-effort `URLSession` send that never throws into the run; gated on `NotifyConfig.isUsable` (enabled + https URL). Posts after a successful snapshot-only collect and after a successful generate in the scheduled-run path. |
| `FleetRollup` | (v2.2.0) Pure aggregator of a report group's per-profile `DailySummary` KPIs into consolidated metrics with period-over-period deltas. Percentages are **device-weighted** (Σ(pct × devices) / Σ(devices)); counts are summed. The caller passes one latest summary per profile plus the matching prior-period summary. |
| `FleetReportEmitter` | (v2.2.0) Emits a `ReportGroup`'s consolidated report as a `Metric,Current,Previous,Delta` CSV (formula-injection-safe by construction; group name only in the filename) under `_fleet-reports/` in the workspaces root. `priorSummary` selects the delta baseline by lookback (daily 1d / weekly 7d / monthly 30d). `main.swift`'s all-profiles **reports** run emits one CSV per group after the per-profile loop (and a rich workbook via `FleetWorkbookEmitter`). |
| `FleetWorkbookModel` | (2.4.0) Pure aggregator behind the consolidated fleet **workbook**: builds the universal aggregate (via `FleetRollup`, compliance excluded), per-profile rows, baseline-grouped mSCP bands (summed only within a shared baseline — never across frameworks), and a date-aligned trend. Universal KPIs are device-weighted; nil metrics render "—". |
| `FleetWorkbookEmitter` | (2.4.0) Renders a `FleetWorkbookModel` into a 5-sheet `.xlsx` (Fleet Summary / Per-Profile Breakdown / Security Posture / Compliance / Fleet Trend) with embedded `ChartRenderer` PNGs via `OOXMLWriter`, written beside the CSV under `_fleet-reports/`. Pure `workbook(for:)` + thin `emit` IO, mirroring `FleetReportEmitter`; percentages render as `"%.1f%%"` strings (the `CoreDashboard` convention). |
| `CLIInstaller` | (2.4.0) Symlinks the in-bundle executable to `/usr/local/bin/jamf-reports` so the GUI binary doubles as the included CLI (the `code`/`subl` pattern). No privilege escalation: writes the symlink only when the target dir is app-writable, otherwise returns the exact `sudo mkdir -p && ln -sf` command. Inspects the destination first — replaces a stale symlink, never clobbers a real file. `source`/`targetDir`/`fileManager` are injectable for tests. Powers SettingsView's "Install command-line tool". Distinct from `JamfCLIInstaller` (which installs the `jamf-cli` dependency). |
| `DebugLoggingService` | (2.4.0) Reads/writes the per-user OSLog Subsystems config plist (`~/Library/Preferences/Logging/Subsystems/<subsystem>.plist`, no privilege escalation). Two independent flags — `persistVerbose` (persist debug/info locally; PII stays `<private>`) and `revealPrivate` (`Enable-Private-Data`; default off, warned). Changes apply on next launch (OSLog reads the config at process start). `bundledProfileURL` locates the MDM `JamfReports-Debug-Logging.mobileconfig` (persist-verbose only). Powers SettingsView's Logging panel. |
| `LogBuffer` | (2.4.0, reworked 2.5.0) In-memory ring buffer (cap 2000, oldest dropped) of this session's diagnostic events. Fed two ways: `AppLogger.event` tees every logged event into it, and `CLIBridge.bufferingOnLine` mirrors the live collect stream from `WorkspaceStore+Refresh`'s GUI-triggered collects (first-collect, heavy-tier refresh, tier refresh). Replaced `LogStoreReader`/`OSLogStore`, which threw a generic "error 0" in signed Hardened-Runtime builds. Powers `LogViewerView`; entries are `LogRedactor`-scrubbed at display/export time, not at capture time. |
| `EAParseHealthService` | (2.5.0) Pure data-accuracy diagnostics for custom EA columns: `assess`/`assessIntCount` grade a column's parse health against the report engine's real type semantics (stricter for percentage/version) and return PII-safe value skeletons (letters→x, digits→9, capped) for the top unparseable values; `coverageDrift` computes per-EA device-coverage change between the two newest decodable `ea-results` snapshot days (files whose decode was salvaged from a truncated snapshot are skipped — a truncated day fabricates drift). Backs the Config Doctor's "Data accuracy" family and the EA-view coverage-drift callout. |
| `MetricAlertEvaluator` | (2.6) Pure evaluator behind the opt-in `alerts:` config block (`AlertsConfig`/`AlertRule` in ConfigDecoder): rules name a `DailySummary` metric key (`filevault_pct`, `patch_pct`, `stale_count`, …), an operator (`below` / `above` / `drops_more_than`), a threshold, and an optional `lookback_days` (default 7, drops rules only). `evaluate(rules:current:prior:)` returns `MetricAlertHit`s; a nil metric never fires (absent data is the dead-man switch's job, not an alert). The scheduled-run path (`main.swift` `notifyMetricAlerts`) evaluates after any run that collected and posts one `WebhookNotifier.sendAlert` attention card via the existing `notify:` webhook only when at least one rule trips. |
| `AutomationHealth` | (2.6) Dead-man switch for scheduled runs (WorkspaceStore+Automation.swift). Pure `evaluate(inputs:now:)` turns per-agent `LaunchAgentService.ScheduleHealthInput` (expected fire from the new backward-looking `lastScheduledFireDate`, which steps the proven forward `nextDate` matcher across a capped 35-day window; last run from `<label>_status.json`) into `.overdue` / `.failing` issues with a 60-minute grace. `AutomationHealthModel.shared` (@MainActor @Observable) publishes issues computed after `reconcileManagedAutomation` at launch; OverviewView shows a summary banner ("Open Automation" action), AutomationView shows an Automation Health section, and one optional overdue webhook digest posts per day when `notify:` is usable. |
| `PatchVelocityBuilder` | (2.6) Pure adoption-velocity engine: reads every dated `patch-status` snapshot (one decode per file, one point per LOCAL calendar day — the day-bucket zone must match `dateFromSnapshotFilename`'s local-time parsing, manifest.json excluded), joins `PatchReleaseDateService` release dates (id-first, name fallback), and emits `TitleVelocity` per title: adoption series, `daysBehind`, and `daysTo50`/`daysTo90` — nil unless the threshold crossing was actually OBSERVED in the series (never estimated; a series that starts above threshold reports nil). Feeds the PatchView velocity card (5 slowest titles + adoption chart) and the "Patch Velocity" xlsx sheet. Per-OS-version adoption HISTORY is the deferred 2.7 half. |
| `SnapshotManifest` (writer) | (2.6) `record(snapshotFile:data:)` writes/updates the per-kind `manifest.json` (schema v2, SHA-256, atomic staged write; a corrupt existing manifest is replaced, never thrown). Called from `ReportEngine.saveSnapshot` when `jamf_cli.require_manifest` is true, so `verify`'s `.mismatch` state is reachable for app-collected snapshots (previously only the retired Python collector wrote manifests). A manifest-write failure logs and never fails collect. SOFA / patch-release-dates / `.last` state files write through other paths and are not yet stamped (follow-up). |

**Intelligence layer (2.5.0 — opt-in, macOS 27+, off by default).** `AIConfig` decodes the `ai:` config.yaml block on every toolchain/OS (parsing is independent of FoundationModels availability); `enabled` gates all model use, `tier` selects `on_device` / `pcc` / `external` (external is reserved — specced, not built), and `lock_on_device` is a high-security override: `GeneratorKind.select(config:)` is a pure, ungated function that resolves a locked config to `.onDevice` unconditionally regardless of `tier` — provable without importing FoundationModels. `AIConfigLoader`/`AIConfigWriter` read/write the `ai:` block directly through `ConfigLoader`/`YAMLCodec`, deliberately NOT through `ConfigService`'s managed-key editor contract (that surface owns a fixed key list for the Config tab). Every real model call goes through a seam protocol (`FleetInsightGenerator`, `RunFailureExplaining`, `ReportNarrativeGenerating`) with an ungated `StubXxx` conformer (disabled/unavailable/pre-27 toolchain) and a `#if canImport(FoundationModels) && compiler(>=6.4)`-gated `FoundationModelsXxx` conformer (real model, macOS 27 only) — the gate compiles out entirely on the default toolchain. `ModelAvailability` collapses the compile-time gate, the `@available(macOS 27)` runtime check, and the concrete model's own availability into one renderable enum; `PCCEntitlement.isPresent` MUST be checked before constructing `PrivateCloudComputeLanguageModel` anywhere — the framework `fatalError`s on construction without the `private-cloud-compute` entitlement, which is uncatchable. `AIInsightCard` (Overview) renders the fleet-insight seam's output. The run-failure explainer (`RunFailureExplainer.swift`, RunsView "Explain this run") is on-device-ONLY regardless of configured tier — `RunFailureInput`'s initializer is private; the only constructor, `build(...)`, fully redacts (`LogRedactor` + `DiagnosticRedactor`) and tail-truncates a log excerpt before it can exist as a value, and `makeRunFailureExplainer` hands the generator a `lockedOnDeviceCopy` of the config. `ReportNarrative.makeForGUIGenerate` (`ReportNarrativeGenerator.swift`) writes an aggregates-only exec-summary paragraph, called ONLY from GUI generate flows (OverviewView/GenerateSheet `runGenerate`) — headless/CLI/scheduled paths never call it, so `aiNarrative` stays nil there; generation is raced against a 10-second timebox and the model's output is HTML-escaped before it lands in a report.

**Managed automation model (v2.2.0 — "set policy, not cron jobs").** `AutomationPolicy` (Models/AutomationPolicy.swift) is a single app-level `@AppStorage` JSON value (key `automationPolicy`, lenient `decodeIfPresent` so a new field never wipes a saved policy). `isManaged` is the master switch and **defaults off** — until the operator opts in via `AutomationView` (Phase 5) or the deferred Phase 6 migration, `ManagedAutomation.reconcile` installs and removes nothing. The managed agents are `--all-profiles` plists that resolve the profile set at run time, so adding/removing a profile auto-adjusts with no agent rewrite; `excludedProfiles` is enforced as a run-time exclusion (discover all, minus excluded — never a positive `--multi-profiles` list). `report_groups` (a `[ReportGroup]` on `AutomationPolicy`, NOT in config.yaml) drives the consolidated fleet report. The opt-in webhook digest lives in config.yaml's `notify:` block (`NotifyConfig`). Catch-up-on-wake (`WorkspaceStore.catchUpCollectIfNeeded`, launch + `willBecomeActive`) collects the day's freshness snapshot if a scheduled run was missed, gated by the Phase-1 once-per-day `force:false` collect guard.

**Tab visibility model.** Every non-core sidebar tab is toggleable via SettingsView → Sidebar Visibility. Backed by `@AppStorage("hiddenTabs")` parsed/serialized through `TabVisibility`. Core tabs (`Tab.isCoreTab` — Overview, Devices, Sources, Settings, Onboarding) are filtered out at the toggle UI level and protected at the model level (toggling a core tab is a no-op). Sidebar groups with all-hidden contents auto-collapse so the layout never shows orphan headers. Visibility is a per-user UX preference, not workspace-bound.

**Report templates.** `Engine/Templates/` defines the `ReportTemplate` protocol plus the shipping templates (Full Instance Report, Executive, Operational, Compliance, Asset, Security Posture, School, Custom), resolved by `TemplateResolver`. Each template lists its `includedSheets` (`SheetID` raw values must match `CoreDashboard.sheetPlan` names exactly) and `htmlSections` (`SectionID` → `HtmlReport.buildSectionMap`). **`FullInstanceTemplate` (`full-instance`) is the default** for both GUI generation (GenerateSheet) and engine-level `generateAll`/`generate` calls; it includes every sheet and section. `CustomTemplate` (`custom`) lets users select any subset of sheets for single-sheet or focused reports, with the selected sheet list persisted in AppStorage. Adding a new sheet/section: add the enum case, register the builder, and add it to FullInstanceTemplate (a test asserts FullInstanceTemplate covers all SectionID cases).

**Snapshot key contract (Swift HTML report).** `HtmlReport` loads cached snapshots by the canonical on-disk names that `ReportEngine.collect` writes — `computers`, `policies`, `smart-computer-groups`, `patch-device-failures` — with the older alternate names kept as fallback aliases in `loadJSONList(kinds:)` calls. When adding a section that reads a new kind, the kind must also be added to the collect command matrix and `knownCollectKinds` in `ReportEngine.swift` (and `CollectionTier` if it should participate in tiered collection); otherwise the section will silently render its empty-state placeholder forever.

**Compliance benchmark label.** UI surfaces never hardcode a benchmark name. `TrendSeries.Metric.compliance`'s default label is "Compliance Benchmark"; `WorkspaceStore.complianceBenchmarkLabel` overrides it from `compliance.baseline_label` or the first `platform.compliance_benchmarks` entry in the workspace config. mSCP baseline identifiers and the framework preset pickers keep real benchmark names — those are data/user choices, not labels the app asserts.

**EDR agent label (v2.2.0).** Same rule for security-agent vendor names. `TrendSeries.Metric.edrAgent` / `SecurityScore.Metric.edrAgent` default to "EDR Agent Installed/Connected"; `WorkspaceStore.edrAgentName` overrides from the first `security_agents` entry. Both enums keep the legacy `"crowdstrike"` raw value for persisted-selection and summary.json schema compatibility — do not rename the raw value or the `crowdstrikePct` JSON field.

**Logging & observability (2.4.0, log viewer reworked 2.5.0).** `AppLogger` emits through eight OSLog categories under subsystem `com.github.tonyyo11.jamf-reports-community` — `cli`, `collect`, `report`, `auth`, `schedule`, `webhook`, `platform`, `ui` (each filterable in Console.app and, for this session's events, the in-app viewer). The level convention lives in `AppLogger.swift`'s header (`.error` actionable · `.warning` degraded-but-continuing · `.notice` significant · `.info` milestone · `.debug` verbose trace); debug/info persist only when verbose logging is on. Settings → Diagnostics → **Logging** exposes the two `DebugLoggingService` toggles, an embedded `LogViewerView` (snapshot+refresh over the in-app `LogBuffer`, not the macOS log store — reading `OSLogStore` failed with a generic error in signed builds; redacted export via `LogRedactor`), a "Reveal MDM profile" affordance for the bundled `.mobileconfig`, and copy-paste `log stream`/Console instructions for anything outside this session's buffer. Operation failures route through `CLIBridge.explainOperationError` → `explainExit` (cause + remediation) instead of a raw `localizedDescription`. `Theme/ErrorStateView` (sibling of `EmptyStateView`, with a Retry action) surfaces **true** dashboard read-failures only where a service distinguishes a corrupt/unreadable snapshot from "no data yet" (`SecurityPostureService`/`CompliancePostureService` `Snapshot.loadError`; DevicesView's warnings-with-empty-devices) — legitimate empty states keep `EmptyStateView` (no mislabeling).

**Convention:** New jamf-cli command wrappers go through the `CLICommand` enum and `CLIExecutor` protocol (`Services/CLICommand.swift`), not bespoke `CLIBridge` methods. Existing helpers (`generate`, `collect`, `audit`, `deviceDetail`, …) stay as-is per `.claude/plans/ADR-W21-clicommand-enum.md` (Hybrid scope).

#### Schedule mode contract (PR-20 / PR-21; backup added in v2.2.0)

`Schedule.RunMode` has five cases; each is strict and operationally distinct.
Both the GUI "Run now" path (`CLIBridge.runNow(profile:mode:)`) and the
LaunchAgent path (`main.swift --scheduled-run --mode <rawValue>`) honor the
same contract — they share `CLIBridge.newestCSV(in:)` so CSV lookup is
identical between the two.

| Mode (`Schedule.RunMode`)         | Behavior                                                                    | Trends updated? |
|------------------------------------|-----------------------------------------------------------------------------|------------------|
| `.snapshotOnly` (`snapshot-only`)  | `ReportEngine.collect` only — emits `summary.json`; no workbook            | Yes              |
| `.jamfCLIOnly` (`jamf-cli-only`)   | `ReportEngine.generate` only — uses cached snapshots; NO collect            | No (no collect)  |
| `.jamfCLIFull` (`jamf-cli-full`)   | collect + generate; no CSV                                                  | Yes              |
| `.csvAssisted` (`csv-assisted`)    | collect + generate; **requires** a CSV in `csv-inbox/` — hard-fails if none | Yes              |
| `.backup` (`backup`)               | `jamf-cli pro backup` only — config objects to `backups/`; no collect, no report | No          |

LaunchAgent plists written before PR-20 omit `--mode`; both the parser
(`LaunchAgentService.parse` line 185) and `main.swift` (`scheduledRun`
parser) default to `.jamfCLIOnly` so existing plists keep working
verbatim — but the meaning of `.jamfCLIOnly` changed at PR-21, so a
pre-PR-20 plist that previously collected before generating now only
generates from cache. Re-save the schedule from the GUI to migrate.

`ReportEngine.collect` (static) now emits `summary.json` at the end of the
collection loop in addition to `ReportEngine.generate` — that's how
`.snapshotOnly` updates Trends without producing a workbook. The
first-run-of-day skip from PR-18 (ReportEngine.swift:287-299) still
applies: if `summary_<today>.json` already exists with the three required
keys, it's left in place and subsequent collects log
`[info] summary_<today>.json already exists`.

#### jamf-cli exit codes

Named constants in `CLIBridge`. Reference: jamf-cli Error Handling & Exit Codes spec.

| Code | Constant | Meaning | App behavior |
|------|----------|---------|--------------|
| 0 | — | Success | Continue normally |
| 1 | — | General error (network failure, unexpected) | Warn; use cached data |
| 2 | `exitCodeUsage` | Bad flags / missing args | Indicates a caller bug — log as error |
| 3 | `exitCodeUnauthorized` | HTTP 401 — invalid or expired credentials | Hard fail; `authGuard` blocks live calls |
| 4 | `exitCodeNotFound` | HTTP 404 — resource does not exist | Warn; use cached data |
| 5 | `exitCodePermissionDenied` | HTTP 403 — account lacks required API privileges | Warn with specific message; use cached data |
| 6 | `exitCodeRateLimited` | HTTP 429 — server throttling | Warn with specific message; use cached data |
| 7 | `exitCodePartialFailure` | Partial failure (v1.19.0+) — some sub-operations failed, stdout contains valid JSON for the successful subset | Warn; save the returned partial data |

The `authGuard` function probes `pro auth token` before any live API command. It skips the probe for Jamf School profiles (`shouldSkipAuthProbe`) because School uses API key auth rather than OAuth2. `exitCodeUnauthorized` (3) is the only code that causes a hard abort — all others warn and fall back to cached data. Exit code 7 counts as a success for the auth-dead verdict (auth was accepted; only some sub-operations failed).

#### Key views (41 Swift view files as of v2.2.0; tables last synced at v2.0 — see Views/ and Services/ for the current set)

Core: `Sidebar`, `Titlebar`, `OverviewView`, `FleetOverviewView`, `DevicesView`,
`DeviceLookupView`, `TrendsView`, `ReportsView`, `BackupsView`, `AutomationView`,
`RunsView`, `ConfigView`, `CustomizeView`, `SourcesView`, `AuditView`,
`OnboardingView`, `SettingsView`

`AutomationView` (v2.2.0, DRAFT pending visual sign-off) is the "set policy"
screen bound to `AutomationPolicy`; the `Tab.schedules` case now routes to it
(label "Automation"). `SchedulesView` remains compiled but **unrouted** pending
the deferred Phase 6 migration that consolidates existing hand-built schedules.

Posture group: `SecurityPostureView` (weighted score ring + per-control KPIs +
P0/P1/P2 action items + OS donut), `CompliancePostureView` (compliance band
donut + control-gap bars + per-OS breakdown), `OutreachView` (stale tier cards
+ devices table + clipboard mail-merge).

Operations group: `PatchView` (titles table with CSV + PNG export, per-title failure drawer),
`UpdatesView` (plan state donut + failed-plans table + error-devices table),
`PolicyProfileView` (two-tab segment: Policies findings + Profiles status),
`ExtensionAttributesView` (coverage grid + value-distribution chart).

Fleet group: `MobileFleetView` (iPad/iPhone breakdown + iOS version
distribution + devices table), `ProtectView` (alerts/computers/insights or
explicit "Protect not detected" empty state).

Utilities: `AppToolbar`, `WhatsNewBanner`, `DashboardChartExport`,
`GenerateSheet`, `SecureSecretField`, `WorkspaceView`, `HealthCheckView`.

DevicesView gains a `.priorityAction` filter + per-device "Priority Risk"
section in the detail panel — driven by `RiskScoringService`.

TrendsView's metric picker auto-includes `.securityScore` once any summary
file (legacy import or live run) populates that field.

#### Security model

- **Path allow-list:** `SystemActions` file open/reveal is bounded to `~/Jamf-Reports`,
  `~/Library/LaunchAgents`, and standard user folders. Paths are canonicalized with a
  trailing-`/` prefix check to prevent symlink traversal.
- **Profile-name regex:** `ProfileService.isValid` (`^[a-z0-9][a-z0-9._-]*$`) is enforced
  at every path-construction site.
- **No persisted credentials in app:** During onboarding the secret is passed to `jamf-cli`
  via `stdin`, redacted from failure output, and cleared immediately. Persistent secrets live
  in the system keychain through `jamf-cli`.
- **UserAgents-only:** The app only manages `~/Library/LaunchAgents`. It never requests
  `sudo` or installs system-wide LaunchDaemons.
- **Atomic writes:** Configuration and plist updates use `replaceItem(at:withItemAt:)` to
  prevent corruption on power loss or crash.
- **Hardened Runtime + entitlements:** The release bundle is built with Hardened Runtime
  enabled. Entitlements are in `app/JamfReports.entitlements`.

#### Included CLI (2.4.0)

The same binary is both the GUI and a `jamf-reports` command-line tool.
`App/main.swift` dispatches on the arguments: `--scheduled-run` keeps its
dedicated headless path (LaunchAgent back-compat); a recognized subcommand
(`JamfReportsCLI.isKnownSubcommand(argv[1])`) routes to the CLI; anything else
(including double-click launch) opens the GUI.

The CLI lives in `Sources/JamfReports/CLI/` and uses `swift-argument-parser`
(the second and only other dependency, after ZIPFoundation). `JamfReportsCLI`
is the `AsyncParsableCommand` root; each of the 11 subcommands is a thin shell
over an already-tested engine entry point — `generate`/`html`
(`ReportEngine.generate`/`generateHTML`), `collect` (`ReportEngine.collect`),
`backup`/`device` (`CLIBridge`, MainActor hop), `scaffold` (`ScaffoldService`),
`check`/`school-check`/`school-scaffold` (the `runCheck`/`runSchoolCheck`/
`runSchoolScaffold` helpers in `main.swift`), `capabilities` (`CapabilityService`
+ `DefaultCLIExecutor`), and `diagnostic-bundle` (`DiagnosticBundleService`).
`CLIRun` holds the shared helpers (`loadProfile`, `resolveTemplate`, tier
parsing, log-line stream routing).

**xlsx + HTML only — no PDF.** PDF generation uses `WKWebView`, which needs an
AppKit run loop a headless CLI lacks; it stays a GUI feature.

**Dispatch gotcha — do not "simplify" it.** CLI dispatch goes through the
`@available(macOS 14, *) runIncludedCLI()` helper, NOT a bare
`JamfReportsCLI.main()` at top level. ArgumentParser's async `main`/`run`
overloads are `@available(macOS 10.15, *)`-gated; in unannotated top-level code
overload resolution binds to the synchronous overloads, which refuse to run an
async root (they print help and exit 0). The `@available` wrapper supplies the
context that makes the async overloads win. `JamfReportsCLI` carries the same
annotation.

**School commands ship untested** — `school-check`/`school-scaffold` are
first-class but unvalidated (no Jamf School tenant); they invite community
feedback. Install the `jamf-reports` symlink via `CLIInstaller` (Settings →
"Command-line tool"). User guide: `docs/wiki/07-Command-Line.md`.

#### Building the app

```bash
cd app
swift build                        # validate compilation
swift run JamfReports              # launch (debug)

# Produce a runnable .app bundle (ad-hoc signed, local dev use)
./build-app.sh release             # → app/build/JamfReports.app

# A public release (vs a beta): set RELEASE=1
RELEASE=1 ./build-app.sh release   # stamps JRReleaseChannel=release
```

For distribution to other Macs: sign with a Developer ID certificate, notarize via
`xcrun notarytool`, and staple with `xcrun stapler staple`. These steps are currently
manual and not integrated into `build-app.sh`.

**Version model.** `MARKETING_VERSION` in `build-app.sh` is the single source of
truth for the user-facing semver (`CFBundleShortVersionString`); keep it in sync with
`AppVersionState.fallbackVersion` (`AppVersionDriftTests` enforces this). `CFBundleVersion`
is always a monotonic integer (git commit count) — never set it to the marketing version.
Release-vs-beta is signalled by `RELEASE=1` → `JRReleaseChannel` in `Info.plist`, which
`build-pkg.sh` reads to decide artifact naming (`-betaN` suffix for betas).
To bump: change `MARKETING_VERSION`, roll `CHANGELOG.md`, tag `vX.Y.Z`; the build number
takes care of itself. `.jamf-cli-tracked-version` is a separate axis (the jamf-cli
dependency floor), unrelated to app versioning.

#### Swift code conventions

- Swift 6 strict concurrency (`@MainActor`, `Sendable`, `async/await` throughout).
- `@Observable` for state; no `ObservableObject` / `@Published`.
- All user-visible strings in English; no `NSLocalizedString` wrapping required for now.
- No `UIKit` — SwiftUI only.
- All new services must validate paths through `ProfileService.workspaceURL(for:)` before
  constructing any file paths.
- **Never bind `$array[index]` inside `ForEach(array.indices, id: \.self)`** for an
  editable/removable list — the disappearing row's binding is re-read with a stale index
  during SwiftUI's removal diff and traps ("Array index out of range"). Use
  `safeElementBinding(_:_:default:)` (ConfigView) or a binding-to-element `ForEach($array)`.
- Test targets live in `app/Tests/JamfReportsTests/`.

---

## jamf-cli JSON Shapes (v1.18.0)

The Swift engine parses these exact shapes. Minimum supported jamf-cli is **v1.18.0**.
Older versions are not supported — older fallback branches were removed in W21 (patch-status
`installed/total` shape). The `update-status` older shape is preserved pending live
verification against a tenant with active update plans.

The floor was bumped to 1.16.1 (from 1.14.0) on 2026-05-08 to pick up the platform-section
nil-guard in `pro device <id>` (PR #185). v1.15 added URL normalization at all entry points,
which complements `WorkspaceStore.consoleURL`'s defensive scheme prepend. JamfCLIInstaller
surfaces a Settings notice when the detected jamf-cli is below this floor; the app does not
hard-fail — most code paths still work, the warning is to nudge updates.

**`pro report security --output json`**
```json
[
  {"section": "summary", "data": {"total_devices": N, "filevault_encrypted": N,
    "gatekeeper_enabled": N, "sip_enabled": N, "firewall_enabled": N}},
  {"section": "device", ...},
  {"section": "os_version", "os_version": "15.7.3", "count": N, "pct": "N%"}
]
```

**`pro report policy-status --output json`**
```json
[{"summary": {"total_policies": N, "enabled": N, "disabled": N,
              "config_findings": N, "warnings": N, "info": N},
  "config_findings": [{"severity": "...", "policy": "...", "policy_id": "...",
                       "check": "...", "detail": "..."}]}]
```

**`pro report patch-status --output json`**
```json
[{"title": "Firefox", "id": "123", "on_latest": 100, "on_other": 20,
  "total": 120, "latest": "130.0", "compliance_pct": "83%"}]
```

`on_latest` / `on_other` is the canonical shape on v1.14. The pre-v1.4
`installed`/`total` legacy shape is no longer supported.

**`pro report patch-status --scan-failures --output json`**
```json
[{"policy": "Firefox 130.0", "policy_id": "42", "device": "MacBook-001",
  "device_id": "123", "status_date": "2026-04-01", "attempt": 3,
  "last_action": "Retrying", "serial": "ABC123",
  "os_version": "15.7.3", "username": "jdoe"}]
```

One row per failing device × patch policy. `last_action` is fetched from
`/v2/patch-policies/{id}/logs/{deviceId}/details` (highest attempt, highest action order).
Used by `JamfCLIBridge.patch_device_failures()` → CoreDashboard "Patch Failures" sheet.

**`pro report update-status --output json`**
```json
[{"total": N,
  "status_summary": [{"status": "PENDING", "count": N}, ...],
  "plan_total": N,
  "plan_state_summary": [{"state": "Activated", "count": N}, ...]}]
```

`error_devices` and `failed_plans` only appear with `--scan-failures`.

**`pro report update-status --scan-failures --output json`**
```json
[{"total": N,
  "status_summary": [{"status": "...", "count": N}],
  "error_devices": [{"name": "...", "serial": "...", "device_type": "...",
                     "os_version": "...", "username": "...", "status": "...",
                     "product_key": "...", "updated": "..."}],
  "plan_total": N,
  "plan_state_summary": [{"state": "...", "count": N}],
  "failed_plans": [{"name": "...", "serial": "...", "device_type": "...",
                    "os_version": "...", "username": "...", "state": "...",
                    "action": "...", "version": "...", "error": "...",
                    "last_event": "..."}]}]
```

Used by `JamfCLIBridge.update_device_failures()` → CoreDashboard "Update Failures" sheet.
API-expensive: fetches full computer and mobile inventory plus per-plan events in parallel.
v1.7 server-side now drops devices Jamf considers stale before returning the failure list,
so totals match the live console rather than including never-checked-in records.

**`pro advanced-mobile-device-searches list --output json`** (v1.18)
```json
{"totalCount": N,
 "results": [{"id": "211", "name": "...",
              "criteria": [{"name": "...", "priority": 0, "andOr": "and",
                            "searchType": "...", "value": "...",
                            "openingParen": false, "closingParen": false}],
              "displayFields": ["..."], "siteId": "-1"}]}
```

A `{totalCount, results}` envelope (not a bare array). `id`/`siteId` are strings; `siteId`
`-1` means "All Sites". Used by `JamfCLIBridge.advanced_mobile_device_searches_list()` →
CoreDashboard "Advanced Mobile Searches" sheet.

**`pro classic-computer-groups list --output json`** / **`pro classic-mobile-device-groups list --output json`** (v1.18)
```json
[{"id": 1, "is_smart": true, "name": "..."}]
```

Classic API: a flat array with snake_case `is_smart` (absent → treated as static). Returns
BOTH smart and static groups — the static-group visibility the modern smart-groups API omits.
Used by `JamfCLIBridge.classic_computer_groups_list()` → CoreDashboard "Computer Group
Inventory" sheet and `JamfCLIBridge.classic_mobile_device_groups_list()` → "Mobile Device
Groups" sheet.

---

## Code Conventions

### Swift App

- Swift 6. All code compiles with strict concurrency enabled.
- Functions ≤100 lines. Cyclomatic complexity ≤8.
- 100-character line length.
- No force-unwrap (`!`) in production paths — use `guard let` / `if let`.
- Services must be `@MainActor` or explicitly `Sendable`.
- Test new services and business logic in `app/Tests/JamfReportsTests/`.

---

## Testing

### Swift App

Run the Swift test suite from the `app/` directory:

```bash
cd app
swift test
```

Tests live in `app/Tests/JamfReportsTests/`, with engine-layer suites under
its `Engine/` subdirectory — one suite per service or feature area.

All new services and business-logic functions should have corresponding test files.
Follow the same naming convention: `<ServiceName>Tests.swift`.

Verify the app compiles before committing any Swift change:

```bash
cd app && swift build 2>&1 | tail -20
```

**Pre-push CI parity (PR-9.5):** CI pins Xcode to `16.4` via
`maxim-lobanov/setup-xcode@v1` in `.github/workflows/ci.yml` — that
gives a bundled Swift 6.1.x. Local Swift 6.3+ (Xcode 17+) relaxes
`@MainActor` enforcement and will silently compile code that fails on
CI. Before pushing, run:

```bash
cd app && swift build --build-tests 2>&1 | grep "error:" || echo "OK"
```

To catch isolation errors locally, install Xcode 16.4 alongside your
current Xcode (Apple's older-releases page) and `sudo xcode-select -s
/Applications/Xcode_16.4.app` before running `swift build`. SwiftUI
`View`-conforming types are MainActor-isolated; their tests must use
class-level `@MainActor` (not just method-level) for Swift 6.1
compatibility.

### Dummy profile testing

The dummy profile (`jamf_cli.profile: "dummy"`) uses pre-saved JSON from
`jamf-cli-data/dummy/` for fully offline testing without a live Jamf Pro connection.
Set `profile: "dummy"` in `config.yaml` and point `data_dir` to a directory containing
the cached JSON files.

---

## Files

```
jamf-reports-community/
├── config.example.yaml         # Annotated example config — the canonical config schema
├── CHANGELOG.md                # User-visible changes between commits and releases
├── README.md                   # End-user setup and usage guide
├── CLAUDE.md                   # This file
├── AGENTS.md                   # Mirror of CLAUDE.md for OpenAI-compatible agents
├── BACKLOG.md                  # Index of deferred-findings epic issues (GitHub)
├── LICENSE                     # MIT — canonical; mirrored to app/Sources/JamfReports/Resources/
├── NOTICE.md                   # Trademark/affiliation notice — canonical; mirrored to Resources
├── THIRD_PARTY_NOTICES.md      # Third-party attribution — canonical; mirrored to Resources
├── docs/wiki/                  # GitHub Wiki source files
├── app/                        # Native macOS SwiftUI app
│   ├── Package.swift           # SwiftPM manifest (executable target, macOS 14+, Swift 6)
│   ├── JamfReports.entitlements
│   ├── build-app.sh            # Produces app/build/JamfReports.app with ad-hoc signing
│   ├── iconset/                # App icon source and build script
│   ├── Sources/JamfReports/
│   │   ├── App/                # @main entry point, ContentView, CLI/GUI dispatch
│   │   ├── CLI/                # Included jamf-reports CLI (root + subcommands)
│   │   ├── Models/             # Data models + DemoData
│   │   ├── Services/           # Business logic, CLIBridge, workspace management
│   │   ├── Theme/              # Design tokens, shared components
│   │   └── Views/              # SwiftUI screens + shared components
│   └── Tests/JamfReportsTests/ # Swift XCTest suite
└── .gitignore                  # Excludes config.yaml, Generated Reports/, jamf-cli-data/
```

`config.yaml` is gitignored. The app creates it during onboarding, or copy
`config.example.yaml`. Never commit a real `config.yaml` — it will contain column names
that reveal org-specific EA naming conventions.

`CHANGELOG.md` tracks user-visible changes. Update `Unreleased` whenever a change affects
end users, and roll those notes into a versioned section when cutting a release tag.

**Changelog and release-notes style:** plain-language summaries of what changed for the
user — a one-line framing paragraph, then grouped concise bullets (Added/Fixed/Security).
No SHAs, file paths, or class names unless the user needs them to act; technical detail
belongs in commit messages. GitHub release notes follow the same voice with themed
sections and a downloads table — always replace the auto-generated per-PR notes
(`gh release edit --notes-file`), and never @-mention the maintainer or contributors.
The v2.2.1 CHANGELOG section and release page are the reference examples
(style modeled on Macjutsu/super).

---

## What Not to Do

### Swift App

- Do not add Swift Package dependencies without a strong justification. Each dependency
  increases build time, maintenance surface, and binary size.
- Do not construct file paths by string interpolation — always use `ProfileService.workspaceURL(for:)`
  and `WorkspacePaths` typed constants.
- Do not add `UIKit` imports or `AppKit` patterns that bypass SwiftUI — use `NSViewRepresentable`
  only when SwiftUI has no equivalent.
- Do not add Xcode project files (`.xcodeproj`, `.xcworkspace`) — the project is SwiftPM-only.
  (Using Xcode as your IDE is fine and encouraged: it opens `app/Package.swift` natively, with
  SwiftUI previews, Instruments, and the Xcode agentic assistant. This rule bans the project
  *format*, not the editor.)
- Do not request `sudo` or install LaunchDaemons. The security model is user-agent-only.
