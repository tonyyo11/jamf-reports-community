# Reporting Cadence and Operations

## Weekly Reporting

A practical weekly run looks like this:

1. Refresh your source data
2. Save the latest CSV export or run `collect`
3. Archive the CSV if you want trend charts
4. Generate the workbook
5. Deliver the workbook or derived summary to stakeholders

Example:

```bash
python3 jamf-reports-community.py collect --config config.yaml --csv inventory.csv
python3 jamf-reports-community.py generate --config config.yaml --csv inventory.csv --historical-csv-dir snapshots/
```

Weekly is the right rhythm for:

- stale-device review
- compliance remediation sprints
- agent coverage gaps
- software outlier cleanup
- checking whether adoption is moving in the expected direction

## Monthly Reporting

Monthly runs usually benefit from:

- A dedicated month-end CSV snapshot
- A consistent output name
- A retained workbook archive
- Trend charts built from a snapshots directory

Use month-end exports for leadership reporting and weekly runs for operational triage.

If you want clean month-over-month comparisons, keep a deliberate month-end snapshot even
if you also collect weekly. Mixing arbitrary ad-hoc snapshots into leadership trend lines
usually makes the story harder to explain.

## Ad-hoc Reporting

Use ad-hoc runs for:

- Security review requests
- Leadership questions
- Audit preparation
- Migration planning
- EA cleanup or validation work

For ad-hoc work, it is often better to:

- Build a focused CSV
- Reuse an existing config where possible
- Create a temporary output file
- Name outputs clearly as `csv_plus_jamf_cli` or `jamf_cli_only`

The jamf-cli-only path is useful here. If you do not need your full Advanced Search shape,
generate a fast workbook from cached or live jamf-cli data and keep the CSV workflow for
deeper EA and compliance analysis.

## Snapshot Strategy

Recommended pattern:

- Keep live `jamf-cli` snapshots under `jamf-cli-data/<profile>/`
- Keep dated CSV snapshots under `snapshots/`
- Keep generated workbooks under `Generated Reports/`
- Let the tool archive older generated runs so the active output folder stays readable

This separation makes it easy to rerun reports later and explain where each output came
from.

Important distinction:

- CSV snapshots are your long-term trend source for export-driven data.
- jamf-cli JSON snapshots are your long-term trend source for jamf-cli-native sheets and
  charts.
- Generated xlsx and PNG files are output artifacts, not the authoritative historical
  store.

## Historical Trend Discipline

One snapshot equals one point in time.

That means:

- if you collect weekly, your charts show weekly movement
- if you collect monthly, your charts show monthly movement
- if you collect irregularly, your charts show irregular movement

This sounds obvious, but it is the core operating rule behind useful historical reporting.
If you want trustworthy trend lines, build the collection cadence first.

For EA-heavy or compliance-heavy reporting, preserve CSV history.

For jamf-cli-native reporting, preserve `inventory-summary`, `device-compliance`,
`security`, and other JSON histories under `jamf-cli-data/`.

## Output Cleanup and Archiving

Timestamped outputs are useful only if the active folder stays manageable.

The community script now supports an output cleanup model:

- new workbooks and inventory CSVs are timestamped
- chart PNGs inherit the workbook stem as a prefix
- older runs can be moved into an archive folder automatically
- historical CSV snapshots and jamf-cli JSON snapshots remain separate so you do not
  accidentally prune your real trend history

Recommended stance:

- keep generated output folders tidy
- keep historical data stores append-only
- prune only after you understand what data you still need for trend lines

## Delivery Models

There is no single right operating model. Common options:

- Run locally on demand
- Schedule on an admin workstation or utility host
- Run inside CI with secrets from environment variables
- Trigger manually through GitHub Actions for controlled ad-hoc runs

## GitHub Actions As A Future Pattern

One good future operating model is a set of manually triggered GitHub Actions workflows.

Why it can work well:

- Admins can run a report on demand without local Python setup
- Credentials stay in CI secrets instead of personal shells
- Outputs can be emailed, uploaded, or forwarded to Slack or Teams
- Hosted runners avoid tying reporting to a single Mac

This repo does not implement those workflows yet, but the model fits both
`jamf-cli` and `jamf-reports-community`.

This aligns with the direction from the jamf-cli maintainer: lightweight manual-trigger
workflows, credentials in CI secrets, and output delivery handled by the workflow instead
of by an admin laptop.

## Security Guidance

Prefer these patterns:

- Interactive `jamf-cli pro setup` for local admin use
- Environment variables only for automation
- Separate profiles and snapshot directories per tenant
- Least-privilege API roles where possible

If you only need direct API data collection or one-off admin operations, use `jamf-cli`
alone and follow its documentation:

- [Jamf Concepts jamf-cli site](https://concepts.jamf.com/jamf-cli/)
- [jamf-cli Documentation Wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki)
- [Setup Guide](https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide)
- [Configuration & Profiles](https://github.com/Jamf-Concepts/jamf-cli/wiki/Configuration-&-Profiles)
- [Common Workflows](https://github.com/Jamf-Concepts/jamf-cli/wiki/Common-Workflows)
