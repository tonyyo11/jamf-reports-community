# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

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
