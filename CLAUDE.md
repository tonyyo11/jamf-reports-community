# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This file orients AI coding assistants working on this project. Read it before making
any changes.

> **Note:** `AGENTS.md` is a mirror of this file for OpenAI-compatible agents. Keep them
> in sync when making changes here.

---

## What This Project Is

A single-file Python script (`jamf-reports-community.py`) that generates multi-sheet
Excel workbooks from Jamf Pro CSV exports and/or jamf-cli JSON data. It is config-driven:
users edit `config.yaml` to map their Jamf Pro column names to logical field names; no
Python changes are needed for normal use.

Target audience: Mac admins at any organization running Jamf Pro. The tool must work
without any org-specific values in the code.

---

## Architecture

The entire implementation lives in `jamf-reports-community.py` (~3,300 lines). There are
no other Python files. Do not create additional modules — keep it single-file.

### Classes

| Class | Purpose |
|-------|---------|
| `Config` | Loads `config.yaml`, deep-merges with `DEFAULT_CONFIG`, exposes typed properties. `resolve_path()` resolves relative paths from the config file's directory. |
| `ColumnMapper` | Resolves logical field names → CSV column names. `.get(field)` returns name or None. `.extract(row, field)` returns cell value or `""` |
| `JamfCLIBridge` | Subprocess wrapper for jamf-cli. Saves JSON output to `jamf-cli-data/`. Optional — gracefully no-ops if jamf-cli is absent. Supports `profile` for multi-tenant use. Falls back to latest cached JSON when live calls fail (`use_cached_data=True`). |
| `CoreDashboard` | Generates 9 sheets from jamf-cli JSON data: Fleet Overview, Inventory Summary, Security Posture, Device Compliance, EA Coverage, EA Definitions, Software Installs, Policy Health, Patch Compliance. No CSV required. |
| `CSVDashboard` | Generates sheets from a Jamf Pro CSV export. Only runs when `--csv` is provided. Generates: Device Inventory, Stale Devices, Security Controls, Security Agents, Compliance, plus one sheet per `custom_eas` entry. |
| `ChartGenerator` | Generates matplotlib PNG charts and embeds them in the xlsx. Skipped if matplotlib is not installed (`HAS_MATPLOTLIB` flag). |

### Key top-level functions

| Function | Purpose |
|----------|---------|
| `_safe_write(ws, row, col, value, fmt)` | Sanitizes cell values before writing: handles None, NaN/inf, control chars, formula injection |
| `_parse_manager(raw)` | Parses AD Distinguished Names into readable names |
| `_load_matplotlib()` | Lazy-loads matplotlib; sets `HAS_MATPLOTLIB`, `plt`, `mdates` globals |
| `_archive_old_output_runs(...)` | Moves older timestamped report files into archive_dir |
| `_archive_csv_snapshot(csv_path, hist_dir)` | Copies the current CSV into the historical snapshot dir with a timestamp |
| `_semantic_warnings(config, df)` | Checks for likely column mapping mistakes before writing |
| `cmd_scaffold(csv_path, out_path)` | Reads CSV headers, fuzzy-matches via `COLUMN_HINTS`/`COLUMN_EXCLUDES`, writes starter `config.yaml` |
| `cmd_check(config, csv_path)` | Validates jamf-cli auth and all configured column names against actual CSV headers |
| `cmd_generate(config, csv_path, out_file, historical_csv_dir)` | Main entry point — builds xlsx, generates charts |
| `cmd_collect(config, csv_path, historical_csv_dir)` | Fetches live jamf-cli snapshots and optionally archives a CSV snapshot |
| `cmd_inventory_csv(config, out_file)` | Exports a wide computer inventory CSV from jamf-cli computers list + EA results |

### Scaffold semantic matching

`COLUMN_HINTS` maps each logical field to known-good header substrings.
`COLUMN_EXCLUDES` maps each logical field to substrings that should never match (e.g.,
"Bootstrap Token Allowed" is excluded from `bootstrap_token` — only "Escrowed" matches).
This prevents the mismatches that previously required manual post-scaffold correction.

### CLI commands

```
python3 jamf-reports-community.py generate [--config config.yaml] [--csv export.csv]
                                           [--out-file report.xlsx]
                                           [--historical-csv-dir snapshots/]
python3 jamf-reports-community.py collect  [--config config.yaml] [--csv export.csv]
                                           [--historical-csv-dir snapshots/]
python3 jamf-reports-community.py inventory-csv [--config config.yaml]
                                                [--out-file inventory.csv]
python3 jamf-reports-community.py scaffold [--csv export.csv] [--out config.yaml]
python3 jamf-reports-community.py check    [--csv export.csv]
```

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

## jamf-cli JSON Shapes (v1.2.0)

CoreDashboard parses these exact shapes. Do not change the parsing without verifying
against the jamf-cli source.

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

Patch-status parser handles both `installed/total` and `on_latest/on_other` field shapes
for compatibility with different jamf-cli versions.

---

## Code Conventions

- Python 3.9+. Type hints on all method signatures.
- Google-style docstrings on all classes and public methods.
- Functions ≤100 lines. Cyclomatic complexity ≤8.
- 100-character line length.
- No relative imports (there is only one file).

---

## Testing

No automated test suite exists yet. The test CSV is `Jamf Reports/97 Computers.csv`
(96 sanitized dummy devices). Manual test workflow:

```bash
cd "/Users/alyoung/Documents/04_GitHub_Projects/jamf-reports-community"

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
```

All five commands should exit without errors before any change is considered ready.

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
├── jamf-reports-community.py   # Entire implementation — single file
├── config.example.yaml         # Annotated example config — must stay in sync with DEFAULT_CONFIG
├── COMMUNITY_README.md         # End-user setup and usage guide
├── CLAUDE.md                   # This file
├── AGENTS.md                   # Mirror of CLAUDE.md for OpenAI-compatible agents
├── PROJECT_CONTEXT.md          # Session context, known issues, enhancement backlog
├── requirements.txt            # xlsxwriter, pandas, pyyaml, matplotlib
├── docs/wiki/                  # GitHub Wiki source files
├── Jamf Reports/               # Test CSV (gitignored except the dummy CSV)
│   └── 97 Computers.csv        # 96 sanitized dummy devices
└── .gitignore                  # Excludes config.yaml, Generated Reports/, jamf-cli-data/
```

`config.yaml` is gitignored. Users create it via `scaffold` or by copying
`config.example.yaml`. Never commit a real `config.yaml` — it will contain column names
that reveal org-specific EA naming conventions.

---

## Reference: v3.6 Production Script

This project was written fresh — not stripped from the private CBP/Akima production script
(`jamf_reports_cli_v3.6.py`). However, that script contains reference implementations worth
consulting when adding new features:

- `JamfCLIBridge` subprocess pattern
- `_safe_write()` sanitization approach
- `_parse_manager()` AD DN parsing
- Certificate expiration sheet design
- Tiered data collection via `collect.zsh` + LaunchAgent

Do not port org-specific logic, hardcoded column names, or CBP-specific EA names.

---

## What Not to Do

- Do not add a `setup.py`, `pyproject.toml`, or package structure. It must remain a
  drop-in script.
- Do not add features that require org-specific configuration to be useful (e.g., a sheet
  that only makes sense with a specific EA name hardcoded).
- Do not add dependencies beyond those in `requirements.txt` without a strong reason.
  Each dependency is installation friction for end users.
- Do not add backward-compatibility shims or dual config formats. When a key name changes,
  update the code and the example — users will re-scaffold.
