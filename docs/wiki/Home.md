# jamf-reports-community Wiki

This wiki set is the long-form companion to [COMMUNITY_README.md](https://github.com/tonyyo11/jamf-reports-community/blob/main/COMMUNITY_README.md).

Use it when you want a full setup and operating guide instead of a quick-start.

## What This Tool Covers

`jamf-reports-community` turns Jamf Pro inventory data into Excel workbooks, charts, and
repeatable reporting workflows.

It supports two primary data collection paths:

- Jamf Pro CSV exports
- `jamf-cli` live data plus cached JSON snapshots

It is built and tested against Jamf Pro. Jamf Protect support now exists as an
experimental, opt-in `Protect Overview` sheet driven by `jamf-cli 1.6`, but it has not
been fully validated against a live Protect tenant. Platform API workbook support is
also available as an opt-in preview when the selected jamf-cli build exposes the new
`pro report` platform commands.

This project is open sourced intentionally. The goal is to give Mac admins a practical
starting point they can extend for their own needs, including deeper Jamf Protect or
Jamf Platform API work.

## Suggested Reading Order

1. [Setup and Prerequisites](./01-Setup-and-Prerequisites.md)
2. [Jamf Pro CSV Workflow](./02-Jamf-Pro-CSV-Workflow.md)
3. [jamf-cli Workflow](./03-jamf-cli-Workflow.md)
4. [Config and Scaffolding](./04-Config-and-Scaffolding.md)
5. [Reporting Cadence and Operations](./05-Reporting-Cadence-and-Operations.md)
6. [Historical Trends and Extensibility](./06-Historical-Trends-and-Extensibility.md)
7. [LaunchAgent Automation](./07-LaunchAgent-Automation.md)

## Choose Your Starting Path

Use the Jamf Pro CSV workflow when:

- You already export Advanced Search or Search Inventory data
- You want full control over which extension attributes are present in the dataset
- You need a familiar, admin-friendly bootstrap path

Use the `jamf-cli` workflow when:

- You want to reduce reliance on Jamf UI exports
- You want API-driven summary sheets and cached snapshots
- You want a quick way to build a baseline CSV with `inventory-csv`
- You want a jamf-cli-only workbook or chart path

## What jamf-reports-community Does Not Replace

If you only need one-off API actions, direct inventory lookups, or broader Jamf
automation, go straight to `jamf-cli`:

- [Jamf Concepts jamf-cli site](https://concepts.jamf.com/jamf-cli/)
- [jamf-cli Documentation Wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki)
- [jamf-cli README](https://github.com/Jamf-Concepts/jamf-cli)
- [jamf-cli Setup Guide](https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide)
- [jamf-cli Configuration & Profiles](https://github.com/Jamf-Concepts/jamf-cli/wiki/Configuration-&-Profiles)
- [jamf-cli Command Reference](https://github.com/Jamf-Concepts/jamf-cli/wiki/Command-Reference)
- [jamf-cli Common Workflows](https://github.com/Jamf-Concepts/jamf-cli/wiki/Common-Workflows)

Use `jamf-reports-community` when the goal is recurring reporting, workbook generation,
visualization, or historical snapshots.

If your real objective is historical reporting, read the historical-trends page before
you automate anything. The quality of your charts depends on how intentionally you save
point-in-time snapshots.

If you want those snapshots and workbooks to happen on a real cadence, read the
LaunchAgent automation page next. That is the recommended local-macOS scheduling model
for this project.
