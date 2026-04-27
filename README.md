# jamf-reports community edition

Config-driven macOS fleet reporting for Jamf Pro. Generates formatted Excel workbooks from
a Jamf Pro CSV export — no Power BI, no custom infrastructure, no hardcoded credentials.

This tool is featured in the [jamf-cli Community Showcase](https://github.com/Jamf-Concepts/jamf-cli/wiki/Community-Showcase).

## macOS App (preview)

A native SwiftUI macOS application is currently in development on the `dev-app/2.0`
branch. This GUI wraps the core CLI logic into a multi-profile workspace manager
with a dedicated **Historical Trends** dashboard built on Swift Charts. Full
details and build instructions are in [app/README.md](app/README.md).

The app requires Xcode 16+ to build from source and can be packaged as a
standalone bundle via `cd app && ./build-app.sh release`. Note that while local
builds are ad-hoc signed, wider distribution requires a Developer ID signature
and notarization (not yet integrated into the release workflow).

<!-- TODO: screenshot -->

Long-form setup and operations docs live in the [project wiki](https://github.com/tonyyo11/jamf-reports-community/wiki).

Automated testing docs and fixture guidance live in [docs/testing.md](docs/testing.md).

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
experimental `Protect Overview` sheet for Jamf Protect environments and preview Platform
API sheets for blueprints, benchmark compliance, and DDM status.

**Test scope:** this project is built and tested against Jamf Pro. Jamf Protect support is
new, opt-in, and based on the `jamf-cli 1.6` command surface, but it has not been fully
validated against a live Protect tenant yet. Platform API support is also preview-only
and depends on a jamf-cli build that exposes the new `pro report` platform commands.

**Open source direction:** this repo is intentionally meant to be extended. If your
environment needs Jamf Protect, Jamf Platform API data, deeper EA visualizations, or more
opinionated compliance views, fork it and iterate.

**Committed test data:** the automated tests use committed fixtures under `tests/fixtures/`.
Those fixtures are derived from Jamf-provided fake/demo data from the local `Dummy/` and
`Harbor/` workspaces, not production or customer data.

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

jamf-cli is a command-line interface for Jamf Pro. Documentation and setup guides are at
the [jamf-cli wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki). If you want the live
API sheets, install it and run:

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

If you also want the preview Platform API sheets, use a jamf-cli build that exposes these
commands under `jamf-cli pro report`:

- `blueprint-status`
- `compliance-rules`
- `compliance-devices`
- `ddm-status`

Then opt in from `config.yaml`:

```yaml
platform:
  enabled: true
  compliance_benchmarks:
    - "CIS Level 1"
```

When `platform.enabled` is true, the workbook attempts to build `Platform Blueprints`,
`Platform DDM Status`, and, when `platform.compliance_benchmarks` contains one or more
entries, benchmark-specific `Platform Compliance Rules` and `Platform Compliance Devices`
sheets. This path is also defensive and will skip cleanly if Platform auth or report
commands are unavailable.

The [Jamf Platform API](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api)
is currently in public beta. This tool accesses it only through jamf-cli's preview
`pro report` commands — it does not call the Platform API directly. Admins should review
it, as it may affect future integrations and tooling in this space as it matures.

If you use multiple jamf-cli profiles, set `jamf_cli.profile` in `config.yaml` to the
profile name you want this report to target. This is the same profile selected with
`jamf-cli -p <name> ...`.

You can also pass `--profile <name>` to Jamf Pro commands such as `generate`, `collect`,
`html`, `inventory-csv`, `backup`, `check`, `device`, and `patch-managed`. That override
is process-local and takes precedence over `jamf_cli.profile` in the config file.

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

## Try It Offline

You do not need a live Jamf tenant, local `Dummy` or `Harbor` workspaces, or your own
CSV export to preview the project. The repo includes committed demo fixtures that can
generate offline reports immediately.

Run every offline demo report:

```bash
./scripts/demo.sh
```

Or generate a specific demo:

```bash
./scripts/demo.sh html
./scripts/demo.sh xlsx
./scripts/demo.sh mobile
./scripts/demo.sh school
```

By default the script writes output to `Generated Reports/demo/` in the repo root.
Pass a second argument to override that directory:

```bash
./scripts/demo.sh all /tmp/jrc-demo
```

The demo runner uses only committed fixture files from `tests/fixtures/`:

- `html` builds a self-contained Jamf Pro HTML report from cached `jamf-cli` JSON
- `xlsx` builds the Jamf Pro jamf-cli workbook from cached `jamf-cli` JSON
- `mobile` builds a mobile-device workbook from a committed CSV export
- `school` builds a Jamf School workbook from a committed CSV export

This is intended as the supported no-credentials preview path for the community repo.

---

## Automated Tests

Install dev dependencies:

```bash
pip install -r requirements-dev.txt
```

Run the automated suite:

```bash
python3 -m pytest tests -q
```

Or use the repo wrapper:

```bash
./scripts/test.sh
```

The committed fixture corpus is intentionally curated rather than keeping full timestamped
workspace histories in git. See [docs/testing.md](docs/testing.md) for fixture provenance,
refresh workflow, and how to add fresh dated snapshots for historical-trend testing.

If you want pushes to run the local test gate automatically, enable the repo-managed hook:

```bash
git config core.hooksPath .githooks
```

That installs the committed `pre-push` hook, which runs `./scripts/test.sh` before git
push completes.

---

## Releases

Keep `main` as the full source repository, including `tests/` and `docs/`. For end-user
downloads, build a smaller release bundle that contains just the runtime files:

- `jamf-reports-community.py`
- `requirements.txt`
- `config.example.yaml`
- `CHANGELOG.md`
- `README.md`

Track user-visible changes in [CHANGELOG.md](CHANGELOG.md). Update the `Unreleased`
section as part of normal development, then cut a versioned entry when you tag a release.

Build that zip locally with:

```bash
./scripts/build-release.sh v1.0.0
```

The script writes `dist/jamf-reports-community-v1.0.0.zip`.

The repository also includes a tag-driven GitHub Actions workflow in
`.github/workflows/release.yml`. Pushing a tag such as `v1.0.0` will:

1. build the release zip
2. upload it as a workflow artifact
3. attach it to the GitHub Release for that tag

Example:

```bash
git tag v1.0.0
git push origin v1.0.0
```

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

That export uses `jamf-cli pro computers list` (with `--section GENERAL --section
HARDWARE --section OPERATING_SYSTEM --section USER_AND_LOCATION --section
DISK_ENCRYPTION --section SECURITY`) plus `jamf-cli pro report ea-results --all`
to create a wide CSV with one row per computer and one column per EA.

Hardware, OS, user/location, FileVault, SIP, firewall, Gatekeeper, and bootstrap token
state are returned directly by the inventory list response. An optional per-device
enrichment loop (`pro device <id>` per computer) is available as a fallback and can be
disabled with `inventory_csv.skip_security_enrichment: true` once you confirm the
inventory list response has everything you need. A scaffolded config from this CSV
can populate the `Security Controls` sheet without requiring a Jamf UI export.

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

### Step 6 — Optional: bootstrap a per-tenant workspace (recommended)

For all users, including MSPs, the recommended workflow is one workspace per tenant.
That keeps `config.yaml`, `jamf-cli-data/`, `snapshots/`, `Generated Reports/`, and the
tenant-specific CSV inbox isolated from other tenants.

Create a live `jamf-cli` tenant workspace like this:

```bash
python3 jamf-reports-community.py workspace-init \
    --profile acme-demo \
    --workspace-root ~/Jamf-Reports
```

Create a CSV-only tenant workspace like this:

```bash
python3 jamf-reports-community.py workspace-init \
    --workspace-root ~/Jamf-Reports \
    --workspace-name csv-demo
```

A workspace created this way contains:

- `config.yaml`
- `jamf-cli-data/`
- `snapshots/`
- `Generated Reports/`
- `csv-inbox/`
- `automation/logs/`

By default, `workspace-init` seeds `config.yaml` with local workspace-relative paths.
That means the same repo can hold many tenant workspaces safely.

If you already have a tenant workspace, run report commands from inside it whenever
possible:

```bash
cd ~/Jamf-Reports/acme-demo
python3 /path/to/jamf-reports-community/jamf-reports-community.py \
    generate --csv "$HOME/Jamf Exports/my-export.csv"
```

Or run from the repo root and explicitly point to the tenant config:

```bash
python3 jamf-reports-community.py \
    --config ~/Jamf-Reports/acme-demo/config.yaml \
    generate --csv "$HOME/Jamf Exports/my-export.csv"
```

If you are no longer using the root repo workspace, delete the root `config.yaml` and
empty root folders such as `Jamf Reports/`, `jamf-cli-data/`, and `Generated Reports/`.

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

- `snapshot-only` — refresh jamf-cli snapshots and archive per-family CSV history; optional xlsx/HTML output is controlled by `automation.*`
- `jamf-cli-only` — generate configured automation outputs from live or cached jamf-cli data
- `jamf-cli-full` — build a jamf-cli baseline CSV, refresh snapshots, and generate configured outputs
- `csv-assisted` — prefer a manifest-selected CSV first, then an inbox CSV, plus jamf-cli data

Schedules currently support `daily`, `weekdays`, `weekly`, and `monthly`.

Set `automation.generate_xlsx`, `automation.generate_html`, and
`automation.generate_inventory_csv` in `config.yaml` to control which artifacts each
scheduled run produces.

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
| `--profile` | `jamf_cli.profile` | Runtime jamf-cli profile override for Jamf Pro commands |

If you omit `--csv`, the workbook is built from jamf-cli data only unless a matching
report family is enabled. `report_families.computers` is preferred; if no computer
family matches, `report_families.mobile` is used as a fallback. Mobile CSV workbook runs
use `mobile_columns` and currently write dedicated mobile inventory/stale sheets plus
`custom_eas`. CSV trend charts remain computer-focused, so mobile CSV runs keep charts on
the jamf-cli side for now.

Examples:

```bash
# Mixed workbook: create a baseline CSV, then build jamf-cli sheets plus CSV sheets
python3 jamf-reports-community.py inventory-csv --config config.yaml --out-file inventory.csv
python3 jamf-reports-community.py generate --config config.yaml --csv inventory.csv

# Mobile CSV workbook with dedicated mobile mappings
python3 jamf-reports-community.py generate --config config.yaml --csv mobile_export.csv

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
software install distribution when the installed jamf-cli build supports them. When
`platform.enabled` is true, `collect` also saves the Platform API report snapshots needed
for the blueprint, DDM, and optional benchmark sheets. The saved JSON files are already
timestamped; the generated report outputs can also auto-archive older runs out of the
active output folder.

`collect` does not require a CSV or preexisting history. In a fresh workspace, it can
bootstrap `jamf-cli-data/` from the selected Jamf Pro profile by saving inventory,
security, compliance, app/update, group, package, script, and org metadata snapshots.

When `report_families` is enabled, `collect` also archives the newest matching CSV for
each enabled family into that family's `historical_dir`, even when `--csv` is omitted.

### `inventory-csv` — Export a wide inventory CSV from jamf-cli

```
python3 jamf-reports-community.py inventory-csv \
    [--config config.yaml] \
    [--out-file inventory.csv]
```

Builds a local CSV from live Jamf Pro data using `jamf-cli pro computers list` (with
GENERAL, HARDWARE, OPERATING_SYSTEM, USER_AND_LOCATION, DISK_ENCRYPTION, and SECURITY
sections requested) plus `jamf-cli pro report ea-results --all`. This is the easiest
way to feed the existing `scaffold`, `check`, and `generate` flow without hand-building
a Jamf Advanced Search.

This is a baseline export, not a perfect clone of every Jamf Pro CSV shape. It depends on
computer names being unique so EA values can be joined back to device rows safely.

The export is intentionally based on the `computers list` surface, so it is
best for bootstrap and general inventory reporting. It is not a full replacement for
every possible Jamf Pro Advanced Search or every per-device field exposed by `jamf-cli
pro device`.

`inventory-csv` uses live auth for the computer inventory list and writes that response
to `jamf-cli-data/computers-list/`. Extension attribute results use the normal
live-or-cached snapshot path; if EAs are temporarily unavailable, the command still
writes the base inventory CSV and prints a warning.

Hardware, OS, user/location, and standard security columns (FileVault, SIP, firewall,
Gatekeeper, bootstrap token state) come directly from the inventory list response, so
scaffolded configs can auto-map those columns without any extra round trips. An
optional per-device `pro device <id>` enrichment loop is available as a fallback;
disable it with `inventory_csv.skip_security_enrichment: true` once you confirm the
inventory list response has the columns you need. Tune parallelism with
`inventory_csv.max_workers` (default `20`) and per-call timeouts with
`jamf_cli.command_timeout_seconds` / `ea_results_timeout_seconds`.

If you want later commands to use `--csv inventory.csv`, create it explicitly with
`inventory-csv --out-file inventory.csv`. If you omit `--out-file`, the export is written
to `Generated Reports/` using the configured timestamp behavior.

### `backup` — Snapshot Jamf Pro configuration objects

```bash
python3 jamf-reports-community.py backup \
    [--config config.yaml] \
    [--label before-change-window]
```

Runs `jamf-cli pro backup --format json` for the configured `jamf_cli.profile` and writes
the result under `backups/<timestamp>-<label>/` next to the profile's `config.yaml`.
Each backup includes a `manifest.json` with profile, timing, file count, byte size, and
the exact jamf-cli command used. The macOS app's Backups screen can reveal these folders
and compare two backups with `jamf-cli pro diff`.

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
    [--mode jamf-cli-only] \
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
- `jamf-cli-only` is the default because it is the simplest and most reliable path
- `csv-assisted` prefers `report_families` first, then can consume emailed Jamf exports
  from an inbox folder, while still keeping jamf-cli as the primary backend

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

### `capabilities` — Print app/report capabilities

```bash
python3 jamf-reports-community.py capabilities --output json
```

Prints a deterministic JSON manifest for GUI clients and automation wrappers. The
manifest lists supported Jamf products, commands, data sources, current-status surfaces,
historical/trend surfaces, config sections, and known product gaps. It does not load
`config.yaml`, probe the filesystem, or call `jamf-cli`.

### App-facing run summaries

```bash
python3 jamf-reports-community.py generate --summary-json run-summary.json
python3 jamf-reports-community.py collect --summary-json collect-summary.json
python3 jamf-reports-community.py school-generate --summary-json school-summary.json
python3 jamf-reports-community.py school-collect --summary-json school-collect-summary.json
python3 jamf-reports-community.py html --summary-json html-summary.json
```

These commands can write deterministic JSON summaries for GUI clients and automation
wrappers. The summaries include command metadata, output paths, counts, selected inputs,
and source/archive information without changing the normal console output.

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

Sheets appear only when the required config and data are present. Use
`sheets.skip` to omit named tabs or `sheets.only` to generate a focused workbook.

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
| Package Lifecycle | jamf-cli | Package inventory with filename, optional age/size, and notes |
| Policy Health | jamf-cli | Policy count, config findings |
| Profile Status | jamf-cli | Config profile deployment errors by profile and device |
| Mobile Config Profiles | jamf-cli | Mobile configuration profile list and category distribution |
| App Status | jamf-cli v1.2.0+ | Managed app deployment failures by app and device |
| Patch Compliance | jamf-cli | Per-title patch compliance percentages |
| Update Status | jamf-cli v1.2.0+ | Managed software update status summary and error device list |
| Platform Blueprints | jamf-cli platform preview | Blueprint deployment state, scope, and failure/pending counts |
| Platform Compliance Rules | jamf-cli platform preview + `platform.compliance_benchmarks` | Per-rule benchmark pass/fail/unknown counts |
| Platform Compliance Devices | jamf-cli platform preview + `platform.compliance_benchmarks` | Devices with benchmark rule failures and aggregate compliance |
| Platform DDM Status | jamf-cli platform preview | Declaration success vs unsuccessful counts by source |
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

### `mobile_columns`

Maps logical field names to a mobile-device CSV export when you want workbook sheets from
`report_families.mobile` or an explicit mobile `--csv` path.

```yaml
mobile_columns:
  device_name: "Display Name"
  serial_number: "Serial Number"
  operating_system: "OS Version"
  last_checkin: "Last Inventory Update"
  email: "Email Address"
  model: "Model"
  device_family: "Device Family"
  managed: "Managed"
  supervised: "Supervised"
```

Keep this separate from `columns`. Mixed environments often need both computer and mobile
families in one config, and one header mapping cannot credibly serve both schemas.

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
  enabled: true
  data_dir: "jamf-cli-data"
  profile: ""
  use_cached_data: true
  allow_live_overview: true
  command_timeout_seconds: 300
  ea_results_timeout_seconds: 600
```

The community default is a plain `jamf-cli-data/` folder next to the script. If you prefer
your production-style layout, point `data_dir` at that directory instead. Relative paths
resolve from the folder containing `config.yaml`. When you switch between multiple
jamf-cli profiles, set `profile` and use a profile-specific `data_dir` to keep cached
snapshots from different tenants separate. Set `allow_live_overview: false` only if you
want Fleet Overview to rely on cached JSON for a specific environment. Set
`enabled: false` when you want a strict CSV-only run that skips both live jamf-cli calls
and cached jamf-cli sheets entirely.

`command_timeout_seconds` is the per-call subprocess timeout for every jamf-cli
invocation; raise it for slow Jamf Pro instances or large fleets that exceed the 300s
default. `ea_results_timeout_seconds` overrides that ceiling specifically for
`pro report ea-results --all`, which queries every EA value across the fleet and is
consistently the slowest jamf-cli call — the 600s default has headroom for fleets with
hundreds of EAs and thousands of devices.

### `inventory_csv`

Controls the `inventory-csv` command's per-device enrichment loop.

```yaml
inventory_csv:
  max_workers: 20
  skip_security_enrichment: false
```

`max_workers` sets the parallelism for the optional `pro device <id>` enrichment loop.
`skip_security_enrichment: true` disables that loop entirely. The inventory list call
already returns FileVault, SIP, firewall, Gatekeeper, and bootstrap token state via the
SECURITY section, so skipping the per-device loop usually loses no data and is the most
impactful single tuning knob for runtime on large fleets.

### `platform`

Opt-in preview support for jamf-cli Platform API report commands.

```yaml
platform:
  enabled: false
  compliance_benchmarks: []
```

Set `enabled: true` to turn on the Platform sheets. Leave `compliance_benchmarks` empty
if you only want blueprint and DDM reporting. Add one or more benchmark titles or IDs to
also generate the benchmark-specific compliance sheets.

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

### `report_families`

Optional manifest for tenants that keep many Jamf CSV families in one workspace.

```yaml
report_families:
  computers:
    enabled: true
    current_dir: "Jamf Reports/Pro"
    historical_dir: "snapshots/computers"
    include_globs:
      - "*Computers*.csv"
    exclude_globs:
      - "*Portal - Applications*.csv"
    prefer_name_contains:
      - "All Devices"
```

Use this when you want to preserve many raw emailed/exported report streams without
pointing one workbook at the entire archive root.

Current behavior:
- `report_families.computers` drives `check` and `generate` when `--csv` is omitted.
- If no computers family matches, `report_families.mobile` is the fallback.
- `collect` archives the newest matching CSV for every enabled family into that family's
  `historical_dir`.
- `mobile` can now drive dedicated mobile CSV workbook sheets when `mobile_columns` is
  configured.
- `compliance` remains useful for archival/discovery and future automation, but it is not
  auto-merged into workbook CSV sheets yet.

Practical guidance:
- Keep one baseline computer inventory family for the main workbook.
- Keep one mobile family if you want either historical preservation or mobile CSV
  workbooks.
- Keep specialized searches like patching, local admin, or OS compliance in separate
  family folders instead of mixing them into the baseline computer history.

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

### `sheets`

Optional workbook-tab filtering by final display name.

```yaml
sheets:
  only:
    - "Patch Compliance"
    - "Patch Failures"
  skip:
    - "Report Sources"
```

- `only` takes precedence over `skip`
- matching is case-insensitive
- filtering applies to Jamf Pro tabs, CSV tabs, Jamf School tabs, custom EA tabs,
  and auxiliary workbook tabs such as `Report Sources` and `Charts`

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

If you keep many Jamf exports in one folder, prefer one baseline computer inventory export
and, if needed, one baseline mobile inventory export per cadence. Equivalent same-day CSVs
with the same schema are deduped for trend charts by keeping the largest snapshot, so an
all-devices export wins over smaller subset exports. Re-running `generate` with the same
unchanged CSV also reuses the existing identical archived snapshot instead of creating
another duplicate copy.

#### Cached jamf-cli snapshots

If you want the core jamf-cli sheets to keep working even when live auth breaks, leave
`jamf_cli.use_cached_data: true` and keep saved JSON snapshots in `jamf_cli.data_dir`.
The script uses the newest matching snapshot per report and logs when cached data is used.
The OS adoption chart can also use `inventory-summary` history, and the device state trend
chart can use `device-compliance` history, so jamf-cli-only reporting no longer depends on
CSV history for every chart.

### `branding`

All fields are optional. When `org_name` is set it is prepended to every sheet title in
the Excel workbook and shown in the HTML report header and PPTX title slide.

| Key | Default | Description |
| --- | ------- | ----------- |
| `org_name` | `""` | Organisation name, e.g. `"Acme Corp"` |
| `logo_path` | `""` | Path to a PNG/JPEG logo (relative to config file or absolute) |
| `accent_color` | `"#2D5EA2"` | Hex colour for Excel column headers and HTML primary accent |
| `accent_dark` | `"#004165"` | Darker accent for HTML topbar and dark-mode elements |

The logo is embedded as a base64 image in the self-contained HTML report and inserted on
the Report Sources sheet of the Excel workbook.

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
