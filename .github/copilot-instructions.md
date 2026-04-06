# Copilot Instructions for jamf-reports-community

This file provides context for GitHub Copilot and other AI coding assistants working with this project.

## Project Overview

A single-file Python script (`jamf_reports_community.py`, ~3,800 lines) that generates multi-sheet Excel workbooks from Jamf Pro CSV exports and/or jamf-cli JSON data. Configuration-driven: users edit `config.yaml` to map their Jamf Pro column names to logical field names; no Python code changes are needed for normal use.

**Key constraint:** Must work for any organization running Jamf Pro without requiring hardcoded org-specific values (column names, policy names, IP addresses, etc.) in the code.

## Architecture

### Single-File Design

The entire implementation lives in `jamf_reports_community.py`. Do not split into modules—it's designed to be dropped into any directory and run as-is.

### Core Classes

| Class | Purpose |
|-------|---------|
| `Config` | Loads `config.yaml`, deep-merges with `DEFAULT_CONFIG`, exposes typed properties via `resolve_path()` |
| `ColumnMapper` | Resolves logical field names → CSV column names. Key methods: `.get(field)`, `.extract(row, field)` |
| `JamfCLIBridge` | Subprocess wrapper for jamf-cli. Saves JSON to `jamf-cli-data/`. Optional—gracefully no-ops if unavailable. Supports multi-tenant via `profile`. Falls back to cached JSON when live calls fail. |
| `CoreDashboard` | Generates 9 sheets from jamf-cli JSON: Fleet Overview, Inventory Summary, Security Posture, Device Compliance, EA Coverage, EA Definitions, Software Installs, Policy Health, Patch Compliance. |
| `CSVDashboard` | Generates sheets from Jamf Pro CSV export (only when `--csv` provided): Device Inventory, Stale Devices, Security Controls, Security Agents, Compliance, plus one sheet per `custom_eas` entry. |
| `ChartGenerator` | Generates matplotlib PNG charts and embeds in xlsx. Skipped if matplotlib not installed (`HAS_MATPLOTLIB` flag). |

### CLI Commands

```bash
# Generate report from CSV ± jamf-cli data
python3 jamf_reports_community.py generate [--config config.yaml] [--csv path/to/export.csv]
                                           [--out-file report.xlsx]
                                           [--historical-csv-dir snapshots/]

# Fetch live jamf-cli snapshots and archive CSV
python3 jamf_reports_community.py collect [--config config.yaml] [--csv path/to/export.csv]
                                          [--historical-csv-dir snapshots/]

# Export wide inventory CSV from jamf-cli
python3 jamf_reports_community.py inventory-csv [--config config.yaml]
                                                [--out-file inventory.csv]

# Scaffold config.yaml from CSV headers (fuzzy-matches via COLUMN_HINTS/COLUMN_EXCLUDES)
python3 jamf_reports_community.py scaffold [--csv path/to/export.csv] [--out config.yaml]

# Validate jamf-cli auth and config column mappings
python3 jamf_reports_community.py check [--csv path/to/export.csv]
```

## Critical Invariants (Do Not Break)

1. **`_safe_write()` for all CSV-sourced data.** Never call `worksheet.write()` directly with user data. Always route through `_safe_write()` which sanitizes None, NaN/inf, control chars, and formula injection. Static labels (written by script) can use `worksheet.write()` directly.

2. **No hardcoded column names.** All column names come from config via `ColumnMapper`. Strings like `"Computer Name"` appear only in `config.example.yaml` and `config.yaml`, never in code.

3. **No hardcoded org-specific values.** No IP addresses, URLs, usernames, department names, policy names, or EA names in code.

4. **jamf-cli is optional.** Always check `JamfCLIBridge.is_available()` before jamf-cli calls. Script continues with CSV-only output if jamf-cli absent.

5. **matplotlib is optional.** Use `_load_matplotlib()` before chart code. Gate all chart logic on `HAS_MATPLOTLIB`.

6. **Single file—always.** Drop-in script design. No modules, no package structure.

## Config System

### Single Source of Truth

`DEFAULT_CONFIG` (top of script) defines all keys. `config.example.yaml` mirrors that structure exactly—no phantom keys.

**Rule:** Never add a config key to `config.example.yaml` that isn't read by the code.

### When Adding a Config Key

1. Add to `DEFAULT_CONFIG` with sensible default
2. Read it in the relevant class/function
3. Document in `config.example.yaml` with comment
4. Update `COMMUNITY_README.md` if user-facing

### Key Names (Common Confusion Points)

Use these exact names:

| Section | Key | ❌ NOT |
|---------|-----|--------|
| `columns` | `operating_system` | `os_version` |
| `columns` | `last_checkin` | `last_contact` |
| `columns` | `email` | `assigned_user_email` |
| `jamf_cli` | `profile` | `jamf_profile` |
| `jamf_cli` | `allow_live_overview` | `live_overview` |
| `security_agents` | `connected_value` | `installed_value` |
| `compliance` | `failures_count_column` | `failed_count_column` |

## Testing & Validation

### Manual Test Workflow

No automated test suite. Test CSV: `Jamf Reports/97 Computers.csv` (96 sanitized dummy devices).

```bash
cd /path/to/jamf-reports-community

# 1. Verify syntax
python3 -c "import py_compile; py_compile.compile('jamf_reports_community.py', doraise=True)"

# 2. Scaffold from test CSV
python3 jamf_reports_community.py scaffold --csv "Jamf Reports/97 Computers.csv"

# 3. Validate column mapping
python3 jamf_reports_community.py check --csv "Jamf Reports/97 Computers.csv"

# 4. Generate report (CSV only, no jamf-cli needed)
python3 jamf_reports_community.py generate --csv "Jamf Reports/97 Computers.csv"

# 5. Collect jamf-cli snapshots (optional, or use dummy profile)
python3 jamf_reports_community.py collect

# 6. Export inventory CSV from jamf-cli (optional)
python3 jamf_reports_community.py inventory-csv
```

**All five commands must exit cleanly before any change is ready.**

### Dummy Profile Testing

For offline testing without live Jamf Pro:
- Set `jamf_cli.profile: "dummy"` in `config.yaml`
- Pre-saved JSON lives in `jamf-cli-data/dummy/`
- Fully offline—no credentials required

### Useful Test EAs (in the test CSV)

- `McAfee Agent Version` (text type)
- `SysTrack Install Status` (boolean type)
- `SysTrack Agent Version` (version type)
- `KerberosSSO - password_expires_date` (date type)
- `EC - adBound` (boolean type)
- `Apply All Updates - Date` (date type)

## Custom EA Types

Extension Attributes are dispatched in `CSVDashboard._write_custom_ea()`:

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
1. Add method `_ea_<typename>(self, ws, row_i, col, ea)` to `CSVDashboard`
2. Add key to `dispatch` dict
3. Document in `config.example.yaml`
4. Update type table in `COMMUNITY_README.md`

## Code Conventions

- **Python 3.9+** with type hints on all method signatures
- **Google-style docstrings** on classes and public methods
- **Functions ≤100 lines**, cyclomatic complexity ≤8
- **100-character line length**
- **No relative imports** (only one file anyway)
- **Comment only what needs explaining.** Code should be self-documenting. No commented-out code—delete it.

## jamf-cli JSON Data Shapes

CoreDashboard parses these exact shapes (jamf-cli v1.2.0). Don't change parsing without verifying against jamf-cli source:

**`pro report security --output json`**
```json
[
  {"section": "summary", "data": {"total_devices": N, "filevault_encrypted": N, ...}},
  {"section": "os_version", "os_version": "15.7.3", "count": N, "pct": "N%"}
]
```

**`pro report policy-status --output json`**
```json
[{"summary": {"total_policies": N, "enabled": N, ...},
  "config_findings": [{"severity": "...", "policy": "...", ...}]}]
```

**`pro report patch-status --output json`**
```json
[{"title": "Firefox", "id": "123", "on_latest": 100, "on_other": 20, ...}]
```

Note: Patch-status parser handles both `installed/total` and `on_latest/on_other` field shapes for compatibility.

## Key Top-Level Utility Functions

| Function | Purpose |
|----------|---------|
| `_safe_write(ws, row, col, value, fmt)` | Sanitizes cell values: None, NaN/inf, control chars, formula injection |
| `_parse_manager(raw)` | Parses AD Distinguished Names into readable names |
| `_load_matplotlib()` | Lazy-loads matplotlib; sets `HAS_MATPLOTLIB`, `plt`, `mdates` globals |
| `_archive_old_output_runs(...)` | Moves older timestamped report files to archive_dir |
| `_archive_csv_snapshot(csv_path, hist_dir)` | Copies current CSV into historical snapshot dir with timestamp |
| `_semantic_warnings(config, df)` | Checks for likely column mapping mistakes before writing |

## File Dependencies

- `config.example.yaml` — Annotated config template. Must stay in sync with `DEFAULT_CONFIG`. Users copy to `config.yaml`.
- `config.yaml` — Gitignored. Users create this via `scaffold` or by copying example.
- `Jamf Reports/97 Computers.csv` — Test data (96 sanitized dummy devices)
- `jamf-cli-data/` — Cached jamf-cli JSON output. Ignored in git.
- `Generated Reports/` — Output xlsx files and PNG charts. Ignored in git.

## Related Documentation

- **CLAUDE.md / AGENTS.md** — Detailed architecture, config system reference, invariants, conventions
- **COMMUNITY_README.md** — End-user setup and usage guide
- **PROJECT_CONTEXT.md** — Session context, known issues, enhancement backlog
- **docs/wiki/** — Extended documentation (GitHub Wiki source)

## Before You Change Anything

1. Read CLAUDE.md or AGENTS.md for the complete invariants and architecture
2. Understand that ALL CSV-sourced data must go through `_safe_write()`
3. Remember: **single file design**—no modules, no splits
4. Run the manual test workflow (all 5 commands) after your change
5. Verify no hardcoded org-specific values leak into the code
6. Check that config keys are in `DEFAULT_CONFIG` before using them
