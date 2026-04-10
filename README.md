# jamf-reports community edition

Config-driven macOS fleet reporting for Jamf Pro. Generates formatted Excel workbooks from
a Jamf Pro CSV export — no Power BI, no custom infrastructure, no hardcoded credentials.

Long-form setup and operations docs live in the [project wiki](https://github.com/tonyyo11/jamf-reports-community/wiki).

---

## What This Is

A single Python script (`jamf-reports-community.py`) that reads a YAML config file and
produces a multi-sheet Excel workbook covering:

- Device inventory and stale device tracking
- Security controls summary (FileVault, SIP, firewall, Gatekeeper, secure boot, bootstrap token)
- Third-party security agent installation rates (CrowdStrike, SentinelOne, Splunk, etc.)
- mSCP compliance results (failed-rule counts and per-device detail)
- Custom EA-driven sheets (disk usage, certificate expiry, version tracking, and more)
- macOS adoption charts (PNG files embedded in the workbook)

Everything is config-driven: you edit `config.yaml` to match your Jamf Pro column names
and the script handles the rest.

**jamf-cli is optional.** The full report generates from a CSV export alone. jamf-cli
integration adds live fleet, mobile-device visibility, EA discovery, software inventory,
and patch/compliance sheets for orgs that want them. There is also an opt-in,
experimental `Protect Overview` sheet for Jamf Protect environments.

**Test scope:** this project is built and tested against Jamf Pro. Jamf Protect support is
new, opt-in, and based on the `jamf-cli 1.6` command surface, but it has not been fully
validated against a live Protect tenant yet.

**Open source direction:** this repo is intentionally meant to be extended. If your
environment needs Jamf Protect, future Jamf Platform API data, deeper EA visualizations,
or more opinionated compliance views, fork it and iterate.

---

## Prerequisites

**Python 3.9 or later**

```
python3 --version
```

**Python packages**

```
pip install xlsxwriter pandas pyyaml
```

Or using `uv` (faster):

```
uv pip install xlsxwriter pandas pyyaml
```

**matplotlib** (optional — required only for chart generation)

```
pip install matplotlib
```

If matplotlib is not installed, the script runs normally and skips chart generation.

**jamf-cli v1.2.0 or later** (optional — required only for live API, EA discovery, and software sheets)

jamf-cli is a command-line interface for Jamf Pro. If you want the live API sheets, install
it and run:

```
jamf-cli pro setup --url https://jamf.example.com
```

Follow the prompts to enter your API client ID and client secret. If jamf-cli is not
installed or not authenticated, those sheets are silently skipped and the rest of the
report is unaffected. Older jamf-cli builds may also lack some report subcommands; those
sheets are skipped automatically with a clear message. If you keep saved jamf-cli JSON
snapshots, the script can also reuse those as an offline cache.

jamf-cli v1.2.0 is the minimum version that supports `app-status` and `update-status`.
Builds before 1.2.0 will skip those sheets with a clear skip message.

If you also want the experimental Jamf Protect sheet, use `jamf-cli 1.6.0+`, configure
Protect separately, and then opt in from `config.yaml`:

```bash
jamf-cli protect setup
```

```yaml
protect:
  enabled: true
```

When `protect.enabled` is true, the workbook attempts to build a `Protect Overview` sheet
from `jamf-cli protect overview`, `protect computers list`, `protect analytics list`, and
`protect plans list`. This path is intentionally defensive and will skip cleanly if
Protect auth or commands are unavailable.

If you use multiple jamf-cli profiles, set `jamf_cli.profile` in `config.yaml` to the
profile name you want this report to target. This is the same profile selected with
`jamf-cli -p <name> ...`.

If a specific tenant has trouble with live overview collection, you can set
`jamf_cli.allow_live_overview: false` to force Fleet Overview to use cached JSON only.

**Jamf Pro API permissions required for jamf-cli**

The API client used by jamf-cli needs the following Jamf Pro API roles:

| Resource | Privileges needed |
|----------|------------------|
| Computers | Read |
| Mobile Devices | Read |
| Mobile Device Configuration Profiles | Read |
| Computer Extension Attributes | Read |
| Policies | Read |
| Patch Management | Read |
| Mobile Device Applications | Read |
| Managed Software Updates | Read |
| Computer Groups | Read |

Minimum recommended role: create a dedicated API role with the permissions above.
Do not use a full-administrator API client for scheduled reporting.

All config-managed paths are resolved relative to `config.yaml`, not your current shell
directory. That means you can keep a self-contained reports workspace if you want:

```
Jamf Reports/
├── config.yaml
├── jamf-cli-data/
├── snapshots/
└── Generated Reports/
```

The community tool supports that layout, but does not require it.

Use `python3 jamf-reports-community.py ...` in examples and automation.

---

## Quick Start

### Step 1 — Export your Jamf Pro computer inventory

In Jamf Pro, go to **Computers > Search Inventory**, run an All Computers search, and
export to CSV. Include all Extension Attributes in the export.

If you want to reduce reliance on Advanced Search exports, you can also build a baseline
inventory CSV from live `jamf-cli` data:

```
python3 jamf-reports-community.py inventory-csv
```

That export uses `jamf-cli pro computers list` plus `jamf-cli pro report ea-results --all`
to create a wide CSV with one row per computer and one column per EA.

The generated baseline CSV also attempts to add generic security posture columns from
`jamf-cli pro device`, including FileVault, SIP, firewall, Gatekeeper, and bootstrap
token states. That means a scaffolded config from `inventory-csv` can now populate the
CSV-driven `Security Controls` sheet without requiring a Jamf UI export.

Before relying on jamf-cli-driven commands, validate the profile you expect to use:

```bash
jamf-cli config validate -p yourprofile
```

`inventory-csv` and `collect` require working live jamf-cli auth. `generate` can reuse
saved JSON snapshots when `jamf_cli.use_cached_data: true`.

If you later run `generate` or `collect` with jamf-cli available, the workbook can also
include live EA coverage, EA definition metadata, software install distribution, device
compliance, inventory summary, and other API-driven sheets alongside the CSV analysis.

### Step 2 — Generate a starter config

```
python3 jamf-reports-community.py scaffold --csv "your_export.csv"
```

This reads your CSV headers and writes a `config.yaml` with best-guess column mappings
pre-filled. Review it and correct any columns it could not auto-detect.

### Step 3 — Validate your config (recommended)

```
python3 jamf-reports-community.py check --csv "your_export.csv"
```

This confirms every column name in `config.yaml` exists in your CSV and warns about common
semantic mistakes such as mapping `columns.manager` to Jamf's `Managed` status column.
Fix any mismatches or warnings before generating the report.

### Step 4 — Generate the report

```
python3 jamf-reports-community.py generate --csv "your_export.csv"
```

The report is written to `Generated Reports/` by default, relative to `config.yaml`.
Generated workbooks and PNGs are timestamped by default so each run is preserved as a
separate point-in-time artifact.

### Step 5 — Optional: collect snapshots for offline runs and trends

```
python3 jamf-reports-community.py collect --csv "your_export.csv"
```

This refreshes live `jamf-cli` JSON snapshots when auth is working and can also archive
the current CSV into `charts.historical_csv_dir` for trend charts. `collect` is the best
way to build an append-only historical store for later weekly and monthly reporting.

### Step 6 — Optional: bootstrap a per-profile workspace

If you support more than one Jamf tenant or more than one `jamf-cli` profile, create one
workspace per tenant before you automate anything.

```bash
python3 jamf-reports-community.py workspace-init \
    --profile yourprofile \
    --workspace-root ~/Jamf-Reports
```

That creates a profile-scoped folder tree such as:

- `config.yaml`
- `jamf-cli-data/`
- `snapshots/`
- `Generated Reports/`
- `csv-inbox/`
- `automation/logs/`

By default, the generated `config.yaml` resets path-bearing settings back to local
workspace-relative defaults so each tenant’s data stays isolated.

### Step 7 — Optional: automate collection and reporting with a LaunchAgent

If you want trend lines to improve over time, automate the collection cadence first.
`launchagent-setup` creates a macOS LaunchAgent that runs in the same user context as
your `jamf-cli` profile and config, which keeps scheduled reporting aligned with the
same keychain-backed and XDG-configured environment you use interactively.

Recommended pattern for MSPs and multi-tenant admins:

- one `jamf-cli` profile per tenant
- one `config.yaml` per tenant
- one reporting workspace per tenant
- one LaunchAgent per tenant

If `jamf_cli.profile` is set but your paths still use generic shared defaults such as
`jamf-cli-data`, `snapshots`, or `Generated Reports`, `check` and `launchagent-setup`
now print profile-isolation guidance so you can avoid mixing tenant data.

That separation keeps `jamf-cli-data/`, CSV inboxes, historical snapshots, and generated
reports from mixing across customers.

```bash
python3 jamf-reports-community.py launchagent-setup --config config.yaml
```

The setup command can build these workflow types:

- `snapshot-only` — refresh jamf-cli snapshots and optional CSV history only
- `jamf-cli-only` — generate a workbook from live or cached jamf-cli data
- `jamf-cli-full` — build a jamf-cli baseline CSV, refresh snapshots, and generate a workbook
- `csv-assisted` — prefer the newest CSV in an inbox folder and fall back to jamf-cli-only

Schedules currently support `daily`, `weekdays`, `weekly`, and `monthly`.

Reference guidance:

- [jamf-cli Setup Guide](https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide)
- [jamf-cli Configuration & Profiles](https://github.com/Jamf-Concepts/jamf-cli/wiki/Configuration-&-Profiles)
- [jamf-cli Secrets & Keychain](https://github.com/Jamf-Concepts/jamf-cli/wiki/Secrets-&-Keychain)
- [Wiki: LaunchAgent Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/07-LaunchAgent-Automation)

---

## CLI Reference

```
python3 jamf-reports-community.py <command> [options]
```

### `generate` — Build the report workbook

```
python3 jamf-reports-community.py generate \
    [--config config.yaml] \
    [--csv export.csv] \
    [--out-file report.xlsx] \
    [--historical-csv-dir snapshots/]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--config` | `config.yaml` | Path to config file |
| `--csv` | none | Path to Jamf Pro CSV export (enables CSV sheets) |
| `--out-file` | auto-named | Output path for the xlsx file. Timestamp appended by default if needed |
| `--historical-csv-dir` | none | Directory of dated CSV snapshots for trend charts |

If you omit `--csv`, the workbook is built from jamf-cli data only.

Examples:

```bash
# Mixed workbook: create a baseline CSV, then build jamf-cli sheets plus CSV sheets
python3 jamf-reports-community.py inventory-csv --config config.yaml --out-file inventory.csv
python3 jamf-reports-community.py generate --config config.yaml --csv inventory.csv

# jamf-cli-only workbook
python3 jamf-reports-community.py generate --config config.yaml --out-file jamf_report_jamf_cli_only.xlsx
```

### `collect` — Save jamf-cli snapshots and optional CSV history

```
python3 jamf-reports-community.py collect \
    [--config config.yaml] \
    [--csv export.csv] \
    [--historical-csv-dir snapshots/]
```

Uses live `jamf-cli` commands to refresh saved JSON snapshots in `jamf_cli.data_dir`.
If `--csv` and a historical snapshot directory are available, it also archives the CSV
for future trend analysis. This is the best command to schedule if you want offline
report generation later. Snapshot collection includes EA coverage, EA definitions, and
software install distribution when the installed jamf-cli build supports them. The saved
JSON files are already timestamped; the generated report outputs can also auto-archive
older runs out of the active output folder.

### `inventory-csv` — Export a wide inventory CSV from jamf-cli

```
python3 jamf-reports-community.py inventory-csv \
    [--config config.yaml] \
    [--out-file inventory.csv]
```

Builds a local CSV from live Jamf Pro data using `jamf-cli pro computers list` plus
`jamf-cli pro report ea-results --all`. This is the easiest way to feed the existing
`scaffold`, `check`, and `generate` flow without hand-building a Jamf Advanced Search.

This is a baseline export, not a perfect clone of every Jamf Pro CSV shape. It depends on
computer names being unique so EA values can be joined back to device rows safely.

The export is intentionally based on the lightweight `computers list` surface, so it is
best for bootstrap and general inventory reporting. It is not a full replacement for
every possible Jamf Pro Advanced Search or every per-device field exposed by `jamf-cli
pro device`.

`inventory-csv` is a live-auth path. Unlike `generate`, it does not reuse cached JSON
snapshots when jamf-cli auth is broken.

Because the command now enriches each computer with `jamf-cli pro device` security
details, it can take noticeably longer on larger fleets than a plain `computers list`
export. The payoff is that scaffolded configs can auto-map FileVault, SIP, firewall,
Gatekeeper, and bootstrap-token columns directly from the generated CSV.

If you want later commands to use `--csv inventory.csv`, create it explicitly with
`inventory-csv --out-file inventory.csv`. If you omit `--out-file`, the export is written
to `Generated Reports/` using the configured timestamp behavior.

### `workspace-init` — Create a per-profile workspace skeleton

```bash
python3 jamf-reports-community.py workspace-init \
    [--seed-config config.yaml] \
    [--profile yourprofile] \
    [--workspace-root ~/Jamf-Reports] \
    [--workspace-name acme-prod]
```

This command creates a new workspace directory for one tenant/profile and writes a seeded
`config.yaml`. If `--seed-config` exists, that config is cloned first. Otherwise the
command falls back to `config.example.yaml`.

Use it when:

- you manage multiple Jamf Pro tenants
- you want one reporting workspace per `jamf-cli` profile
- you want `jamf-cli-data/`, `snapshots/`, and `Generated Reports/` separated by tenant

Examples:

```bash
# Create a fresh tenant workspace from config.example.yaml
python3 jamf-reports-community.py workspace-init \
    --profile acme-prod \
    --workspace-root ~/Jamf-Reports

# Clone an existing config into a new per-profile workspace
python3 jamf-reports-community.py workspace-init \
    --seed-config ~/Jamf-Reports/shared-template.yaml \
    --profile school-west \
    --workspace-root ~/Jamf-Reports
```

### `launchagent-setup` — Create a scheduled LaunchAgent on macOS

```bash
python3 jamf-reports-community.py launchagent-setup \
    [--config config.yaml] \
    [--mode csv-assisted] \
    [--schedule weekdays] \
    [--time-of-day 07:00]
```

This interactive setup command writes a LaunchAgent plist, creates log and status-file
paths, and points the job back at `launchagent-run` with absolute paths for the script,
config, and optional CSV inbox/history folders.

Why use it:

- scheduled `collect` and `generate` runs build better historical data over time
- LaunchAgents keep automation scoped to the same macOS user account that owns the
  `jamf-cli` profile and config
- `csv-assisted` can consume emailed Jamf exports from a folder but still fall back to
  jamf-cli-only output when no fresh CSV is present

Examples:

```bash
# Interactive setup with prompts
python3 jamf-reports-community.py launchagent-setup --config config.yaml

# Weekday report run with a CSV inbox fallback
python3 jamf-reports-community.py launchagent-setup \
    --config config.yaml \
    --mode csv-assisted \
    --schedule weekdays \
    --time-of-day 07:15 \
    --csv-inbox-dir ~/JamfReports/inbox

# Month-start history collection without generating a workbook
python3 jamf-reports-community.py launchagent-setup \
    --config config.yaml \
    --mode snapshot-only \
    --schedule monthly \
    --day-of-month 1 \
    --time-of-day 06:00
```

### `launchagent-run` — Internal scheduled runner

Generated LaunchAgents call `launchagent-run`. It is safe to run manually when
troubleshooting, but most users should use `launchagent-setup` and let it compose the
correct arguments.

### `scaffold` — Generate a starter config from your CSV

```
python3 jamf-reports-community.py scaffold \
    [--csv export.csv] \
    [--out config.yaml]
```

Reads CSV headers, fuzzy-matches them to known field names, and writes a `config.yaml`
with best-guess mappings. Safe to run multiple times — overwrites the existing file.

For common compliance exports, scaffold also tries to populate
`compliance.failures_count_column` and `compliance.failures_list_column`, and it treats
headers such as `Last Inventory Update` as a valid `last_checkin` match.

### `check` — Validate config against CSV

```
python3 jamf-reports-community.py check [--csv export.csv]
```

Verifies every column name in `config.yaml` exists in the CSV. Reports missing columns
with suggestions. Also verifies jamf-cli authentication if available.

---

## What Gets Generated

Sheets appear only when the required config and data are present.

| Sheet | Requires | Description |
|-------|----------|-------------|
| Device Inventory | `--csv`, `columns` | All active devices with OS, model, last check-in |
| Stale Devices | `--csv`, `columns.last_checkin` | Devices not checked in within `stale_device_days` |
| Security Controls | `--csv`, `columns` | FileVault, SIP, firewall, Gatekeeper, secure boot, bootstrap token rates |
| Security Agents | `--csv`, `security_agents` | Per-agent install rate; missing-agent device list |
| Compliance | `--csv`, `compliance` | Failed rule counts per device; top failing rules |
| Custom EA sheets | `--csv`, `custom_eas` | One sheet per entry |
| Charts | matplotlib plus CSV or jamf-cli history | PNG charts embedded in workbook, including CSV trend charts and jamf-cli-only adoption/device-state charts |
| Fleet Overview | jamf-cli | Live device and OS summary from API |
| Mobile Fleet Summary | jamf-cli | Mobile-device counts, ownership signals, and family/OS breakdown |
| Security Posture | jamf-cli | FileVault/SIP/firewall rates from API |
| Inventory Summary | jamf-cli | Model and OS breakdown from API |
| Mobile Inventory | jamf-cli | iPhone/iPad inventory detail from Jamf Pro mobile-device endpoints |
| Device Compliance | jamf-cli | Managed vs unmanaged and stale-check-in triage |
| EA Coverage | jamf-cli | Fleet-wide EA population, coverage %, and top values |
| EA Definitions | jamf-cli | EA metadata such as type, input source, and display mode |
| Software Installs | jamf-cli | Application version distribution across devices |
| Policy Health | jamf-cli | Policy count, config findings |
| Profile Status | jamf-cli | Config profile deployment errors by profile and device |
| Mobile Config Profiles | jamf-cli | Mobile configuration profile list and category distribution |
| App Status | jamf-cli v1.2.0+ | Managed app deployment failures by app and device |
| Patch Compliance | jamf-cli | Per-title patch compliance percentages |
| Update Status | jamf-cli v1.2.0+ | Managed software update status summary and error device list |
| Report Sources | always when data exists | Declares whether each sheet came from jamf-cli, CSV, or charts |

---

## Configuration Guide

Copy `config.example.yaml` to `config.yaml`. Every field has an inline comment.

### `columns`

Maps logical field names to your actual CSV column headers.

```yaml
columns:
  computer_name: "Computer Name"
  serial_number: "Serial Number"
  operating_system: "Operating System Version"
  last_checkin: "Last Check-in"
  department: "Department"
  email: "Email Address"
  filevault: "FileVault 2 - Status"
  sip: "System Integrity Protection"
  firewall: "Firewall Enabled"
  gatekeeper: "Gatekeeper"
  secure_boot: "Secure Boot Level"
  bootstrap_token: "Bootstrap Token Escrowed"
  disk_percent_full: "Boot Drive Percentage Full"
```

Required: `computer_name`, `serial_number`. All others are optional — leave blank or omit
to skip the corresponding feature.

For `manager`, use a real manager EA or directory-derived field. Do not map it to Jamf's
built-in `Managed` / `Unmanaged` status column.

### `security_agents`

A list of third-party security tools to track. Each entry drives a row in the Security
Agents sheet.

```yaml
security_agents:
  - name: "CrowdStrike Falcon"
    column: "CrowdStrike Falcon - Status"
    connected_value: "Installed"

  - name: "SentinelOne"
    column: "SentinelOne - Agent Status"
    connected_value: "running"
```

`connected_value` is matched case-insensitively as a substring of the EA cell value.

### `jamf_cli`

Controls where jamf-cli JSON snapshots are stored and whether cached snapshots are reused.

```yaml
jamf_cli:
  data_dir: "jamf-cli-data"
  profile: ""
  use_cached_data: true
  allow_live_overview: true
```

The community default is a plain `jamf-cli-data/` folder next to the script. If you prefer
your production-style layout, point `data_dir` at that directory instead. Relative paths
resolve from the folder containing `config.yaml`. When you switch between multiple
jamf-cli profiles, set `profile` and use a profile-specific `data_dir` to keep cached
snapshots from different tenants separate. Set `allow_live_overview: false` only if you
want Fleet Overview to rely on cached JSON for a specific environment.

### `compliance`

Single compliance framework (e.g., mSCP NIST or DISA STIG). Requires a failed-count EA
column and a pipe-delimited failed-list EA column.

```yaml
compliance:
  enabled: true
  baseline_label: "NIST 800-53r5 Moderate"
  failures_count_column: "Compliance - Failed mSCP Results Count - NIST 800-53r5"
  failures_list_column: "Compliance - Failed mSCP Result List - NIST 800-53r5"
```

Set `enabled: false` to skip the Compliance sheet entirely.

### `custom_eas`

A list of additional sheets, each driven by one EA column.

#### boolean — Yes/No or Enabled/Disabled

```yaml
- name: "FileVault Status"
  column: "FileVault 2 - Status"
  type: boolean
  true_value: "Encrypted"
```

`true_value` is the string that means "compliant". Devices with any other non-empty value
are flagged.

#### percentage — Numeric 0–100

```yaml
- name: "Disk Usage"
  column: "Boot Drive Percentage Full"
  type: percentage
  warning_threshold: 80
  critical_threshold: 90
```

Devices above `critical_threshold` are highlighted red; above `warning_threshold`, yellow.
Both default to `thresholds.warning_disk_percent` and `thresholds.critical_disk_percent`
if not set here.

#### version — Version strings

```yaml
- name: "macOS Version"
  column: "Operating System Version"
  type: version
  current_versions:
    - "15.4"
    - "15.3.2"
```

Generates a version frequency table. Devices not in `current_versions` are flagged.

#### text — Free-form strings

```yaml
- name: "Patch Agent Status"
  column: "Patch Management - Agent Status"
  type: text
```

Generates a frequency table of all unique values in the column.

#### date — Date strings

```yaml
- name: "Identity Certificate Expiration"
  column: "Identity Certificate - Expiration Date"
  type: date
  warning_days: 60
```

Flags devices where the date is past (expired) or within `warning_days` days (expiring
soon). Defaults to `thresholds.cert_warning_days` if `warning_days` is not set.

### `thresholds`

```yaml
thresholds:
  stale_device_days: 30      # Days since last check-in before a device is "stale"
  warning_disk_percent: 80   # Default yellow threshold for disk usage
  critical_disk_percent: 90  # Default red threshold for disk usage
  cert_warning_days: 90      # Default expiry warning window (days)
```

### `output`

```yaml
output:
  output_dir: "Generated Reports"  # Directory for generated files
  timestamp_outputs: true          # Append timestamps to user-specified output names
  archive_enabled: true            # Move older runs into an archive folder
  archive_dir: ""                  # Blank = use an archive folder next to the output
  keep_latest_runs: 10             # Keep this many recent runs per report family
```

### `charts`

Requires `matplotlib`. Charts are saved as PNG files alongside the xlsx and embedded in a
Charts sheet inside the workbook.

```yaml
charts:
  enabled: true
  save_png: true
  embed_in_xlsx: true
  historical_csv_dir: "snapshots"
  archive_current_csv: true

  os_adoption:
    enabled: true
    per_major_charts: true   # One chart per major macOS version (10, 11, 12, …)

  compliance_trend:
    enabled: true            # Requires compliance.failures_count_column
    bands:
      - {label: "Pass",            min_failures: 0,  max_failures: 0,    color: "#4472C4"}
      - {label: "Low (1-10)",      min_failures: 1,  max_failures: 10,   color: "#2E9E7D"}
      - {label: "Med-Low (11-30)", min_failures: 11, max_failures: 30,   color: "#FFCA30"}
      - {label: "Medium (31-50)",  min_failures: 31, max_failures: 50,   color: "#F07C21"}
      - {label: "High (>50)",      min_failures: 51, max_failures: 9999, color: "#C0392B"}

  device_state_trend:
    enabled: true            # jamf-cli device-compliance history
```

#### Trend charts with historical snapshots

Pass `--historical-csv-dir` pointing to a directory of dated CSV snapshots to generate
trend lines showing change over time. One archived CSV equals one historical point, so
your weekly or monthly cadence directly determines chart granularity.

```
# Archive each run's export with a timestamp
cp "Jamf Export.csv" "snapshots/computers_$(date +%Y-%m-%d_%H%M%S).csv"

# Generate report with trend charts
python3 jamf-reports-community.py generate \
    --csv "Jamf Export.csv" \
    --historical-csv-dir snapshots/
```

Or configure it in `config.yaml`:

```yaml
charts:
  historical_csv_dir: "snapshots"
  archive_current_csv: true
```

With `archive_current_csv: true`, each `generate --csv ...` run copies the current export
into the historical snapshot directory using a date/time-stamped filename. Snapshot
filenames must contain a date in `YYYY-MM-DD`, `YYYYMMDD`, `YYYY-MM-DD_HHMMSS`, or
`YYYY-MM-DDTHHMMSS` format. The script scans subfolders recursively and ignores CSV files
that do not contain the configured chart columns.

#### Cached jamf-cli snapshots

If you want the core jamf-cli sheets to keep working even when live auth breaks, leave
`jamf_cli.use_cached_data: true` and keep saved JSON snapshots in `jamf_cli.data_dir`.
The script uses the newest matching snapshot per report and logs when cached data is used.
The OS adoption chart can also use `inventory-summary` history, and the device state trend
chart can use `device-compliance` history, so jamf-cli-only reporting no longer depends on
CSV history for every chart.

---

## Adapting Column Names

Jamf Pro column names vary between instances because Extension Attributes are named by
whoever created them. If your EA names differ from the examples in `config.example.yaml`,
there are two ways to fix this:

**Option 1 — Scaffold (recommended)**

```
python3 jamf-reports-community.py scaffold --csv "your_export.csv"
python3 jamf-reports-community.py check --csv "your_export.csv"
```

The scaffold command auto-detects column names. The check command confirms every name
it found actually exists in your CSV.

**Option 2 — Manual edit**

Open your CSV in any spreadsheet app, find the exact header text for the field you need,
and paste it as the value in `config.yaml`. Column names are case-sensitive and must match
exactly, including spaces and punctuation.

```yaml
# Wrong — will produce "column not found" warning:
column: "crowdstrike falcon status"

# Correct — matches the actual CSV header:
column: "CrowdStrike Falcon - Status"
```

---

## Troubleshooting

**`Error: no config file found`**

No `config.yaml` in the current directory. Copy the example or run scaffold:

```
cp config.example.yaml config.yaml
# — or —
python3 jamf-reports-community.py scaffold --csv "your_export.csv"
```

**`Column not found: "..."`**

The column name in `config.yaml` does not match your CSV. Run:

```
python3 jamf-reports-community.py check --csv "your_export.csv"
```

It will list every mismatch and suggest corrections.

**`ModuleNotFoundError: No module named 'xlsxwriter'`**

```
pip install xlsxwriter pandas pyyaml
```

**`No active devices found`**

All devices were filtered out by the `stale_device_days` threshold. Either your CSV is
stale (re-export from Jamf) or the threshold needs adjustment:

```yaml
thresholds:
  stale_device_days: 60   # increase to include older check-ins
```

**Charts are missing from the workbook**

matplotlib is not installed. Run `pip install matplotlib`, then regenerate.

**`jamf-cli: command not found`** or **`jamf-cli not available`**

The script falls back to CSV-only mode. All jamf-cli sheets are skipped. All CSV-driven
sheets still generate normally.

**jamf-cli auth failures / `[skip]` on multiple Core Dashboard sheets**

If several Core Dashboard sheets are skipped with auth-related errors, check:

1. Run `jamf-cli config validate -p yourprofile` to confirm the expected profile resolves.
2. Run `jamf-cli --profile yourprofile pro overview` directly to confirm the API path works.
3. If the API client token has expired, re-authenticate: `jamf-cli pro setup --url https://jamf.example.com`
4. If auth is intermittently failing (e.g., scheduled runs overnight), set
   `jamf_cli.use_cached_data: true` — the script will fall back to the most recent
   saved JSON snapshot for each sheet that fails live collection.
5. If the Jamf Pro server is temporarily unreachable, cached data avoids a fully blank
   workbook. Snapshots are labeled with their age in the sheet header.

`inventory-csv` remains live-only, so it will still fail until jamf-cli auth is fixed.

**Stale snapshots in jamf-cli-data/**

Each report command saves a new timestamped JSON file. The script always uses the
newest file it finds. If a snapshot looks unexpectedly old:

- Run `collect` to refresh: `python3 jamf-reports-community.py collect`
- Verify `jamf_cli.data_dir` in `config.yaml` points to the right folder.
- If using multiple profiles, confirm `jamf_cli.profile` matches the profile that has
  current auth, and that `data_dir` is profile-specific so snapshots don't mix.

**Duplicate computer names in inventory-csv output**

`inventory-csv` joins EA values to device rows by computer name. If two devices share
the same name, the export aborts with an error. Resolve duplicate names in Jamf Pro
before re-running, or use the Jamf Pro Advanced Search CSV export path instead.

**`[skip] App Status: jamf-cli report 'app-status' is not available`** or same for `update-status`

Your installed jamf-cli build predates v1.2.0. Upgrade jamf-cli to 1.2.0 or later to
enable those sheets. The rest of the report is unaffected.

---

## Getting Help

Open an issue on the project's GitHub repository. Include:

- The full error message
- The relevant section of `config.yaml` (redact any sensitive values)
- Output of `python3 --version` and `pip show xlsxwriter`
- Output of `python3 jamf-reports-community.py check --csv "your_export.csv"` if the
  issue is column-mapping related
