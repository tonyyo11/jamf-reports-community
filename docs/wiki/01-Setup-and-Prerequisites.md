# Setup and Prerequisites

## Scope

This project is designed for Jamf Pro reporting. It reads Jamf Pro CSV exports, optional
`jamf-cli` snapshots, or both.

It has been tested on Jamf Pro only. `jamf-cli` supports more than Jamf Pro, but this
community project only has experimental Jamf Protect coverage today. The `Protect
Overview` sheet is available as an opt-in path, but it has not been fully validated
against a live Protect tenant or future Platform API data.

## Required Components

### Python

Install Python 3.9 or later:

```bash
python3 --version
```

### Python packages

Install the project dependencies:

```bash
pip install xlsxwriter pandas pyyaml
```

Optional charts require:

```bash
pip install matplotlib
```

### jamf-cli

`jamf-cli` is optional, but strongly recommended if you want:

- Fleet Overview
- Inventory Summary
- Security Posture
- Device Compliance
- EA Coverage
- EA Definitions
- Software Installs
- Patch Compliance
- `inventory-csv`
- Cached JSON snapshots for offline reruns

If you also want the experimental Jamf Protect workbook sheet, use `jamf-cli 1.6.0+`,
run `jamf-cli protect setup`, and set:

```yaml
protect:
  enabled: true
```

Primary references:

- [Jamf Concepts jamf-cli site](https://concepts.jamf.com/jamf-cli/)
- [jamf-cli Documentation Wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki)
- [jamf-cli README](https://github.com/Jamf-Concepts/jamf-cli)
- [Setup Guide](https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide)
- [Configuration & Profiles](https://github.com/Jamf-Concepts/jamf-cli/wiki/Configuration-&-Profiles)
- [Secrets & Keychain](https://github.com/Jamf-Concepts/jamf-cli/wiki/Secrets-&-Keychain)

## Recommended Folder Layout

Use one folder per reporting workspace:

```text
Jamf Reports/
├── config.yaml
├── Jamf Reports/
│   └── export.csv
├── jamf-cli-data/
│   ├── prod/
│   └── dummy/
├── snapshots/
│   ├── inventory_2026-04-05_090000.csv
│   └── inventory_2026-04-12_090000.csv
└── Generated Reports/
    └── archive/
```

Notes:

- `config.yaml` path settings resolve relative to the config file location.
- If you use more than one `jamf-cli` profile, keep each profile in its own snapshot
  directory.
- If you automate with LaunchAgents, keep one reporting workspace and one LaunchAgent per
  tenant/profile.
- The local example in this repo uses `jamf_cli.profile: dummy` and
  `jamf_cli.data_dir: jamf-cli-data/dummy`.
- Timestamped generated outputs can be auto-archived so the active output folder stays
  readable while older runs remain preserved.

If you manage multiple tenants, create one workspace per `jamf-cli` profile:

```bash
python3 jamf-reports-community.py workspace-init \
    --profile yourprofile \
    --workspace-root ~/Jamf-Reports
```

That bootstrap command creates a per-profile `config.yaml`, `jamf-cli-data/`,
`snapshots/`, `Generated Reports/`, `csv-inbox/`, and `automation/logs/` layout.

## Authentication Guidance

For interactive use, prefer `jamf-cli pro setup` so the client ID and secret are stored
in the system keychain instead of shell history.

If you enable Jamf Protect reporting, run `jamf-cli protect setup` as well. Protect uses
its own API credentials even though `jamf-cli` still selects the profile with the same
global `-p/--profile` flag.

Validate the profile before running `inventory-csv` or `collect`:

```bash
jamf-cli config validate -p yourprofile
jamf-cli --profile yourprofile pro overview
```

For automation, environment variables are acceptable:

- `JAMF_URL`
- `JAMF_CLIENT_ID`
- `JAMF_CLIENT_SECRET`

That pattern is better for CI, scheduled jobs, or hosted runners than typing credentials
into long-lived shells.

## Data Collection Paths

Choose one of these starting points:

1. Export a Jamf Pro inventory CSV and run `scaffold`
2. Use `jamf-cli inventory-csv` to create a baseline CSV first
3. Use both, with CSV for broad inventory detail and `jamf-cli` for live summary sheets
4. Build a recurring snapshot routine before you worry about charts or trend lines

The next pages cover each path.
