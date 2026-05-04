# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This file orients AI coding assistants working on this project. Read it before making
any changes.

> **Note:** `AGENTS.md` is a mirror of this file for OpenAI-compatible agents. Keep them
> in sync when making changes here.

---

## What This Project Is

This project has two components that ship together:

**1. Python CLI engine (`jamf-reports-community.py`)** — A single-file Python script that
generates multi-sheet Excel workbooks and/or self-contained HTML reports from Jamf Pro CSV
exports and/or jamf-cli JSON data. As of v1.7-1.9 support, it also generates Jamf School
reports from jamf-cli school data and/or Jamf School device CSV exports. It is config-driven:
users edit `config.yaml` to map their column names to logical field names; no Python changes
are needed for normal use.

**2. Native macOS app (`app/`)** — A SwiftUI GUI (macOS 14+, Swift 6) that wraps every CLI
flow — config editing, scheduling via LaunchAgents, report generation, run history — and adds
a Historical Trends screen built on archived `summary.json` snapshots. The app bundles a
private Python runtime and the CLI script; end users do not need Python installed separately.
It is a SwiftPM project (`app/Package.swift`), not a hand-rolled `.xcodeproj`.

Target audience: Mac/iPad admins at any organization running Jamf Pro or Jamf School.
Neither component should contain any org-specific values in the code.

---

## Architecture

### Python CLI Engine

The entire Python implementation lives in `jamf-reports-community.py` (~13,600 lines). There
are no other Python files. Do not create additional modules — keep it single-file.

### Classes

| Class | Purpose |
|-------|---------|
| `Config` | Loads `config.yaml`, deep-merges with `DEFAULT_CONFIG`, exposes typed properties. `resolve_path()` resolves relative paths from the config file's directory. |
| `ColumnMapper` | Resolves logical field names → CSV column names. `.get(field)` returns name or None. `.extract(row, field)` returns cell value or `""` |
| `JamfCLIBridge` | Subprocess wrapper for jamf-cli pro/protect commands. Saves JSON output to `jamf-cli-data/`. Optional — gracefully no-ops if jamf-cli is absent. Supports `profile` for multi-tenant use. Falls back to latest cached JSON when live calls fail (`use_cached_data=True`). |
| `SchoolCLIBridge` | Subclass of `JamfCLIBridge` for `jamf-cli school` commands. Same caching/fallback infrastructure. Methods: `overview`, `devices_list`, `device_groups_list`, `users_list`, `groups_list`, `classes_list`, `apps_list`, `profiles_list`, `locations_list`. |
| `CoreDashboard` | Generates sheets from jamf-cli data: Fleet Overview, Mobile Fleet Summary, Inventory Summary, Mobile Inventory, Security Posture, Device Compliance, EA Coverage, EA Definitions, Software Installs, Policy Health, Profile Status, Mobile Config Profiles, App Status, Patch Compliance, Patch Failures, Update Status, Update Failures. No CSV required. |
| `CSVDashboard` | Generates sheets from a Jamf Pro CSV export. Only runs when `--csv` is provided. Generates: Device Inventory, Stale Devices, Security Controls, Security Agents, Compliance, plus one sheet per `custom_eas` entry. |
| `SchoolDashboard` | Generates sheets from Jamf School data (jamf-cli school or CSV export). Sheets: Device Inventory, OS Versions, Device Status, Stale Devices (CSV-driven); School Overview, Device Groups, Users, Classes, Apps, Profiles, Locations (bridge-driven). |
| `SchoolColumnMapper` | Resolves `school_columns` config field names → Jamf School CSV column names. Same interface as `ColumnMapper`. |
| `ChartGenerator` | Generates matplotlib PNG charts and embeds them in the xlsx. Skipped if matplotlib is not installed (`HAS_MATPLOTLIB` flag). |
| `HtmlReport` | Generates a self-contained HTML instance report from jamf-cli data. Adapts the design from work from @DevliegereM. Fetches overview, security, and all list-type resources (policies, profiles, scripts, packages, smart groups, org data). Uses Chart.js from CDN; no new Python dependencies. |

### Key top-level functions

| Function | Purpose |
|----------|---------|
| `_safe_write(ws, row, col, value, fmt)` | Sanitizes cell values before writing: handles None, NaN/inf, control chars, formula injection |
| `_parse_manager(raw)` | Parses AD Distinguished Names into readable names |
| `_load_matplotlib()` | Lazy-loads matplotlib; sets `HAS_MATPLOTLIB`, `plt`, `mdates` globals |
| `_archive_old_output_runs(...)` | Moves older timestamped report files into archive_dir |
| `_archive_csv_snapshot(csv_path, hist_dir)` | Copies the current CSV into the historical snapshot dir with a timestamp |
| `_semantic_warnings(config, df)` | Checks for likely column mapping mistakes before writing |
| `_school_csv_load(csv_path)` | Loads a Jamf School CSV export, auto-detecting semicolon vs comma delimiter |
| `cmd_scaffold(csv_path, out_path)` | Reads CSV headers, fuzzy-matches via `COLUMN_HINTS`/`COLUMN_EXCLUDES`, writes starter `config.yaml` |
| `cmd_check(config, csv_path)` | Validates jamf-cli auth and all configured column names against actual CSV headers |
| `cmd_generate(config, csv_path, out_file, historical_csv_dir)` | Main entry point — builds xlsx, generates charts |
| `cmd_html(config, out_file, no_open)` | Builds the self-contained HTML instance report via `HtmlReport` |
| `cmd_collect(config, csv_path, historical_csv_dir)` | Fetches live jamf-cli snapshots and optionally archives a CSV snapshot |
| `cmd_inventory_csv(config, out_file)` | Exports a wide computer inventory CSV from jamf-cli computers list + EA results |
| `cmd_school_scaffold(csv_path, out_path)` | Reads Jamf School CSV headers, fuzzy-matches via `SCHOOL_COLUMN_HINTS`, writes/appends `school_columns` block |
| `cmd_school_check(config, csv_path)` | Validates school bridge availability and column mappings |
| `cmd_school_collect(config)` | Fetches all jamf-cli school snapshots in parallel |
| `cmd_school_generate(config, csv_path, out_file)` | Builds the Jamf School Excel report |

### Scaffold semantic matching

`COLUMN_HINTS` / `COLUMN_EXCLUDES` — Jamf Pro CSV auto-detection.
`SCHOOL_COLUMN_HINTS` / `SCHOOL_COLUMN_EXCLUDES` — Jamf School CSV auto-detection.

Each maps logical field names to known-good/bad header substrings. The `EXCLUDES` dict
prevents false positives (e.g., "Name" must not match "LocationName" for `device_name`).

### CLI commands

```
# Jamf Pro
python3 jamf-reports-community.py generate [--config config.yaml] [--csv export.csv]
                                           [--out-file report.xlsx]
                                           [--historical-csv-dir snapshots/]
python3 jamf-reports-community.py html     [--config config.yaml] [--out-file report.html]
                                           [--no-open]
python3 jamf-reports-community.py collect  [--config config.yaml] [--csv export.csv]
                                           [--historical-csv-dir snapshots/]
python3 jamf-reports-community.py inventory-csv [--config config.yaml]
                                                [--out-file inventory.csv]
python3 jamf-reports-community.py scaffold [--csv export.csv] [--out config.yaml]
python3 jamf-reports-community.py check    [--csv export.csv]

# Jamf School (jamf-cli 1.7+)
python3 jamf-reports-community.py school-generate [--config config.yaml]
                                                  [--csv school_export.csv]
                                                  [--out-file report.xlsx]
python3 jamf-reports-community.py school-collect  [--config config.yaml]
python3 jamf-reports-community.py school-scaffold [--csv school_export.csv]
                                                  [--out config.yaml]
python3 jamf-reports-community.py school-check    [--config config.yaml]
                                                  [--csv school_export.csv]
```

**`html`** — generate a self-contained HTML instance report intended for management
review. Fetches: overview, security posture, policies, profiles, scripts, packages,
smart groups, categories, ADE instances, and org data (sites, buildings, departments).
Writes a single `.html` file with embedded Chart.js charts and a dark-mode toggle.
Auto-opens in the default browser unless `--no-open` is passed.
HTML design is adapted from [@DevliegereM](https://github.com/DevliegereM).

**`collect`** — fetch live snapshots from jamf-cli and save to `jamf_cli.data_dir`. Also
archives a CSV snapshot if `--csv` and `--historical-csv-dir` are both provided.

**`inventory-csv`** — export a wide CSV from jamf-cli `computers list` + EA results,
suitable for use as a `--csv` source on systems without a Jamf Pro CSV export.

### `--historical-csv-dir` usage

Point to a directory of dated CSV snapshots (filenames should contain `YYYY-MM-DD`,
`YYYYMMDD`, `YYYY-MM-DD_HHMMSS`, or `YYYY-MM-DDTHHMMSS`; file mtime is the fallback).
With 2+ snapshots, trend charts (line + stacked area) are generated. With a single
snapshot, point charts are generated.

```bash
# Archive a run manually (or use collect --csv)
cp "Jamf Export.csv" "snapshots/computers_$(date +%Y-%m-%d).csv"

python3 jamf-reports-community.py generate --csv "Latest Export.csv" \
    --historical-csv-dir snapshots/
```

---

## Config System — Critical Rules

`DEFAULT_CONFIG` (top of script) is the **single source of truth** for all config keys.
`config.example.yaml` must be a working example of that structure — the same key names,
no extras.

**Never add a key to `config.example.yaml` that is not read by the code.** Phantom keys
mislead users and are difficult to audit.

When adding a new config key:
1. Add it to `DEFAULT_CONFIG` with a sensible default.
2. Read it from `config` in the relevant class/function.
3. Document it in `config.example.yaml` with a comment.
4. Update `COMMUNITY_README.md` if it's user-facing.

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
```

When using multiple Jamf Pro instances, set `data_dir` to a profile-specific path so
snapshots from different tenants don't overwrite each other.

### output config

```yaml
output:
  output_dir: "Generated Reports"
  timestamp_outputs: true        # append date/time to output filenames
  archive_enabled: true          # move older runs to archive_dir
  archive_dir: ""                # defaults to "archive" next to output file
  keep_latest_runs: 10           # how many timestamped runs to keep in output_dir
```

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
`compliance.failures_count_column` (compliance trend). All chart code gates on
`HAS_MATPLOTLIB`.

---

## Invariants — Do Not Break These

**`_safe_write` for all CSV-sourced data.** Never call `worksheet.write()` directly with
values that came from user data. Always route through `_safe_write()`. Static labels and
headers (written by the script itself) can use `worksheet.write()` directly.

**No hardcoded column names.** All column names must come from config via `ColumnMapper`.
The string `"Computer Name"` should not appear in the script body — only in
`config.example.yaml` and `config.yaml`.

**No hardcoded org-specific values.** No IP addresses, URLs, usernames, department names,
policy names, or EA names should exist anywhere in the Python code.

**jamf-cli is optional.** `JamfCLIBridge.is_available()` must be checked before any
jamf-cli call. If it returns False, the script continues with CSV-only output. Never make
jamf-cli a hard requirement.

**matplotlib is optional.** Use `_load_matplotlib()` before any chart code. All chart
logic must gate on `HAS_MATPLOTLIB`. If matplotlib is absent, the script runs normally.

**Single file.** The tool is designed to be dropped into any directory and run. Do not
split into multiple files or add a package structure.

---

### Swift App Architecture

The macOS app lives in `app/` and is a SwiftPM executable target (`JamfReports`).
Build target: macOS 14+ (Sonoma), Swift 6 strict concurrency.

#### Key services

| Service | Purpose |
|---------|---------|
| `WorkspaceStore` | `@Observable` per-profile state. Sidebar chip switches the active profile; every screen re-routes to that workspace's data. |
| `CLIBridge` / `CLIBridge+Run` | `Process`-based async wrapper for `jrc` and `jamf-cli`. Streams stdout/stderr live to the Runs screen. Prefers the bundled Python runtime + bundled CLI script; falls back to external `python3`/`jrc`. |
| `WorkspacePaths` | Typed, profile-validated path constants under `~/Jamf-Reports/<profile>/`. All path construction goes through here. |
| `ProfileService` | Validates profile slugs (`^[a-z0-9][a-z0-9._-]*$`), resolves workspace URLs, discovers local profiles. |
| `LaunchAgentService` | Discovers and parses existing `~/Library/LaunchAgents/com.jamfreports.*.plist` jobs. |
| `LaunchAgentWriter` | Generates LaunchAgent plists and writes them atomically. |
| `OnboardingFlow` | Orchestrates first-run: jamf-cli auth via `stdin`, profile creation, workspace init, first collect/generate run. |
| `ConfigService` | Reads and writes `config.yaml` within a profile workspace. |
| `TrendStore` | Loads `summary.json` snapshots from `snapshots/computers/summaries/`; feeds the Trends screen charts. |
| `DeviceInventoryService` | Reads cached device inventory JSON from the workspace. |
| `ReportLibrary` | Lists generated reports in `Generated Reports/`. |
| `RunHistoryService` | Reads run logs from `automation/logs/`. |
| `SnapshotArchiveService` | Manages dated CSV snapshot archives. |
| `SystemActions` | `NSWorkspace` file open/reveal, strictly bounded to allowed paths. |
| `YAMLCodec` | Minimal YAML reader/writer for `config.yaml` fields the GUI exposes. |
| `JamfCLIInstaller` | Auto-update check and installation via Homebrew. |

**Convention:** New jamf-cli command wrappers go through the `CLICommand` enum and `CLIExecutor` protocol (`Services/CLICommand.swift`), not bespoke `CLIBridge` methods. Existing helpers (`generate`, `collect`, `audit`, `deviceDetail`, …) stay as-is per `.claude/plans/ADR-W21-clicommand-enum.md` (Hybrid scope).

#### Key views (13 screens)

`Sidebar`, `Titlebar`, `OverviewView`, `FleetOverviewView`, `DevicesView`,
`TrendsView`, `ReportsView`, `BackupsView`, `SchedulesView`, `RunsView`,
`ConfigView`, `CustomizeView`, `SourcesView`, `AuditView`, `OnboardingView`, `SettingsView`

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

#### Building the app

```bash
cd app
swift build                        # validate compilation
swift run JamfReports              # launch (debug)

# Produce a runnable .app bundle (ad-hoc signed, local dev use)
./build-app.sh release             # → app/build/JamfReports.app

# Skip Python runtime bundling for fast local iteration
JRC_BUNDLE_PYTHON=0 ./build-app.sh debug
```

The release build bundles a private Python runtime via `scripts/build-python-runtime.sh`.
Pin details live in `app/python-runtime.lock`. The script refuses to proceed until
`PBS_ARM64_SHA256` and `PBS_X86_64_SHA256` are filled in.

For distribution to other Macs: sign with a Developer ID certificate, notarize via
`xcrun notarytool`, and staple with `xcrun stapler staple`. These steps are currently
manual and not integrated into `build-app.sh`.

#### Swift code conventions

- Swift 6 strict concurrency (`@MainActor`, `Sendable`, `async/await` throughout).
- `@Observable` for state; no `ObservableObject` / `@Published`.
- All user-visible strings in English; no `NSLocalizedString` wrapping required for now.
- No `UIKit` — SwiftUI only.
- All new services must validate paths through `ProfileService.workspaceURL(for:)` before
  constructing any file paths.
- Test targets live in `app/Tests/JamfReportsTests/`.

---

## Custom EA Types — Adding a New One

EA types are dispatched in `CSVDashboard._write_custom_ea()` via a dict:

```python
dispatch = {
    "boolean": self._ea_boolean,
    "percentage": self._ea_percentage,
    "version": self._ea_version,
    "text": self._ea_text,
    "date": self._ea_date,
}
```

To add a new type:
1. Add a method `_ea_<typename>(self, ws, row_i, col, ea)` to `CSVDashboard`.
2. Add the key to the `dispatch` dict.
3. Document the type and its config keys in `config.example.yaml`.
4. Update the type table in `COMMUNITY_README.md`.

---

## jamf-cli JSON Shapes (v1.14.0)

CoreDashboard parses these exact shapes. Minimum supported jamf-cli is **v1.14.0**.
Older versions are not supported — older fallback branches were removed in W21 (patch-status
`installed/total` shape). The `update-status` older shape is preserved pending live
verification against a tenant with active update plans.

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

---

## Code Conventions

### Python CLI

- Python 3.9+. Type hints on all method signatures.
- Google-style docstrings on all classes and public methods.
- Functions ≤100 lines. Cyclomatic complexity ≤8.
- 100-character line length.
- No relative imports (there is only one file).

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

Tests live in `app/Tests/JamfReportsTests/`. Current coverage:
`AuditHygieneTests`, `DeviceInventoryRecordTests`, `LaunchAgentServiceTests`,
`LaunchAgentWriterTests`, `RunHistoryServiceTests`, `TrendStoreTests`.

All new services and business-logic functions should have corresponding test files.
Follow the same naming convention: `<ServiceName>Tests.swift`.

Verify the app compiles before committing any Swift change:

```bash
cd app && swift build 2>&1 | tail -20
```

### Python CLI

An automated pytest suite now exists under `tests/`, backed by committed fixtures in
`tests/fixtures/`. Manual validation is still useful, especially for bigger end-to-end
changes. Local manual test workflow:

```bash
cd /path/to/jamf-reports-community

# Verify compilation
python3 -c "import py_compile; py_compile.compile('jamf-reports-community.py', doraise=True)"

# Scaffold from test CSV (semantic matching should produce correct mappings)
python3 jamf-reports-community.py scaffold --csv "Jamf Reports/97 Computers.csv"

# Validate column mapping
python3 jamf-reports-community.py check --csv "Jamf Reports/97 Computers.csv"

# Generate report (CSV only — no jamf-cli needed)
python3 jamf-reports-community.py generate --csv "Jamf Reports/97 Computers.csv"

# Collect jamf-cli snapshots (requires jamf-cli auth, or use dummy profile)
python3 jamf-reports-community.py collect

# Export inventory CSV from jamf-cli
python3 jamf-reports-community.py inventory-csv

# Generate HTML instance report (requires jamf-cli auth or cached data)
python3 jamf-reports-community.py html --no-open
```

All six commands should exit without errors before any change is considered ready.

### Automated fixtures

Committed automated-test fixtures now live under `tests/fixtures/`. They are derived from
Jamf-provided fake/demo data from the local `Dummy/` and `Harbor/` workspaces, not
production or employer/client data, and are approved for commit.

Keep the committed fixture corpus curated:

- prefer stable filenames in `tests/fixtures/csv/` and `tests/fixtures/jamf-cli-data/`
- keep dated filenames only in `tests/fixtures/snapshots/` where chart/trend logic needs them
- keep one latest-good jamf-cli JSON sample per command shape unless a regression needs more
- do not commit generated `.xlsx` or chart PNG outputs

Run automated tests with:

```bash
python3 -m pytest tests -q
```

### Dummy profile testing

The dummy profile (`jamf_cli.profile: "dummy"`) uses pre-saved JSON from
`jamf-cli-data/dummy/` for fully offline testing without a live Jamf Pro connection.
Set `profile: "dummy"` in `config.yaml` and point `data_dir` to a directory containing
the cached JSON files.

### Useful EAs in the test CSV for custom_eas testing

`McAfee Agent Version` (text), `SysTrack Install Status` (boolean), `SysTrack Agent
Version` (version), `KerberosSSO - password_expires_date` (date), `EC - adBound`
(boolean), `Apply All Updates - Date` (date)

---

## Files

```
jamf-reports-community/
├── jamf-reports-community.py   # Entire Python CLI implementation — single file
├── config.example.yaml         # Annotated example config — must stay in sync with DEFAULT_CONFIG
├── CHANGELOG.md                # User-visible changes between commits and releases
├── COMMUNITY_README.md         # End-user setup and usage guide
├── CLAUDE.md                   # This file
├── AGENTS.md                   # Mirror of CLAUDE.md for OpenAI-compatible agents
├── PROJECT_CONTEXT.md          # Session context, known issues, enhancement backlog
├── requirements.txt            # xlsxwriter, pandas, pyyaml, matplotlib
├── requirements-dev.txt        # pytest and dev tools
├── docs/wiki/                  # GitHub Wiki source files
├── tests/                      # Python pytest suite
│   ├── fixtures/               # Committed test data (CSV, jamf-cli JSON, snapshots)
│   └── test_*.py               # One file per feature area
├── Jamf Reports/               # Test CSV (gitignored except the dummy CSV)
│   └── 97 Computers.csv        # 96 sanitized dummy devices
├── app/                        # Native macOS SwiftUI app
│   ├── Package.swift           # SwiftPM manifest (executable target, macOS 14+, Swift 6)
│   ├── JamfReports.entitlements
│   ├── build-app.sh            # Produces app/build/JamfReports.app with ad-hoc signing
│   ├── python-runtime.lock     # Pinned python-build-standalone release + SHA256 checksums
│   ├── requirements-runtime.txt # Packages bundled in the private Python runtime
│   ├── SECURITY_AUDIT.md       # Security audit findings and mitigations
│   ├── scripts/
│   │   └── build-python-runtime.sh  # Downloads + packages the private Python runtime
│   ├── iconset/                # App icon source and build script
│   ├── Sources/JamfReports/
│   │   ├── App/                # @main entry point, ContentView
│   │   ├── Models/             # Data models + DemoData
│   │   ├── Services/           # Business logic, CLIBridge, workspace management
│   │   ├── Theme/              # Design tokens, shared components
│   │   └── Views/              # 16 SwiftUI screens
│   └── Tests/JamfReportsTests/ # Swift XCTest suite
└── .gitignore                  # Excludes config.yaml, Generated Reports/, jamf-cli-data/
```

`config.yaml` is gitignored. Users create it via `scaffold` or by copying
`config.example.yaml`. Never commit a real `config.yaml` — it will contain column names
that reveal org-specific EA naming conventions.

`CHANGELOG.md` tracks user-visible changes. Update `Unreleased` whenever a change affects
end users, and roll those notes into a versioned section when cutting a release tag.

---

## Reference: v3.6 Production Script

This project was written fresh — not stripped from an internal production script
(`jamf_reports_cli_v3.6.py`). However, that script contains reference implementations
worth consulting when adding new features:

- `JamfCLIBridge` subprocess pattern
- `_safe_write()` sanitization approach
- `_parse_manager()` AD DN parsing
- Certificate expiration sheet design
- Tiered data collection via `collect.zsh` + LaunchAgent

Do not port org-specific logic, hardcoded column names, or tenant-specific EA names.

---

## What Not to Do

### Python CLI

- Do not add a `setup.py`, `pyproject.toml`, or package structure. It must remain a
  drop-in script.
- Do not add features that require org-specific configuration to be useful (e.g., a sheet
  that only makes sense with a specific EA name hardcoded).
- Do not add dependencies beyond those in `requirements.txt` without a strong reason.
  Each dependency is installation friction for end users.
- Do not add backward-compatibility shims or dual config formats. When a key name changes,
  update the code and the example — users will re-scaffold.

### Swift App

- Do not add Swift Package dependencies without a strong justification. Each dependency
  increases build time, maintenance surface, and binary size.
- Do not construct file paths by string interpolation — always use `ProfileService.workspaceURL(for:)`
  and `WorkspacePaths` typed constants.
- Do not add `UIKit` imports or `AppKit` patterns that bypass SwiftUI — use `NSViewRepresentable`
  only when SwiftUI has no equivalent.
- Do not expose new CLI operations unless the Python CLI has a corresponding command to back
  them. The app is a GUI shell; the Python script is the engine.
- Do not add Xcode project files (`.xcodeproj`, `.xcworkspace`) — the project is SwiftPM-only.
- Do not request `sudo` or install LaunchDaemons. The security model is user-agent-only.
