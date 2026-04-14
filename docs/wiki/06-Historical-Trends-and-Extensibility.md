# Historical Trends and Extensibility

## Why History Matters

Jamf Pro gives you current state. Reporting programs need point-in-time history.

That is the core model behind `jamf-reports-community`: save snapshots as you run them,
then build timelines from those snapshots later. Do not expect Jamf to reconstruct every
past state for you on demand.

Use two historical stores on purpose:

- CSV snapshot history for export-shaped inventory, extension attributes, and compliance
  detail that only exists in your Advanced Search or Search Inventory export.
- `jamf-cli` JSON snapshot history for API-native summaries such as Fleet Overview,
  Inventory Summary, Security Posture, Device Compliance, EA Coverage, and Software
  Installs.

Those stores complement each other. They are not interchangeable.

## Recommended Historical Layout

```text
Jamf Reports/
├── config.yaml
├── Jamf Reports/
│   ├── weekly_inventory_2026-04-05_090000.csv
│   └── monthly_inventory_2026-04-30_170000.csv
├── snapshots/
│   ├── weekly_inventory_2026-04-05_090000.csv
│   ├── weekly_inventory_2026-04-12_090000.csv
│   └── monthly_inventory_2026-04-30_170000.csv
├── jamf-cli-data/
│   ├── prod/
│   │   ├── inventory-summary/
│   │   ├── device-compliance/
│   │   ├── security/
│   │   └── ea-results/
│   └── dummy/
└── Generated Reports/
    ├── jamf_report_csv_plus_jamf_cli_2026-04-05_090000.xlsx
    ├── jamf_report_csv_plus_jamf_cli_2026-04-05_090000_adoption_timeline.png
    └── archive/
```

Key rules:

- Treat `snapshots/` and `jamf-cli-data/` as append-only historical stores.
- Let generated reports be disposable. They can be archived for cleanliness.
- Keep one directory per tenant or jamf-cli profile when multiple instances exist.
- Timestamp everything you want to compare later.

## What One Snapshot Means

One saved CSV or one saved jamf-cli JSON file equals one point in time.

That has practical consequences:

- Weekly collection gives you weekly trend points.
- Daily collection gives you daily trend points.
- Ad-hoc collections create irregular timelines, which are still useful for investigations
  but less ideal for recurring leadership dashboards.

If you care about trend quality, collection cadence matters as much as chart logic.

## CSV History vs jamf-cli History

### CSV history is for rich detail

Use CSV snapshots when you need:

- Extension Attribute visualizations
- Compliance counts and failed-rule lists
- Department, manager, and user slicing
- Any field that only exists in your saved Jamf Pro export shape

This is the right historical source for:

- mSCP or STIG trend reporting
- EA-based version tracking
- Expiring certificate or profile analysis
- Manager or department-targeted remediation reports

### jamf-cli history is for API-native summaries

Use jamf-cli JSON history when you need:

- OS adoption from `inventory-summary`
- Device freshness and managed-state trends from `device-compliance`
- Security posture summaries from `security`
- EA coverage and definition drift from `ea-results` and extension-attribute metadata

This is the right historical source for:

- jamf-cli-only reporting
- Offline reruns when live auth is unavailable
- Fast recurring collections that do not depend on Jamf UI exports

## Building Weekly Reporting

A solid weekly operating model looks like this:

1. Refresh source data.
2. Run `collect` to save jamf-cli JSON history.
3. Save or export the current CSV if you need EA/compliance detail.
4. Run `generate`.
5. Review stale devices, compliance deltas, agent gaps, and adoption movement.
6. Hand off action items by manager, department, or owning team.

Suggested weekly focus:

- Current vs stale device movement
- Security-control regressions
- New compliance failures
- EA population drift
- Patch or software outliers

## Building Monthly Reporting

Monthly reporting usually needs more stability than weekly triage.

Recommended pattern:

- Keep a month-end CSV snapshot even if you also collect weekly.
- Generate a dedicated month-end workbook for leadership.
- Compare month-end snapshots against the prior month instead of mixing arbitrary daily
  points into the same story.
- Use weekly runs for remediation and monthly runs for trend communication.

Good monthly themes:

- macOS adoption movement
- compliance trend over the month
- stale-device reduction
- security-agent coverage changes
- EA coverage maturity

## Ad-hoc Investigations

Ad-hoc work is where mixed-source reporting is most useful.

Examples:

- Export a focused Advanced Computer Search for one business unit, then enrich the same
  run with jamf-cli summary sheets.
- Generate a jamf-cli-only workbook when you need a fast live view and do not care about
  CSV-only EAs.
- Use `inventory-csv` to bootstrap a baseline CSV without going into Jamf Pro first.

## Extending EA Visualization

The community edition should stay generic, but it is intentionally open to enhancement.

High-value extensions include:

- Coverage by EA category or naming prefix
- EA value drift over time
- top-value charts for text EAs
- boolean rollups by site, department, or manager
- version compliance views that compare observed values to known current versions
- date-based aging views for expiring tokens, profiles, or certificates

When designing EA visualizations, keep them reusable:

- Avoid hardcoding one organization's EA names in Python.
- Put thresholds and labels in `config.yaml`.
- Prefer charts that still work when an EA is missing or sparsely populated.

## Extending Compliance Visualization

The current community model is intentionally simple: failures count, failures list, and
trend bands.

Useful future extensions:

- per-rule failure trend tables
- top failing rules by department or manager
- pass/fail snapshots by OS major version
- exception-aware views for known carve-outs
- side-by-side comparison of multiple baselines
- compliance burn-down views for remediation sprints

This is a good area to keep building from CSV exports because many organizations store
compliance results in extension attributes rather than API-native Jamf objects.

## Future Directions

This repo is open sourced on purpose. It should be easy for admins to fork and extend.

Likely next areas for community growth:

- Jamf Protect data ingestion and visualization
- Jamf Platform API reporting as that surface matures
- richer historical metrics stores for week-over-week executive deltas
- GitHub Actions or CI-driven reporting workflows
- delivery integrations for Teams, Slack, email, or file shares

The [Jamf Platform API](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api)
is currently in public beta. This tool does not use it today — it uses jamf-cli, which
wraps the Classic and Pro APIs. Admins planning future integrations or tooling should
review the Platform API documentation as it matures.

One important constraint remains:

- The current community project has been tested on Jamf Pro only.

If you extend it for Protect or future Platform API data, document the tested surface
clearly so users know what is stable versus experimental.
