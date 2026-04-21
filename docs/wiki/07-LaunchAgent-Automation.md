# LaunchAgent Automation

## Why Automate This

Historical reporting is only as good as the cadence behind it.

If you collect snapshots and CSVs consistently:

- trend charts become easier to trust
- weekly and month-end comparisons become easier to explain
- workbook generation stops depending on a human remembering to run commands
- cached `jamf-cli` JSON becomes a real offline rerun source instead of an accident

That is why this project now includes a LaunchAgent setup path instead of treating
scheduling as an external afterthought.

## Why LaunchAgent, Not LaunchDaemon

This project currently supports LaunchAgents only.

That choice is intentional:

- the job runs in the same macOS user context that owns the `jamf-cli` profile
- `jamf-cli` configuration follows XDG config-file rules, so the active config path is
  naturally user-scoped
- `jamf-cli` interactive setup stores secrets as keychain references, which fits the
  local-user reporting model better than a root daemon model

Relevant upstream references:

- [jamf-cli Setup Guide](https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide)
- [jamf-cli Configuration & Profiles](https://github.com/Jamf-Concepts/jamf-cli/wiki/Configuration-&-Profiles)
- [jamf-cli Secrets & Keychain](https://github.com/Jamf-Concepts/jamf-cli/wiki/Secrets-&-Keychain)

For headless CI or daemon-style automation, use environment-variable or file-backed
secrets and a different operating model. That is outside the scope of this local-user
LaunchAgent workflow.

## Tenant Isolation Rules

For multi-tenant admins and MSPs, use this discipline:

- one `jamf-cli` profile per tenant
- one `config.yaml` per tenant
- one reporting workspace per tenant
- one LaunchAgent per tenant

This is the safest way to avoid mixing:

- cached JSON snapshots in `jamf-cli-data/`
- historical CSV snapshots in `snapshots/`
- emailed or exported CSVs in a CSV inbox folder
- generated xlsx and PNG outputs

The jamf-cli Setup Guide documents multi-instance setup for MSP-style environments and
notes that `pro setup --from-file` auto-names profiles like `pro-school1`,
`pro-school2`, and so on. `jamf-reports-community` should mirror that separation by
keeping one scheduled job per profile/tenant.

The easiest way to enforce that structure locally is to start with:

```bash
python3 jamf-reports-community.py workspace-init \
    --profile yourprofile \
    --workspace-root ~/Jamf-Reports
```

Then point `launchagent-setup` at the generated workspace config.

## What `launchagent-setup` Creates

Run:

```bash
python3 jamf-reports-community.py launchagent-setup --config config.yaml
```

The setup command can:

- prompt for workflow mode and schedule
- create an optional CSV inbox folder
- create an optional historical CSV snapshot folder
- write a LaunchAgent plist under `~/Library/LaunchAgents/` by default
- create per-job stdout and stderr logs
- create a status JSON file for last-run troubleshooting
- optionally load the LaunchAgent into the current GUI session

By default, the generated job points back at this script through the internal
`launchagent-run` command with absolute paths for:

- the Python interpreter
- `jamf-reports-community.py`
- the selected `config.yaml`
- the optional CSV inbox directory
- the optional historical CSV directory

The setup command also carries forward useful launchd environment values such as:

- `PATH`
- `HOME`
- `XDG_CONFIG_HOME` when present
- `JAMFCLI_PATH` when `jamf-cli` is discoverable at setup time

That matters because launchd jobs do not inherit the same shell environment you have in
an interactive Terminal session.

## Workflow Modes

### `snapshot-only`

Use when you want historical data first and workbook generation later.

What it does:

- runs `collect`
- refreshes jamf-cli JSON snapshots
- optionally archives the newest CSV from the inbox into the historical snapshot folder
- optionally runs `inventory-csv`, `generate`, and/or `html` based on `automation.*`

Best for:

- nightly or weekly snapshot preservation
- building trend history before leadership reporting
- keeping live collection separate from workbook generation

### `jamf-cli-only`

Use when you want a workbook without a CSV dependency.

What it does:

- runs `generate` without `--csv`
- uses live `jamf-cli` data and/or cached JSON snapshots

Best for:

- API-driven dashboards
- lighter scheduled reporting
- environments that do not rely on emailed Jamf inventory exports

### `jamf-cli-full`

Use when you want the most self-contained scheduled reporting path.

What it does:

- runs `inventory-csv`
- runs `collect`
- runs `generate --csv <generated_inventory_csv>`

Best for:

- orgs that want CSV-driven sheets without relying on Jamf email exports
- fully local, API-driven recurring reports
- admins who want one scheduled job to refresh both workbook inputs and snapshots

### `csv-assisted`

Use when Jamf CSV exports arrive through email, sync folders, or other human workflows.

What it does:

- looks for the newest `.csv` in the configured inbox folder
- if a fresh CSV is found, runs `generate --csv <that file>`
- if no fresh CSV is found, falls back to jamf-cli-only workbook generation
- still runs `collect` first so jamf-cli snapshots stay current when possible

Best for:

- orgs that already receive Jamf exports by email
- SharePoint/OneDrive synced report folders
- mixed workflows where CSV availability is helpful but not guaranteed

Important behavior:

- fallback is based on CSV presence and age
- a malformed CSV is not silently ignored; that should fail loudly so you notice it

## Automation Output Flags

Scheduled runs can also emit extra artifacts based on `config.yaml`:

```yaml
automation:
  generate_xlsx: true
  generate_html: false
  generate_inventory_csv: false
```

- `generate_xlsx` keeps the existing workbook behavior for scheduled runs.
- `generate_html` adds a timestamped HTML report using the same output retention rules.
- `generate_inventory_csv` writes a timestamped automation inventory CSV; `snapshot-only`
  can use that CSV as the workbook source when `generate_xlsx: true`.

## Schedule Presets

The current setup flow supports:

- `daily`
- `weekdays`
- `weekly`
- `monthly`

This keeps the UI practical while still covering the most common reporting cadences.

Examples:

```bash
# Every weekday at 07:15
python3 jamf-reports-community.py launchagent-setup \
    --config config.yaml \
    --mode csv-assisted \
    --schedule weekdays \
    --time-of-day 07:15

# Every Monday at 06:30
python3 jamf-reports-community.py launchagent-setup \
    --config config.yaml \
    --mode jamf-cli-full \
    --schedule weekly \
    --weekday Monday \
    --time-of-day 06:30

# First day of the month at 05:45
python3 jamf-reports-community.py launchagent-setup \
    --config config.yaml \
    --mode snapshot-only \
    --schedule monthly \
    --day-of-month 1 \
    --time-of-day 05:45
```

On macOS, `launchd` uses `StartCalendarInterval` for these schedules. If the Mac sleeps
through the exact trigger time, launchd will coalesce missed schedule events into one run
when the machine wakes. That usually makes LaunchAgents a better fit than cron for laptop
reporting workflows.

## CSV Inbox Model

The CSV inbox is intentionally simple:

- it scans recursively for `.csv` files
- it picks the newest file by modification time
- it can enforce a freshness window in days

That makes it suitable for folders such as:

- `~/Jamf Reports/inbox/`
- a OneDrive or SharePoint-synced folder
- a manually curated folder of Jamf export attachments

If you enable a CSV inbox, also enable a historical CSV directory unless you have another
deliberate archive process. Otherwise you will consume one-off CSVs without building the
trend history that makes them valuable later.

## Historical Data Strategy

Automation is valuable because it helps preserve the right layers of history:

- `jamf-cli-data/` for API-native JSON snapshots
- `snapshots/` for dated CSV history
- `Generated Reports/` for output artifacts

Those layers should stay conceptually separate.

Recommended pattern:

1. Use `snapshot-only` or `csv-assisted` on a fixed cadence to preserve point-in-time data.
2. Use `jamf-cli-full` when you want one job to produce both historical inputs and a workbook.
3. Keep generated workbooks archived, but treat snapshots as the real long-term historical store.

If your charts are meant for leadership reporting, preserve a consistent month-end cadence
even if you also collect weekly.

## Troubleshooting

Generated LaunchAgents write:

- a stdout log
- a stderr log
- a JSON status file with the last selected CSV and report path

Useful operational commands:

```bash
# Load or reload a plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.report.plist

# Unload a plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.example.report.plist

# Force one immediate run
launchctl kickstart -k gui/$(id -u)/com.example.report
```

If the repo path, Python interpreter path, or config location changes, rerun
`launchagent-setup` so the generated plist is updated.
