# jamf-cli Workflow

## When To Use This Path

Use the `jamf-cli` path when you want API-driven reporting and snapshot collection with
less dependence on Jamf Pro CSV exports.

Primary `jamf-cli` references:

- [Jamf Concepts jamf-cli site](https://concepts.jamf.com/jamf-cli/)
- [jamf-cli Documentation Wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki)

## What jamf-reports-community Uses From jamf-cli

Current high-value commands:

- `jamf-cli pro overview`
- `jamf-cli protect overview` (experimental workbook support)
- `jamf-cli protect computers list` (experimental workbook support)
- `jamf-cli protect analytics list` (experimental workbook support)
- `jamf-cli protect plans list` (experimental workbook support)
- `jamf-cli pro mobile-device-inventory-details list`
- `jamf-cli pro mobile-devices list`
- `jamf-cli pro classic-mobile-config-profiles list`
- `jamf-cli pro report inventory-summary`
- `jamf-cli pro report security`
- `jamf-cli pro report device-compliance`
- `jamf-cli pro report ea-results`
- `jamf-cli pro computer-extension-attributes list`
- `jamf-cli pro report software-installs`
- `jamf-cli pro report profile-status`
- `jamf-cli pro report app-status` (v1.2.0+)
- `jamf-cli pro report patch-status`
- `jamf-cli pro report update-status` (v1.2.0+)

The important design point is that `jamf-reports-community` uses jamf-cli in two ways:

- live collection for the current workbook or baseline CSV
- cached JSON snapshots as a historical store for offline reruns and jamf-cli-native
  charts

## Profile Setup

Interactive setup:

```bash
jamf-cli pro setup --url https://jamf.example.com
```

If you want the experimental Jamf Protect sheet as well:

```bash
jamf-cli protect setup
```

If you use multiple instances, keep profile names explicit and map them in
`jamf-reports-community` config:

```yaml
jamf_cli:
  profile: "prod"
  data_dir: "jamf-cli-data/prod"
```

Or for a dummy/testing tenant:

```yaml
jamf_cli:
  profile: "dummy"
  data_dir: "jamf-cli-data/dummy"
```

To opt into Protect reporting:

```yaml
protect:
  enabled: true
```

That path currently creates a single `Protect Overview` sheet. It is intentionally
defensive and based on the `jamf-cli 1.6` Protect commands, but it has not been fully
validated against a live Protect tenant.

If you want the filesystem layout created for you, bootstrap one workspace per profile:

```bash
python3 jamf-reports-community.py workspace-init \
    --profile prod \
    --workspace-root ~/Jamf-Reports
```

## Build a Baseline CSV From jamf-cli

Validate the profile first:

```bash
jamf-cli config validate -p yourprofile
```

This is the fastest way to bootstrap reporting without building a Jamf UI export first:

```bash
python3 jamf-reports-community.py inventory-csv --config config.yaml --out-file inventory.csv
```

That command combines:

- `jamf-cli pro computers list`
- `jamf-cli pro device <id>` for generic per-device security posture fields
- `jamf-cli pro report ea-results --all`

Use the resulting CSV as input for:

- `scaffold`
- `check`
- `generate`

This is the bridge between jamf-cli-only collection and the broader CSV-driven reporting
surface. It is the right move when you want security-agent, compliance, or custom-EA
visualizations without building a Jamf Pro export first.

Because the export now enriches each computer with generic security posture fields
(FileVault, SIP, firewall, Gatekeeper, bootstrap token states), a scaffolded config from
that CSV can populate the `Security Controls` sheet directly. Expect the command to run a
bit longer on larger fleets because it performs a per-device detail lookup.

`inventory-csv` is live-only. It does not reuse cached JSON snapshots, so validate auth
first if you plan to depend on it in automation.

## Collect Snapshots

Refresh API-backed JSON snapshots:

```bash
python3 jamf-reports-community.py inventory-csv --config config.yaml --out-file inventory.csv
python3 jamf-reports-community.py collect --config config.yaml --csv inventory.csv
```

This is the best command to schedule if you want offline reruns later.

Recommended pattern:

1. Run `collect` on a fixed cadence.
2. Keep `jamf-cli-data/<profile>/` append-only.
3. Use `inventory-csv` when you need a CSV-shaped baseline for scaffolded reporting.
4. Use `generate` with or without `--csv` depending on the run type.

If you want to schedule that cadence on a Mac, use
`python3 jamf-reports-community.py launchagent-setup --config config.yaml`.
That LaunchAgent path is designed to preserve the same user-scoped `jamf-cli` profile and
config context that you use interactively.

## Generate a Workbook

```bash
python3 jamf-reports-community.py inventory-csv --config config.yaml --out-file inventory.csv
python3 jamf-reports-community.py generate --config config.yaml --csv inventory.csv
```

For a jamf-cli-only workbook:

```bash
python3 jamf-reports-community.py generate --config config.yaml --out-file jamf_report_jamf_cli_only.xlsx
```

For a jamf-cli-only workbook plus a baseline CSV you can scaffold later:

```bash
python3 jamf-reports-community.py inventory-csv --config config.yaml
python3 jamf-reports-community.py generate --config config.yaml
```

With `jamf-cli` available, the workbook can include:

- Fleet Overview
- Protect Overview (experimental, opt-in)
- Mobile Fleet Summary
- Inventory Summary
- Mobile Inventory
- Security Posture
- Device Compliance
- EA Coverage
- EA Definitions
- Software Installs
- Policy Health
- Profile Status
- Mobile Config Profiles
- App Status (v1.2.0+)
- Patch Compliance
- Update Status (v1.2.0+)
- Report Sources

And the Charts sheet can now use jamf-cli snapshot history for:

- macOS adoption from `inventory-summary`
- device state trend from `device-compliance`

That means a jamf-cli-only reporting path is now practical even before you decide whether
to keep a CSV export workflow.

## collect vs generate — When to Use Each

**`collect`** saves live jamf-cli JSON snapshots to `jamf_cli.data_dir`. It does not
produce a workbook. Use it to:

- Build up historical snapshot files for offline reruns
- Separate the live API call (which needs auth) from report generation (which can use cache)
- Run on a schedule (cron or LaunchAgent) independently of report generation
- Archive a dated CSV copy alongside the JSON snapshots

**`generate`** reads from already-saved snapshots (when `use_cached_data: true`) and
optionally refreshes live data. Use it to:

- Produce the Excel workbook
- Combine jamf-cli-sourced sheets with CSV-sourced sheets in one artifact
- Trigger a fresh live pull when you need current data without a separate collect step

Recommended pattern for scheduled reporting:

1. Run `collect` nightly to refresh snapshots.
2. Run `generate` weekly (or on demand) to produce the workbook from saved data.
3. Keep `use_cached_data: true` so `generate` never fails due to a momentary auth issue.
4. Use `inventory-csv` only when you need a fresh CSV baseline and know live auth is good.

## Where To Use jamf-cli Directly

If you do not need a workbook or chart output, use `jamf-cli` directly instead of routing
through this project.

Examples:

- One-off inventory exports
- Device deep-dive lookups
- API automation and object management
- Manual administrative actions
- Multi-profile or multi-instance operational tasks

Recommended references:

- [Jamf Concepts jamf-cli site](https://concepts.jamf.com/jamf-cli/)
- [jamf-cli Documentation Wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki)
- [jamf-cli Command Reference](https://github.com/Jamf-Concepts/jamf-cli/wiki/Command-Reference)
- [jamf-cli Common Workflows](https://github.com/Jamf-Concepts/jamf-cli/wiki/Common-Workflows)
- [jamf-cli Output Formats](https://github.com/Jamf-Concepts/jamf-cli/wiki/Output-Formats)

Use jamf-cli directly for object management, device deep dives, and API operations that do
not need workbook packaging. Use `jamf-reports-community` when the goal is to save history,
normalize recurring output, and turn multiple data pulls into one reporting artifact.
