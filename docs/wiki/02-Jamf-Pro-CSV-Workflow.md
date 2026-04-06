# Jamf Pro CSV Workflow

## When To Use This Path

Use the CSV path when:

- You already rely on Jamf Pro exports
- You want a clear, auditable dataset before generating reports
- You need columns or EAs that are easiest to control from the Jamf Pro UI

## Build the Export

Start from a computer inventory search in Jamf Pro.

Depending on your Jamf Pro version and admin habits, that may be:

- Computers > Search Inventory
- A saved advanced computer search
- An export-oriented search with a curated set of columns

For repeatable reporting, saved advanced computer searches are usually the better choice.
They let you keep one stable export shape for weekly and monthly runs instead of
rebuilding column selections every time.

## Recommended Columns

Include the basics:

- Computer Name
- Serial Number
- Operating System
- Last Check-in
- Model
- Last Enrollment

Include the security fields if you want the built-in security sheet:

- FileVault status
- SIP
- Firewall
- Secure Boot
- Bootstrap Token
- Disk usage
- MDM profile expiry if you track it

Include your extension attributes if you want:

- Security agent coverage
- Compliance data
- Custom EA sheets
- Department, manager, user, or lifecycle metadata

If the report is meant to be your main historical source, include every EA you expect to
visualize over time. Missing columns today become missing trend points later.

## Export Strategy

Keep one CSV export shape for reporting instead of changing columns every run. That makes
your `config.yaml` stable and keeps trend data easier to compare over time.

When saving exports locally, keep the filenames timestamped. Example:

```text
weekly_inventory_2026-04-05_090000.csv
monthly_inventory_2026-04-30_170000.csv
```

If you need multiple reporting views, create multiple saved searches and multiple config
files rather than one giant unstable export.

## First Run

Generate a starter config:

```bash
python3 jamf-reports-community.py scaffold --csv "Jamf Reports/97 Computers.csv"
```

Validate the mappings:

```bash
python3 jamf-reports-community.py check --config config.yaml --csv "Jamf Reports/97 Computers.csv"
```

Build the workbook:

```bash
python3 jamf-reports-community.py generate --config config.yaml --csv "Jamf Reports/97 Computers.csv"
```

## Ongoing CSV Workflow

For recurring reporting:

1. Export the same search again
2. Save the CSV with a timestamp in your working folder
3. Run `check` if headers changed
4. Run `generate`
5. Optionally archive the CSV for historical charts

If you also use jamf-cli, keep that in the same workflow. A strong mixed-source pattern is:

1. Export the saved search CSV
2. Run `collect` to refresh jamf-cli JSON history
3. Run `generate` with the CSV so the workbook contains both CSV-driven and jamf-cli
   sheets

For ad-hoc analysis:

1. Export a focused search
2. Either reuse an existing config or scaffold a temporary one
3. Generate a one-off workbook

## When To Switch To jamf-cli

Move toward `jamf-cli` when:

- You want less Jamf UI work
- You want cached API snapshots
- You want EA discovery without building exports first
- You want summary sheets that come directly from API-driven reports

You do not have to choose one forever. Many orgs will keep CSV exports for EA-heavy and
compliance-heavy reporting while using jamf-cli for discovery, summary sheets, and
offline cache history.

The next page covers that path.
