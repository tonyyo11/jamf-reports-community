# Jamf School Workflow

## When To Use This Path

Use the Jamf School path when you manage an iOS/iPadOS fleet through Jamf School (formerly
Zuludesk) and want workbook reporting from either:

- A Jamf School device CSV export (no live credentials needed)
- Live `jamf-cli school` commands (jamf-cli 1.7+)

This path produces a standalone Jamf School workbook with separate sheets for inventory,
OS versions, device status, stale devices, overview, device groups, users, classes, apps,
profiles, and locations.

## Prerequisites

### jamf-cli school (optional — for live data)

Live collection requires jamf-cli 1.7 or later. Run:

```bash
jamf-cli school setup --profile-name school
```

Verify it works:

```bash
jamf-cli school overview
```

If you only have a CSV export, skip this step. `school-generate` works with `--csv` only.

### Config sections

Add two sections to your `config.yaml` (or run `school-scaffold` to generate them):

```yaml
school_cli:
  enabled: false          # set true when using live jamf-cli school commands
  data_dir: "school-cli-data"
  profile: "school"       # must match the profile name from jamf-cli school setup
  use_cached_data: true

school_columns:
  device_name: ""         # fill in after running school-scaffold
  serial_number: ""
  os_version: ""
  model: ""
  location_name: ""
  # ... (run school-scaffold to auto-detect the rest)
```

`school_columns` maps logical field names to the actual headers in your Jamf School CSV
export. The `school-scaffold` command auto-detects these from a sample CSV.

## CSV Export Format

Jamf School device exports use semicolon (`;`) as the delimiter, not comma. Export from:

**Devices > Export** in the Jamf School web interface.

The tool reads the exported file directly. You do not need to convert it.

## Commands

### school-scaffold

Auto-detect column mappings from a sample CSV and write them to `config.yaml`:

```bash
python3 jamf-reports-community.py school-scaffold \
    --csv school_export.csv \
    --out-file config.yaml
```

Review the generated `school_columns` section before running `school-generate`. Fuzzy
matching is good but not perfect — check that `device_name` resolved to the display name
column, not a location or class name.

### school-check

Validate the current `school_columns` mapping against a CSV:

```bash
python3 jamf-reports-community.py school-check \
    --config config.yaml \
    --csv school_export.csv
```

Prints which columns resolved, which are missing, and whether the required fields are
present. Run this after any manual edit to `school_columns`.

### school-generate (CSV path)

Generate a Jamf School workbook from a CSV export without live credentials:

```bash
python3 jamf-reports-community.py school-generate \
    --config config.yaml \
    --csv school_export.csv \
    --out-file jamf_school_report.xlsx
```

This is the primary path for most environments. It does not require `school_cli.enabled`
or a configured jamf-cli school profile.

### school-collect (live path)

Fetch live data from jamf-cli and save JSON snapshots to `school_cli.data_dir`:

```bash
python3 jamf-reports-community.py school-collect --config config.yaml
```

Requires `school_cli.enabled: true` and a working `jamf-cli school` profile.

### school-generate (live or cached path)

After `school-collect` has run at least once, generate from cached snapshots:

```bash
python3 jamf-reports-community.py school-generate --config config.yaml
```

When `school_cli.use_cached_data: true`, this works offline after the initial collect.

## What jamf-cli school Commands Are Used

When `school-collect` runs, it calls:

- `jamf-cli school overview`
- `jamf-cli school devices list`
- `jamf-cli school device-groups list`
- `jamf-cli school users list`
- `jamf-cli school groups list`
- `jamf-cli school classes list`
- `jamf-cli school apps list`
- `jamf-cli school profiles list`
- `jamf-cli school locations list`

## Workbook Sheets Produced

| Sheet | Source |
|---|---|
| Overview | `school overview` or CSV aggregate |
| Device Inventory | CSV or `school devices list` |
| OS Versions | derived from Device Inventory |
| Device Status | managed, supervised, lost-mode counts |
| Stale Devices | devices not checked in within `stale_device_days` |
| Device Groups | `school device-groups list` |
| Users | `school users list` |
| Classes | `school classes list` |
| Apps | `school apps list` |
| Profiles | `school profiles list` |
| Locations | `school locations list` |

Sheets sourced entirely from live commands are omitted when no cached data exists and
`school_cli.enabled` is false.

## Recommended Pattern

1. Export a CSV from Jamf School (Devices > Export).
2. Run `school-scaffold --csv school_export.csv` to generate column mappings.
3. Review `school_columns` in `config.yaml`.
4. Run `school-check` to confirm the mapping is correct.
5. Run `school-generate --csv school_export.csv` to produce the workbook.
6. If you also have jamf-cli 1.7+, set `school_cli.enabled: true` and run
   `school-collect` to add live-data sheets to future workbooks.

## Offline Demo

To preview the Jamf School workbook output without a live tenant or your own CSV:

```bash
./scripts/demo.sh school
```

This generates a fixture-backed Jamf School workbook using the committed sample data in
`tests/fixtures/csv/harboredu_school_devices.csv`. Output goes to
`Generated Reports/demo/jamf-school-csv.xlsx`.
