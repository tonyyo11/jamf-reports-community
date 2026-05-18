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

The Python `launchagent-setup --mode` flag and the Swift app's Schedules form
share the same four modes. As of PR-20 / PR-21, the Swift app's mode contract
is strict — each mode does exactly one thing, with no operational overlap and
no silent fallback. The mode descriptions below describe that behavior.

The Python `launchagent-run` path predates PR-21 and retains the legacy
behavior (notably the csv-assisted "fall back to jamf-cli-only when no CSV"
fallback). That divergence will be reconciled in a follow-up PR; until then,
the table at the end of this section calls out where the two paths differ.

### `snapshot-only`

Use when you want fresh data for the Trends page without generating a workbook.

What it does:

- runs `collect` to refresh `jamf-cli` JSON snapshots
- writes a daily `summary_YYYY-MM-DD.json` so the Trends page advances
- does NOT generate a workbook

Best for:

- nightly snapshot preservation
- keeping trend history current without producing files anyone has to read
- separating "did the data refresh" from "did the report get built"

Note: the daily summary is written first-run-of-day-wins. If you schedule
multiple `snapshot-only` runs in the same day, only the first writes the
summary; subsequent runs log `[info] summary_<today>.json already exists`.

### `jamf-cli-only`

Use when you want a workbook re-rendered from data that's already cached.

What it does:

- runs `generate` against the latest cached `jamf-cli` snapshots
- does NOT collect fresh data — no API calls, no network dependency

Best for:

- fast re-render after editing `config.yaml`, templates, or column maps
- offline workbook regeneration when the Jamf server is unavailable
- "I just collected, now I want a new workbook" loops

If no cached snapshots exist (fresh workspace), the run fails with a clear
"no cached data" error rather than silently producing an empty workbook.

### `jamf-cli-full`

Use when you want a self-contained scheduled run that does not depend on a CSV.

What it does:

- runs `collect` to refresh `jamf-cli` JSON snapshots
- runs `generate` without a CSV
- writes the daily Trends summary as a side effect of collect

Best for:

- fully API-driven recurring reports
- environments without emailed Jamf inventory exports
- admins who want one scheduled job to refresh both workbook inputs and snapshots

### `csv-assisted`

Use when a CSV export is required for the workbook to be complete (custom
inventory columns `jamf-cli` cannot reach, vendor-specific fields, etc.).

What it does:

- requires a `.csv` in the configured `csv-inbox/` directory (newest wins)
- runs `collect` to refresh `jamf-cli` JSON snapshots
- runs `generate --csv <that file>` to combine both data sources

Best for:

- orgs that already receive Jamf exports by email or sync folder
- workflows where the CSV contains columns nothing else can supply
- jobs where missing CSV should fail loudly rather than silently degrade

Important behavior (PR-21):

- the run hard-fails if `csv-inbox/` has no `.csv` file. Earlier versions
  silently fell back to a jamf-cli-only workbook, which masked broken CSV
  drops for days at a time. If you want the silent-fallback behavior, use
  `jamf-cli-full` explicitly instead.
- a malformed CSV is not silently ignored — `generate` fails the run.

### Mode parity between Python and Swift

| Mode            | Swift app (GUI Schedules + LaunchAgent)         | Python `launchagent-setup` (legacy) |
|-----------------|--------------------------------------------------|-------------------------------------|
| snapshot-only   | collect + Trends summary, no workbook            | collect + optional `automation.*` artifacts |
| jamf-cli-only   | generate from cache only, NO collect             | runs `generate` without `--csv` (with collect side-effects) |
| jamf-cli-full   | collect + generate, no CSV                       | runs `inventory-csv` + `collect` + `generate --csv <inventory>` |
| csv-assisted    | collect + generate, **CSV required (hard fail)** | collect + generate, **fallback to jamf-cli-only when no CSV** |

If you author plists by hand, follow the Swift contract — the parser in the
GUI honors `--mode <rawValue>` (snapshot-only / jamf-cli-only / jamf-cli-full /
csv-assisted) in `ProgramArguments`. Plists written before PR-20 omit `--mode`
and default to jamf-cli-only at run time.

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
