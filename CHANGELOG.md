# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

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
