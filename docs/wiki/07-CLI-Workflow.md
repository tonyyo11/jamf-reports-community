# CLI Workflow

`jamf-reports-community.py` is a single-file Python script that produces the same reports
as the macOS app, from the command line. It is the optional path — use it for headless
servers, CI and Linux environments, and scripted automation where a GUI is not available.

## When to use the CLI

- Headless or Linux hosts with no macOS GUI.
- CI pipelines and hosted runners.
- Scripted, scheduled, or multi-tenant automation.

If you are on a Mac with a desktop, the [app](02-App-Onboarding) is the easier path.

## Install

The CLI needs **Python 3.11 or later** and three packages:

```bash
pip install xlsxwriter pandas pyyaml
pip install matplotlib          # optional — only for chart generation
```

For supply-chain integrity in CI, install from the hash-pinned lock file instead:

```bash
pip install -r requirements.lock.txt --require-hashes
```

`jamf-cli` is optional. A CSV-only run needs neither jamf-cli nor live API access; jamf-cli
adds live collection, snapshot caching, and the API-driven sheets. See
[Installation](01-Installation) to install and authenticate it.

## Commands

```
python3 jamf-reports-community.py <command> [options]
```

| Command | Purpose |
|---|---|
| `scaffold` | Generate a starter `config.yaml` from a CSV export |
| `check` | Validate `config.yaml` against a CSV and jamf-cli auth |
| `generate` | Build the Excel workbook |
| `html` | Build a self-contained HTML instance report |
| `collect` | Refresh jamf-cli JSON snapshots; optionally archive a CSV |
| `inventory-csv` | Export a wide inventory CSV from jamf-cli |
| `backup` | Snapshot Jamf Pro configuration objects |
| `workspace-init` | Create a per-profile workspace skeleton |
| `launchagent-setup` | Create a scheduled LaunchAgent job |
| `diagnostic-bundle` | Bundle redacted diagnostics for sharing |
| `capabilities` | Print a machine-readable capability manifest |

Jamf School has a parallel set — see [Jamf School](08-Jamf-School).

All config-managed paths resolve relative to `config.yaml`, not your shell's working
directory, so a self-contained reporting workspace is portable.

## The Jamf Pro CSV path

Use this path when you already export Jamf Pro inventory data.

1. In Jamf Pro, run a computer inventory search (a saved Advanced Search is best for
   repeatable reporting) and export to CSV. Include the Extension Attributes you want to
   report on — missing columns today become missing trend points later.
2. Scaffold a config:

   ```bash
   python3 jamf-reports-community.py scaffold --csv "export.csv"
   ```

3. Validate the mappings:

   ```bash
   python3 jamf-reports-community.py check --config config.yaml --csv "export.csv"
   ```

4. Generate the workbook:

   ```bash
   python3 jamf-reports-community.py generate --config config.yaml --csv "export.csv"
   ```

Keep one stable export shape so `config.yaml` stays stable and trends stay comparable.

## The jamf-cli data path

Use this path to reduce reliance on Jamf UI exports.

Build a baseline inventory CSV directly from jamf-cli (validate the profile first):

```bash
jamf-cli config validate -p yourprofile
python3 jamf-reports-community.py inventory-csv --config config.yaml --out-file inventory.csv
```

`inventory-csv` combines `jamf-cli pro computers list` (with the GENERAL, HARDWARE,
OPERATING_SYSTEM, USER_AND_LOCATION, DISK_ENCRYPTION, and SECURITY sections) and
`jamf-cli pro report ea-results --all`. The resulting CSV feeds `scaffold`, `check`, and
`generate` like any other export. `inventory-csv` is live-only — it does not reuse cached
snapshots.

Refresh API snapshots, then generate:

```bash
python3 jamf-reports-community.py collect --config config.yaml
python3 jamf-reports-community.py generate --config config.yaml
```

## collect vs generate

- **`collect`** saves live jamf-cli JSON snapshots to `jamf_cli.data_dir`. It produces no
  workbook. Schedule it to build an append-only historical store.
- **`generate`** builds the workbook, reading cached snapshots when `use_cached_data:
  true` so a momentary auth failure does not produce a blank report.

A solid scheduled pattern: `collect` on a frequent cadence, `generate` weekly or on
demand. See [Scheduling & Automation](05-Scheduling-and-Automation) for `launchagent-setup`.

## HTML instance report

```bash
python3 jamf-reports-community.py html --config config.yaml --out-file report.html
```

`html` writes a single self-contained file with embedded Chart.js charts and a dark-mode
toggle. With `html.track_history: true` in `config.yaml`, each run appends an OS-version
snapshot to a history file; once two or more snapshots exist, a macOS adoption timeline
appears in the report.

## What gets generated

A workbook contains only the sheets your config and data support. CSV-driven sheets
include Device Inventory, Stale Devices, Security Controls, Security Agents, Compliance,
and one sheet per `custom_eas` entry. jamf-cli-driven sheets include Fleet Overview,
Security Posture, Inventory Summary, Device Compliance, EA Coverage, Software Installs,
Policy Health, Patch Compliance, and Update Status. Use `sheets.only` / `sheets.skip` in
`config.yaml` to focus a workbook.

## Releases

For end-user downloads, build a release bundle of just the runtime files:

```bash
./scripts/build-release.sh v1.0.0      # → dist/jamf-reports-community-v1.0.0.zip
```

A tag-driven GitHub Actions workflow also builds and attaches the zip when you push a
version tag.
