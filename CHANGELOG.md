# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

### Added

- macOS app **Fleet Overview** tab now aggregates initialized profile workspaces
  from historical summary JSON, showing per-profile device count, Stability
  Index, and last successful run without exposing local configuration paths.
- macOS app **Overview** and **Fleet Overview** surfaces now support drill-down:
  KPI cards, macOS distribution, failing rules, security-agent cards, recent
  activity, and fleet profile cards open detail pages with relevant metrics and
  actions to jump to related tabs.
- Added **Stability Index** trend metric as a management-level health score,
  weighted from compliance, patch posture, and inverse stale-device pressure.
- Added **Interactive Breadcrumbs** to all page headers; users can now click the
  parent view name (e.g., "OVERVIEW") to navigate back or switch tabs.
- Added **Keyboard Shortcuts** for core app actions: `Cmd + R` (Refresh),
  `Cmd + F` (Find/Search), and `Cmd + D` (Toggle Demo Mode).
- Added **Live Status Bar** to the app footer, providing real-time feedback and
  CLI output (e.g., "Collecting jamf-cli snapshots...") during long-running tasks.
- Added **Toast Notifications** for background task completion; a brief popup
  now confirms successful report generation or audit completion across all tabs.
- Added **Context Menus** (right-click) to device rows in Detailed Inventory and
  Overview tables with actions for "Open in Jamf Pro", "Copy Serial", and "Copy User".
- Added **Interactive Column Sorting** to inventory and audit tables.

### Changed

- Compliance failure-count parsing is now fail-closed: `strict_parse_failures()`
  raises `ValueError` on non-numeric values (empty, "N/A", "null", etc.) instead
  of silently treating them as 0. In the summary JSON path, unparseable values
  cause `compliancePct` to be omitted (GUI shows "no data") rather than exiting.
  CSV sheets log unparseable details and exclude those rows from compliance bands.

### Fixed

- `_emit_summary_json` now validates existing summary files before skipping:
  parses JSON and checks for required keys (`date`, `totalDevices`, `source`);
  regenerates instead of using corrupt data.
- Compliance parsing no longer crashes in summary path: removed `sys.exit(1)`
  when unparseable values are found; sets `comp_pct = None` and logs a warning.

### Added

- Tests for `max_cache_age_hours` enforcement in `test_bridge.py`:
  `test_max_cache_age_raises_when_cache_too_old`,
  `test_max_cache_age_skips_check_when_zero`,
  `test_max_cache_age_uses_cache_when_fresh`.
- Tests for `JamfCLIBridge.audit()` and `group_analyze()` methods:
  `test_audit_calls_correct_command`,
  `test_audit_with_category_adds_checks_flag`,
  `test_group_analyze_unused_mode_adds_flag`.

### Fixed
 
- Fixed chart layout overflow in the macOS app where charts could go "off the page"
  due to categorical string X-axis; now uses continuous `Date` scaling.
- Fixed timeline range filtering (W4–W52) to be duration-based rather than
  snapshot-count based, ensuring correct behavior when daily snapshots exist.
- Fixed chart scaling for sparse data: charts now anchor to the selected time
  domain (e.g., a full year for W52) rather than stretching few points to fill.
- Improved responsiveness of **Trends** view; comparison cards now stack
  vertically on narrow windows using `ViewThatFits`.
- Added **Data Staleness Indicators** to headers; timestamps now turn amber (>24h)
  or red (>7d) with a relative age label to warn when viewing old cached data.
- Improved search discoverability; `Cmd + F` now automatically focuses the search
  field in **Detailed Inventory** and **Health Audit** views.
- Health Audit now tracks drift between cached audit snapshots, badges findings
  that are new since the previous run, and shows recently resolved findings.
- Multi-profile automation now has a dedicated `multi-launchagent-run` command
  that fans out the existing LaunchAgent workflow across initialized profile
  workspaces, with aggregate status JSON and per-profile results.
- Fixed optional metrics (Stability, NIST Compliance) in the macOS app **Overview**
  rendering as 0.0% when no historical data exists; now shows "--" and "No Data".
- Manual multi-profile "Run now" actions in the macOS app now append their output
  to the standard schedule logs and record exit status correctly.
- Hardened device row identity to prevent collisions for records that capture
  a numeric Jamf ID but lack a serial number or name.
- Fixed sidebar trend badge to honor custom `charts.historical_csv_dir` paths
  instead of hardcoding the default snapshots directory.
- Manual multi-profile "Run now" now rejects legacy `jamf-cli multi`
  LaunchAgent plists that point at a fake executable with the same basename
  instead of the trusted `jamf-cli` discovered by the app.
- Multi-profile LaunchAgent schedules now read their aggregate status JSON and
  treat `[fail]`, `Error:`, and non-zero exit markers in logs as failed runs,
  so a failed profile fan-out no longer appears as OK in the schedule list.
- Trends now keep optional metric values paired with their original snapshot
  dates, preventing Compliance, CrowdStrike, and Stability data from drifting
  onto the wrong date when summaries mix CSV-only and jamf-cli-backed metrics.
- Active Devices demo trends now use the demo total-device series and clamp
  mismatched demo date/value arrays, preventing crashes when viewing that metric.
- "Open in Jamf Pro" context-menu actions now appear only when a device has a
  numeric Jamf computer ID populated from inventory or patch-failure data,
  avoiding invalid URLs built from serial/name-based local row IDs.
- Breadcrumb navigation actions now use main-actor closures, resolving Swift
  concurrency warnings from page-header navigation callbacks.
- macOS app Trends **Export PNG** now renders readable, self-contained chart
  images with a light background, title, date range, gridlines, axis labels,
  point markers, highlighted latest point, and summary stats instead of sparse
  dark images with little context.
- Active Devices PNG exports now use dynamic y-axis scaling so count metrics no
  longer flatten into a near-empty line against a hardcoded range.
- Multi-profile schedules now run the saved JRC LaunchAgent command instead of
  bypassing automation through `jamf-cli multi -- pro collect`, preserving the
  selected mode, base profile, target profile list/filter, sequential setting,
  logs, and status-file behavior.
- Health Audit, Group Hygiene, and Backups app views received focused usability
  refinements: compact KPI summaries, last-run timestamps, clearer affected
  counts, recommendation details, group-type/status pills, bulk ID/CSV helpers,
  improved backup labels, diff selection hints, and syntax-colored diff output.
- When `--csv` is explicitly provided but the file is unreadable, `generate`
  now exits with an error instead of silently producing a workbook with no
  CSV sheets.
- When the Compliance sheet is enabled in config but fails during generation,
  `generate` now exits with an error rather than silently skipping the sheet.
- The output workbook is now written to a `.partial` temp file and atomically
  renamed to the final path only after a successful `wb.close()`, preventing
  partially-written `.xlsx` files from being left on disk if the process is
  interrupted mid-write.
- Compliance failure counts of `""` or `"N/A"` no longer silently count as
  passing. Unparseable values are excluded from the compliant count in both
  the summary JSON and the Compliance sheet. The sheet now shows an
  "Unparseable (excluded)" row when any values could not be parsed, making
  the data quality issue visible.
- Merging multiple CSVs via `--csv` now deduplicates rows by serial number.
  If the same serial appeared in more than one input file, the first
  occurrence is kept and a warning is printed.
- Fleet Drift comparison now warns when a historical CSV snapshot contains
  duplicate serial numbers, rather than silently discarding them.
- Unexpected exceptions that escape a command (e.g. network errors, malformed
  JSON) now print a clean `Error: <type>: <message>` line to stderr and exit 1,
  instead of surfacing a raw Python traceback with local paths.
- **Build Fix**: Fixed a missing `return` statement in `SchedulesView.swift` that prevented the macOS app from building.
- **Swift Compiler**: Simplified `latestJson` closure in `AuditView.swift` to resolve a compiler ambiguity error.
- macOS app builds now fail fast when component or bundle signing fails instead
  of continuing with a partially signed app.
- Bundled Python runtime builds now require a pinned SHA256 before downloading,
  extracting, or copying a runtime asset.
- Swift jamf-cli install/update subprocesses now drain stdout and stderr while
  the process is running, avoiding hangs when a command emits enough output to
  fill a pipe buffer.
- Manual scheduled "Run now" execution now rejects tampered LaunchAgent plists
  whose Python executable, script path, config/status paths, log paths, or
  profile do not match the generated command contract.
- LaunchAgent environments are now rebuilt from a small trusted set instead of
  inheriting plist-controlled `PATH`, `JAMFCLI_PATH`, `PYTHONHOME`, or
  `PYTHONPATH` values.
- `launchagent-setup` now writes LaunchAgent plists atomically and restores the
  previous plist if `launchctl bootstrap` fails.
- `backup` now removes partial backup directories on subprocess, stats,
  manifest, or final rename failures and reports cleanup failures explicitly.
- `inventory-csv` now writes through a destination-local temp file before
  replacing the final CSV, preserving an existing export if the write fails.
- `generate` now emits trend summary JSON only after the workbook closes
  successfully, and `--force-summary` can explicitly replace an existing
  same-day summary.
- Cached Jamf managed-software-update endpoint errors are now normalized to the
  same no-data workbook rows as live `jamf-cli` failures, so cached reports no
  longer produce blank Update Status/Failures sheets when the tenant toggle is off.
- Reduced macOS app file-opening and onboarding exposure by removing the unused
  `/Applications` allow-list entry and redacting profile credentials from
  registration failure output before it is shown in the UI.
- Hardened generated HTML reports against branding-driven markup/style injection:
  page titles and topbar branding are escaped, accent colors are limited to hex
  values, inline logos must be small bitmap images, and SVG logos are rejected.
- Hardened macOS app multi-profile "Run now" execution so tampered LaunchAgent
  plists cannot redirect the aggregate status file or stdout/stderr logs outside
  the generated `~/Library/Logs/JamfReports/<label>/` directory, and the saved
  `multi-launchagent-run` arguments must match the generated command contract.
- macOS app report actions now choose a Python interpreter that can import the
  bundled report dependencies, and the workspace banner now distinguishes a
  missing `config.yaml` from a missing workspace directory.
- macOS app scheduled runs now show computed next-run times and last-run status
  from the generated LaunchAgent status/log files; manual "Run now" uses the
  schedule's `launchagent-run` command so it records run history consistently.
- Turning demo mode off now removes the synthetic `meridian-prod` local
  workspace and any generated demo LaunchAgents so the demo profile does not
  leak into live profile discovery.
- Hardened macOS app profile handling around connection validation, workspace
  initialization, LaunchAgent labels, and live-mode trends so invalid profile or
  schedule names are rejected consistently and live users are not shown synthetic
  compliance-band chart data.
- The macOS app now delegates scheduled-run LaunchAgent creation to Python's
  `launchagent-setup`, using the shared status-file, log, CSV inbox, and
  `com.github.tonyyo11.jamf-reports-community.*` plist format; old
   `com.tonyyo.jrc.*` app-generated plists are removed on launch.
 - Fixed `DeviceRecordMerger` not updating `jamfIDIndex` after merging records
   with a new `jamfID`, causing subsequent lookups by Jamf ID to miss updated records.
 - Fixed `TrendStore` timezone mismatch: `parsedDate` used UTC while
   `filterSummaries` used `Calendar.current`, causing date-range boundaries to
   shift during DST transitions. Both now use `Calendar(identifier: .iso8601)`.
 - Fixed `DailySummary` decoding to use explicit `init(from:)` with
   `decodeIfPresent` for optional keys (`compliancePct`, `crowdstrikePct`),
   preventing decode failures when Python omits CSV-only metrics.
 - Fixed `cmd_multi_launchagent_run` missing timeout: `ThreadPoolExecutor` now
   uses `wait(futures, timeout=3600)` so a hanging profile run cannot block
   the pool indefinitely; timed-out profiles are recorded as failed.

### Removed

- Removed unwired Swift prototype status/history/benchmark screens, their
  orphaned single-consumer services, unused demo fixtures, unused theme tokens,
  and unused private Python helpers.

## [1.3.0] - 2026-04-24

### Fixed

- `cmd_inventory_csv` now reads `jamf-cli pro computers list` responses correctly.
  Earlier versions read top-level keys (`name`, `serialNumber`, `operatingSystemVersion`,
  `location.username`) but `jamf-cli` returns nested objects (`general.name`,
  `hardware.serialNumber`, `operatingSystem.version`, `userAndLocation.username`) and,
  by default, only includes the General section. The result was inventory CSVs where
  every non-id/udid field was empty. The bridge now requests
  `--section GENERAL --section HARDWARE --section OPERATING_SYSTEM
  --section USER_AND_LOCATION --section DISK_ENCRYPTION --section SECURITY`, and
  `_inventory_export_row()` resolves values through `_flatten_record` plus a new
  `INVENTORY_FIELD_CANDIDATES` lookup table that handles both nested (current) and
  flat (legacy) shapes.
- Per-device `pro device <id>` enrichment is no longer the only source for FileVault,
  SIP, Firewall, Bootstrap Token, and Gatekeeper columns — those values now come from
  the inventory list's SECURITY section. Setting
  `inventory_csv.skip_security_enrichment: true` is now safe with no data loss for
  the standard security columns; it simply skips redundant per-device API calls.

### Added

- New `jamf_cli.command_timeout_seconds` config key (default `300`) sets the per-call
  timeout for jamf-cli subprocess invocations. The previous hardcoded 120s timeout
  was insufficient for slow Jamf Pro instances or large fleets.
- New `jamf_cli.ea_results_timeout_seconds` config key (default `600`) sets a
  longer timeout specifically for `pro report ea-results --all`, which is consistently
  the slowest jamf-cli call because it queries every EA value across the fleet.
- New `inventory_csv` config block with `max_workers` (default `20`) and
  `skip_security_enrichment` (default `false`). Replaces the previous hardcoded
  `max_workers=8` and provides an opt-out for the per-device security enrichment
  loop now that the inventory list returns security fields directly.
- `JamfCLIBridge.computers_list()` accepts a `sections` argument and converts it to
  repeated `--section` flags. `_run()` and `_run_and_save()` accept an optional
  `timeout` override.

### Changed

- Tracked jamf-cli dependency updated to v1.14.0. No code changes required.
  Notable upstream changes in v1.14.0: added `-vv` (request headers) and `-vvv`
  (request and response bodies) verbose levels — additive and orthogonal to this
  tool's stdout JSON parsing. Generator command ingests Jamf Pro 11.27.0
  monolith OpenAPI spec — improves command coverage upstream without affecting
  any commands this tool already calls.

## [1.2.0] - 2026-04-20

### Added

- **`export-reports` command** — generates dated, filtered CSV snapshots from the
  wide `automation_inventory_*.csv` produced by `launchagent-run --mode jamf-cli-full`.
  Configured via the new `export_reports` list in `config.yaml`.  Each entry defines
  a name, output directory, filename template (`{ts}` is replaced with a timestamp),
  schedule (`daily`, `mon,wed,fri`, `1st-of-month`, etc.), optional row filter
  (`within_days` or `exclude_values`), and optional column selection/rename map.
  State files in `jamf-cli-data/state/export-<name>.last` prevent double-writes
  within the same day.
- `export-reports` runs automatically as the final step of
  `launchagent-run --mode jamf-cli-full` when `export_reports` entries are
  configured; exported paths are recorded in the automation status JSON.
- `Config.export_reports` property (returns `list[dict]`, empty list default).
- **`sheets.only`** config list — when non-empty, only the named workbook tabs
  are written. This takes precedence over `sheets.skip` and supports focused
  workbooks such as patch-only, security-only, or mobile-only exports.
- **`sheets.skip`** config list — named workbook tabs can now be skipped during
  `generate` and `school-generate`, including CSV-backed sheets, custom EA tabs,
  and auxiliary tabs such as `Report Sources` and `Charts`. Sheet names are
  matched case-insensitively and unknown names emit a warning.
- **`automation.generate_html` / `generate_xlsx` / `generate_inventory_csv`**
  config flags — LaunchAgent automation can now produce timestamped HTML,
  xlsx, and inventory CSV artifacts per scheduled run, including `snapshot-only`.
- `launchagent-run` status JSON now records separate xlsx, HTML, and inventory
  CSV output paths when those artifacts are produced.
- `cmd_html()` now archives older timestamped HTML outputs using the same
  `output.archive_enabled` / `keep_latest_runs` retention rules as xlsx reports.

### Changed

- Tracked jamf-cli dependency updated to v1.11.0. No code changes required:
  the field-candidate and fallback logic already handles the v1.10.0 change
  where `pro mobile-devices list` switched to the detail endpoint with nested
  `general.*` JSON fields; the `MOBILE_INVENTORY_FIELD_CANDIDATES` dictionary
  already covers both flat and nested key shapes.
- `pro computers-inventory` remains the primary command namespace in v1.10.0;
  `computers` / `comp` are now registered as aliases pointing to it, so all
  existing calls to `pro computers-inventory patch` continue to work unchanged.
- New v1.11.0 subcommands `pro classic-account-users list` and
  `pro classic-account-groups list` are not yet used by this tool; flagged here
  for future consideration as a backup-coverage sheet.
- Tracked jamf-cli dependency updated to v1.12.0. No code changes required.
  Notable upstream changes in v1.12.0: `apply` now works for PATCH-only resources
  (vpp-locations, computers-inventory, adcs-settings, digi-cert-settings,
  mobile-device-groups-static-groups, patch-software-title-configurations,
  team-viewer-remote-administrations, venafis) — this tool does not use `apply`.
  The `--rename` flag was renamed to `--name` for `device-enrollment-instances`
  create/update/apply operations — this tool only uses `device-enrollment-instances list`
  and is unaffected. `config show`, `config list`, and `config validate` now accept
  `-o` for structured output (json, yaml, csv, table, plain) — additive, no impact.
- Tracked jamf-cli dependency updated to v1.13.0. No code changes required.
  Notable upstream changes in v1.13.0: `--installation-priority` added to package
  upload commands — this tool does not upload packages. `--custom-payload-file` and
  `--custom-payload-domain` added for classic macOS config profile create/update —
  this tool only uses `classic-macos-config-profiles list` and is unaffected.
  Help command examples now consistently include the `pro` prefix — cosmetic/docs
  change, no impact on CLI syntax or on the help-output parser used for command
  discovery. HTTP client internals (streaming multipart, shared transport) improved
  with no CLI surface change.

## [1.1.0] - 2026-04-16

### Added

- Added **Active Devices** sheet to the jamf-cli workbook showing total, active, and
  inactive device counts against the `thresholds.stale_device_days` window.
- Added adjusted compliance columns to **Patch Compliance**: Adjusted Up To Date,
  Adjusted Out Of Date, Adjusted Total, and Adjusted Completion %. These columns scale
  raw patch counts by the active-device ratio so stale/offline devices don't deflate
  reported compliance. If device-compliance data is unavailable the adjusted columns are
  silently omitted and raw columns remain unchanged.
- Added Jamf School reporting support for `jamf-cli school` data (jamf-cli 1.7+) and
  Jamf School device CSV exports.
- Added `school-generate`, `school-collect`, `school-scaffold`, and `school-check`
  commands.
- Added Jamf School workbook sheets for inventory, OS versions, device status, stale
  devices, overview, device groups, users, classes, apps, profiles, and locations.
- Added **Cleanup Analysis** section to the HTML report. Surfaces disabled policies,
  unscoped policies, unscoped macOS profiles, unused packages, and unused scripts — each
  in its own tab with a count badge. The section appears only when per-policy and
  per-profile detail JSON is cached on disk (populated by the `collect` step). If no
  detail cache exists, the section is omitted silently.
- Added **macOS Adoption Timeline** chart to the HTML report. Requires
  `html.track_history: true`; the chart appears once two or more point-in-time snapshots
  exist for the same instance.
- Added `scripts/demo.sh` as a supported offline demo runner that generates fixture-backed
  HTML, Jamf Pro workbook, mobile CSV workbook, and Jamf School workbook outputs without
  requiring a live tenant or local maintainer workspaces.

### Changed

- Extended the config and documentation surface to cover Jamf School mappings and
  workflows.
- Documented the committed fixture corpus as the supported no-credentials demo path for
  the community repo and replaced README workspace examples that implied local `Dummy/`
  or `Harbor/` directories.

### Fixed

- Fixed a cache lookup bug in `_latest_cached_json` where `rglob` was matching JSON files
  inside per-ID detail subdirectories (e.g. `classic-policies/14/`) when querying the
  parent directory. Changed to non-recursive `glob` so list-level and detail-level caches
  are not confused.
- Fixed HTML report JavaScript being completely non-functional (dark mode, table sorting,
  search, CSV export all broken). The `_js()` method used a plain triple-quoted Python
  string, causing `\r` and `\n` to be emitted as literal CR/LF bytes inside JavaScript
  regex patterns and string literals, producing a parse error that silently broke the
  entire `<script>` block. Fixed by switching to a raw string (`r"""..."""`).

### Changed

- Removed the DevliegereM attribution link from the HTML report footer. Credit is
  retained in source-code comments. Public-facing documentation and the wiki continue
  to credit the original project.

## [1.0.0] - 2026-04-14

### Added

- Initial tagged community release of the single-file Jamf reporting tool.
- Config-driven Jamf Pro CSV reporting with scaffold, validation, collection, and report
  generation workflows.
- Optional `jamf-cli` integration for live snapshots and expanded workbook coverage.
- Release packaging automation for tagged GitHub releases.
