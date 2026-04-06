# jamf-reports-community — Project Context

Use this document to orient a new coding session. It covers what exists, what works, what is known to be broken or incomplete, and what to work on next.

---

## What This Project Is

A config-driven, community-shareable Jamf Pro reporting tool. Any organization running Jamf Pro can use it without editing Python — they configure `config.yaml` to map their Extension Attribute column names to logical field names, declare which security agents they deploy, and optionally add custom EA sheets.

This is a **separate project from the CBP/Akima production script** (`jamf_reports_cli_v3.6.py`). That script is org-specific and private. This one is designed for public release as a GitHub repository.

**Intended GitHub repo:** `https://github.com/[username]/jamf-reports-community`

**Local path:** `/Users/alyoung/Documents/GitHub/jamf-reports-community/`

---

## File Inventory

```
jamf-reports-community/
├── jamf-reports-community.py     # Main script — 1,265 lines
├── config.example.yaml           # Annotated example config for documentation
├── config.yaml                   # Auto-generated locally from the sanitized demo CSV
├── COMMUNITY_README.md           # Setup and usage guide for public audiences
├── PROJECT_CONTEXT.md            # This file
└── Jamf Reports/
    └── 97 Computers.csv          # Sanitized dummy-only CSV (96 devices; real device removed)
```

---

## Architecture

### Classes

| Class | Purpose |
|-------|---------|
| `Config` | Loads `config.yaml`, deep-merges with `DEFAULT_CONFIG`, validates |
| `ColumnMapper` | Resolves logical field names → actual CSV column names from config. `get(field)` returns column name or None. `extract(row, field)` returns cell value or `""` |
| `JamfCLIBridge` | Finds and calls `jamf-cli` via subprocess. Saves JSON output to `jamf-cli-data/{type}/`. Methods: `overview`, `security_report`, `policy_status`, `profile_status`, `patch_status`, `is_available` |
| `CoreDashboard` | Generates 4 sheets from **jamf-cli data only** (no CSV required): Fleet Overview, Security Posture, Policy Health, Patch Compliance. JSON shapes match actual jamf-cli v1.2.0 output. |
| `CSVDashboard` | Generates sheets from a Full Jamf Export CSV. Activated only when `--csv` is provided. Generates: Device Inventory, Stale Devices, Security Controls, Security Agents, Compliance, plus one sheet per `custom_eas` entry |
| `ChartGenerator` | Generates matplotlib PNG charts and embeds them in xlsx. Requires matplotlib (gracefully skipped if not installed). Supports: macOS adoption timeline, per-major OS breakdown, compliance trend stacked area. |

### Top-level functions

| Function | Purpose |
|----------|---------|
| `_safe_write(ws, row, col, value, fmt)` | Sanitizes cell values before writing to xlsx: handles None, NaN/inf, control chars, 32K char limit, formula injection (`=`, `+`, `-`, `@` prefixes) |
| `_parse_manager(raw)` | Parses AD Distinguished Names (`CN=SMITH\, JOHN,OU=...`) into readable names. Handles plain names and blank/NaN gracefully |
| `cmd_scaffold(csv_path, out_path)` | Reads CSV headers, fuzzy-matches to logical field names, writes starter `config.yaml` |
| `cmd_check(config, csv_path)` | Verifies jamf-cli auth and validates all configured column names against the actual CSV headers |
| `cmd_generate(config, csv_path, out_file, historical_csv_dir)` | Main entry point — builds xlsx, generates charts, embeds PNGs |

### CLI commands

```bash
python3 jamf-reports-community.py generate [--config config.yaml] [--csv export.csv] [--out-file report.xlsx] [--historical-csv-dir snapshots/]
python3 jamf-reports-community.py scaffold [--csv export.csv] [--out config.yaml]
python3 jamf-reports-community.py check [--csv export.csv]
```

### `--historical-csv-dir` usage

Point to a directory of dated CSV snapshots. Files must be named with a date in the
filename (`YYYY-MM-DD` or `YYYYMMDD`) or fall back to file mtime. With 2+ snapshots,
trend charts (line and stacked area) are generated. With a single snapshot, point charts
are generated (still useful as current-state distribution).

```bash
# Archive each run's CSV into a snapshot directory
cp "Jamf Export.csv" "snapshots/computers_$(date +%Y-%m-%d).csv"

# Generate report with trend charts
python3 jamf-reports-community.py generate --csv "Latest Export.csv" --historical-csv-dir snapshots/
```

---

## Config Structure

```yaml
columns:          # logical-name → actual CSV column name (includes mdm_expiry)
security_agents:  # list of {name, column, connected_value}
compliance:       # mSCP/custom baseline EA settings
custom_eas:       # list of {name, column, type, ...}
thresholds:       # stale_device_days, disk thresholds, cert_warning_days
output:           # default_format, output_dir
charts:           # chart generation config (see below)
```

### Charts config

```yaml
charts:
  enabled: true
  save_png: true           # save PNG files alongside the xlsx
  embed_in_xlsx: true      # add a "Charts" sheet with embedded images
  os_adoption:
    enabled: true
    per_major_charts: true # one chart per major macOS version
  compliance_trend:
    enabled: true
    bands:                 # customizable failure count buckets + colors
      - {label: "Pass", min_failures: 0, max_failures: 0, color: "#4472C4"}
      - {label: "Low (1-10)", min_failures: 1, max_failures: 10, color: "#2E9E7D"}
      # ...
```

Charts require the `operating_system` column (for adoption) and `compliance.failures_count_column` (for trend). matplotlib must be installed — gracefully skipped if missing.

### Custom EA types
- `boolean` — pass/fail with true_value, optional "Unknown/Not Reported" row
- `percentage` — distribution with warning/critical thresholds
- `version` — version distribution, optional current_versions list for status coloring
- `text` — value distribution table
- `date` — days-until-expiry, color-coded by proximity (uses `cert_warning_days` threshold)

---

## Test Environment

**Test CSV:** `Jamf Reports/97 Computers.csv` — sanitized dummy-only dataset with 96 devices.

**Key column names in the test CSV** (use these for testing scaffold and generate):

| Logical field | Test CSV column |
|--------------|----------------|
| computer_name | Computer Name |
| serial_number | Serial Number |
| operating_system | Operating System |
| last_checkin | Last Check-in |
| filevault | FileVault Status (note: NOT "FileVault 2 Status") |
| sip | System Integrity Protection |
| firewall | Firewall Enabled |
| secure_boot | Secure Boot Level (also "External Boot Level" exists) |
| bootstrap_token | Bootstrap Token Escrowed (also "Bootstrap Token Allowed") |
| disk_percent_full | Boot Drive Percentage Full (NOT "Boot Drive Available MB") |
| model | Model |
| last_enrollment | Last Enrollment |
| mdm_expiry | MDM Profile Expiration Date |

**Known scaffold mismatches in current `config.yaml`** (auto-generated, needs manual correction):
- `manager` mapped to "Managed" — wrong, should be blank or mapped to user field
- `secure_boot` mapped to "External Boot Level" — correct field exists but "Secure Boot Level" is also present and more appropriate
- `bootstrap_token` mapped to "Bootstrap Token Allowed" — "Bootstrap Token Escrowed" is the better field
- `disk_percent_full` mapped to "Boot Drive Available MB" — wrong, should be "Boot Drive Percentage Full"

The test CSV also has interesting EAs worth using for custom_eas testing:
- `McAfee Agent Version` — text type EA (security agent)
- `SysTrack Agent Version` / `SysTrack Install Status` — boolean/version type
- `KerberosSSO - password_expires_date` — date type
- `EC - adBound` — boolean (Active Directory binding status)
- `Apply All Updates - Date` — date type

---

## Known Issues / Incomplete Areas

### Fixed (no longer blocking)

- **`config.yaml` scaffold mismatches** — Fixed: `manager` cleared, `secure_boot`/`bootstrap_token`/`disk_percent_full` corrected. `check --csv` now validates all configured columns against actual CSV headers.
- **`Generated Reports/` auto-creation** — Already in `cmd_generate` at line ~1630.
- **`requirements.txt` missing** — Added: `xlsxwriter>=3.1`, `pandas>=2.0`, `pyyaml>=6.0`, `matplotlib>=3.7`.
- **`.gitignore` missing** — Added, excludes `config.yaml`, `jamf-cli-data/`, `Generated Reports/`, `__pycache__/`, `*.xlsx`, `.DS_Store`.
- **CoreDashboard JSON shape mismatches** — Fixed all three methods to match actual jamf-cli v1.2.0 output:
  - `_write_security`: parses section-discriminated array (`{"section":"summary","data":{...}}`)
  - `_write_policy`: parses `[{"summary":{...},"config_findings":[...]}]` envelope
  - `_write_patch`: uses `title`, `on_latest`, `on_other` field names (not `name`/`up_to_date`/`out_of_date`)
- **CSVDashboard not tested** — Tested against `97 Computers.csv` (96 rows, 93 columns). Generates Device Inventory, Stale Devices, Security Controls clean.

### Enhancement backlog (future sessions)

- **Trend analysis** — CSVDashboard currently works on a single CSV snapshot. Add support for a directory of historical CSVs to generate week-over-week trend sheets (pattern exists in v3.6's `FleetHealthDashboard._write_vulnerability_trends`)
- **PDF/PPTX export** — v3.6 has a `ReportExporter` class for this. A simplified version could be ported.
- **Teams webhook output** — A `--notify` flag that posts a summary card to a webhook URL.
- **jamf-cli `device` deep-dive integration** — `jamf-cli pro device <serial>` returns a rich per-device view. Could power a device lookup command.
- **GitHub Actions workflow** — A sample workflow that runs the report on a schedule and uploads the xlsx as an artifact or emails it.
- **Interactive scaffold** — Walk the user through mapping columns interactively rather than requiring manual YAML editing.
- **Multiple CSV support** — Some orgs export separate CSVs for computers, mobile devices, and users. Support merging them.

---

## Development Workflow for Future Sessions

### Starting a new session

1. Tell Claude: *"I'm working on the jamf-reports-community project at `/Users/alyoung/Documents/GitHub/jamf-reports-community/`. Read PROJECT_CONTEXT.md first."*
2. Read this file + `jamf-reports-community.py` (at minimum the class/function signatures).
3. Check which known issues to address or which backlog item to pick up.

### Testing

```bash
cd "/Users/alyoung/Documents/04_GitHub_Projects/jamf-reports-community"

# Verify it compiles
python3 -c "import py_compile; py_compile.compile('jamf-reports-community.py', doraise=True)"

# Regenerate scaffold from test CSV
python3 jamf-reports-community.py scaffold --csv "Jamf Reports/97 Computers.csv"

# Run check
python3 jamf-reports-community.py check --csv "Jamf Reports/97 Computers.csv"

# Generate report (CSV only, no jamf-cli needed)
python3 jamf-reports-community.py generate --csv "Jamf Reports/97 Computers.csv"
```

### Code style conventions in this file
- Python 3.9+, type hints on all method signatures
- Google-style docstrings on all classes and public methods
- Functions ≤100 lines — split into helpers if needed
- `_safe_write()` for all CSV-sourced cell writes (not static labels/headers)
- No hardcoded org-specific values anywhere
- Fail fast with clear, actionable error messages

---

## Relationship to v3.6 Production Script

The community script is **not** a stripped copy of v3.6. It was written fresh with different priorities:

| v3.6 | Community |
|------|-----------|
| CBP/Akima production tool | Generic, publicly shareable |
| ~11,000 lines | ~1,265 lines |
| Hardcoded EA column names | All column names in `config.yaml` |
| SharePoint CSV pipeline required | jamf-cli only is sufficient |
| 17 Excel sheets | 4–10 sheets depending on config |
| No scaffold/setup tooling | `scaffold` and `check` commands |

Patterns shared between both (can reference v3.6 for implementation ideas):
- `JamfCLIBridge` pattern (subprocess wrapper + JSON save)
- `_safe_write()` sanitization approach
- `_parse_manager()` AD DN parsing
- Certificate expiration sheet design
- Tiered collection via `collect.zsh` + LaunchAgent

---

## Pre-Publication Checklist

- [x] Fix four scaffold mismatches in `config.yaml`
- [x] Test `generate` against `97 Computers.csv` end-to-end
- [x] `Generated Reports/` directory auto-creation — already in code
- [x] Add `requirements.txt`
- [x] Add `.gitignore`
- [x] Test `scaffold` → `check` → `generate` workflow on a clean run (all pass)
- [x] Fix CoreDashboard JSON parsing for jamf-cli v1.2.0 actual output shapes
- [x] Add `ChartGenerator` class (matplotlib PNG + xlsx embed)
- [x] Add `--historical-csv-dir` CLI flag for trend charts
- [x] `check --csv` now validates all configured columns, not just 4 required fields
- [x] `config.yaml` excluded from git via `.gitignore` — `config.example.yaml` is the template
- [x] Rewrite `COMMUNITY_README.md` — accurate to actual CLI flags, config keys, and sheet inventory
- [x] Rewrite `config.example.yaml` — all keys match DEFAULT_CONFIG and actual EA handler code
- [ ] Test chart generation with a real historical snapshot directory (≥2 CSVs)
- [ ] Create GitHub repository and initial commit
