# Jamf School

Use this path when you manage an iOS/iPadOS fleet through Jamf School and want workbook
reporting from either a Jamf School device CSV export or live `jamf-cli school` data.

It produces a standalone Jamf School workbook with sheets for device inventory, OS
versions, device status, stale devices, overview, device groups, users, classes, apps,
profiles, and locations. The native Swift engine and the Python CLI both generate it; the
CLI commands below are the documented path.

## Prerequisites

A CSV export needs no credentials. For live data, install `jamf-cli` (v1.16.1+, see
[Installation](01-Installation)) and configure a School profile:

```bash
jamf-cli school setup
jamf-cli school overview      # verify it works
```

Add two sections to `config.yaml` — or let `school-scaffold` generate them:

```yaml
school_cli:
  enabled: false          # true when using live jamf-cli school commands
  data_dir: "school-cli-data"
  profile: "school"       # must match the jamf-cli school profile
  use_cached_data: true

school_columns:
  device_name: ""         # filled in by school-scaffold
  serial_number: ""
  # ...
```

## CSV export format

Jamf School device exports use a semicolon (`;`) delimiter, not a comma. Export from
**Devices > Export** in the Jamf School web interface — the tool reads the file directly,
no conversion needed.

## Commands

```bash
# Auto-detect column mappings from a sample CSV
python3 jamf-reports-community.py school-scaffold --csv school_export.csv --out config.yaml

# Validate the school_columns mapping
python3 jamf-reports-community.py school-check --config config.yaml --csv school_export.csv

# Generate a workbook from a CSV export (no credentials needed)
python3 jamf-reports-community.py school-generate --config config.yaml --csv school_export.csv

# Fetch live data into JSON snapshots (requires school_cli.enabled and a school profile)
python3 jamf-reports-community.py school-collect --config config.yaml

# Generate from cached snapshots after a collect
python3 jamf-reports-community.py school-generate --config config.yaml
```

Review the generated `school_columns` after scaffolding — fuzzy matching is good but not
perfect. Confirm `device_name` resolved to the display-name column, not a location or
class name.

## What jamf-cli school commands are used

`school-collect` calls `school overview`, `school devices list`, `school device-groups
list`, `school users list`, `school groups list`, `school classes list`, `school apps
list`, `school profiles list`, and `school locations list`.

## Recommended pattern

1. Export a CSV from Jamf School (Devices > Export).
2. `school-scaffold` to generate column mappings.
3. Review `school_columns` in `config.yaml`.
4. `school-check` to confirm the mapping.
5. `school-generate --csv` to produce the workbook.
6. If you also have a live `jamf-cli school` profile, set `school_cli.enabled: true` and
   `school-collect` to add live-data sheets to future workbooks.

## Offline demo

Preview the Jamf School workbook with no tenant or credentials:

```bash
./scripts/demo.sh school
```

This builds a fixture-backed workbook from committed sample data into
`Generated Reports/demo/`.
