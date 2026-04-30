# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

### Added

- **Health Audit & Group Hygiene**: New reporting surface leveraging `jamf-cli pro audit` and `jamf-cli pro group-tools analyze`.
- Added **Audit Summary** and **Group Hygiene** sheets to the Excel workbook. Audit summary includes severity-based color coding (CRITICAL, WARNING).
- New **Health Audit** screen in the macOS app for running on-demand health checks and hygiene analysis.
- Implementation of a **"View" button** in the Group Hygiene screen that directly opens the computer group in the Jamf Pro web console.
- Audit and hygiene results from the macOS app are now automatically **saved to the workspace** as JSON snapshots, ensuring persistence across app restarts.
- `SystemActions.open` now supports `http` and `https` URLs, enabling the app to launch the default browser for Jamf Pro console links.
- `JamfCLIBridge` (Python) and `CLIBridge` (Swift) now include dedicated methods for `audit` and `group_analyze`.
- macOS app sidebar now includes a dedicated "Health Audit" tab under the REPORTS group.

### Fixed

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
