# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

### Added

- macOS app per-device drilldown now calls `jamf-cli pro device <identifier>`
  for the selected row, caches the JSON under
  `~/Jamf-Reports/<profile>/jamf-cli-data/devices/`, and renders grouped detail
  rows in the Devices pane.
- macOS app report, collection, backup, validation, and drilldown commands now
  always pass the active workspace profile to `jrc` or `jamf-cli`; existing
  workspace configs are reconciled so `jamf_cli.profile` matches the selected
  profile.
- The macOS app now prefers the bundled/current Python script over an installed
  `jrc` shim when launching report commands, avoiding stale shim behavior after
  app updates.
- Onboarding now validates the newly registered `jamf-cli` profile with
  `jamf-cli config validate` before continuing to CSV mapping and first report
  generation.
- `--profile` now works as a runtime Jamf Pro profile override for Python
  commands that use `jamf_cli.profile`, while retaining its existing
  `workspace-init` behavior.
- `collect` now supports first-run Jamf CLI-only bootstrapping more completely,
  saving computer inventory, app/update status, groups, packages, scripts, and
  org metadata snapshots without requiring CSV or historical data.
- `inventory-csv` now saves/falls back through the normal jamf-cli cache path
  and still exports base computer inventory if extension attribute results are
  temporarily unavailable.
- New `backup` command wraps `jamf-cli pro backup --format json --output <dir>`
  and writes atomic per-profile backups plus a `manifest.json` under
  `~/Jamf-Reports/<profile>/backups/`.
- macOS app Backups screen lists local backups, can run a new backup, reveal
  backup folders, and diff two backups or an older backup against the latest
  via `jamf-cli pro diff`.
- macOS app Devices screen for current inventory review. It merges validated
  workspace-local inventory CSV output with cached jamf-cli compliance and patch
  snapshots, then presents searchable device rows, stale filtering, macOS version
  breakdowns, and per-device patch/security detail.
- SwiftUI macOS app scaffold with 10 design-faithful screens.
- Trends hero feature built on Swift Charts for 26-week historical visualization.
- Multi-profile workspace switching via sidebar profile chip.
- LaunchAgent-based scheduling for background data collection and reporting.
- NSWorkspace-bounded file actions for opening reports and revealing folders.
- Spectrum-inspired app icon and brand-faithful IBM Plex Mono typography.
- Emit per-run `summary.json` in `snapshots/summaries/` for macOS GUI trend consumption.
- New `SummaryJSONParser` and `TrendStore` in the macOS app to parse historical summaries.
- Real trend data visualization in `TrendsView` replacing synthetic demo data.
- `capabilities` command emits a deterministic app-facing manifest of supported Jamf
  products, commands, data sources, current-status surfaces, historical/trend surfaces,
  config sections, and known gaps. This gives the Swift app a stable contract instead
  of hardcoding sheet/source support.
- `--summary-json` for `generate`, `html`, `collect`, `school-generate`, and
  `school-collect`, giving the Swift app stable machine-readable run summaries.

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
