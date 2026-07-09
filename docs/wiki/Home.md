# jamf-reports-community

Fleet reporting for Jamf Pro and Jamf School — a native macOS app. This wiki is the full
setup and operating guide; the [README](https://github.com/tonyyo11/jamf-reports-community)
is the short overview.

![Jamf Reports — Fleet Overview](images/overview.png)

## Getting started

A native SwiftUI app (macOS 14+) that collects data, generates reports, schedules
unattended runs, and tracks fleet health — all from a GUI. Read these pages in order:

1. [Getting Started](00-Getting-Started) — zero-context path to a first report
2. [Installation](01-Installation) — install the app and `jamf-cli`
3. [App Onboarding](02-App-Onboarding) — the guided first run
4. [Dashboards](03-App-Dashboards) — a tour of every screen
5. [AI Insights](03b-AI-Insights) — on-device fleet insights (macOS 27+)
6. [Configuration & Templates](04-Configuration-and-Templates) — `config.yaml`, custom EAs, report templates
7. [Scheduling & Automation](05-Scheduling-and-Automation) — run modes and LaunchAgent jobs
8. [Automation Trust](05b-Automation-Trust) — metric alerts and the automation dead-man switch
9. [Historical Trends](06-Historical-Trends) — snapshots and the Trends screen
10. [Patch Velocity](06b-Patch-Velocity) — adoption speed and days-behind tracking
11. [Command Line](07-Command-Line) — the included `jamf-reports` CLI for scripting
12. [Data Provenance](11-Data-Provenance) — what each dashboard's numbers are based on

### Reference for everyone

- [Jamf School](08-Jamf-School) — if you manage a Jamf School tenant
- [Diagnostics & Troubleshooting](09-Diagnostics-and-Troubleshooting)
- [Security & Operational Considerations](10-Security-and-Operational-Considerations)
- [Custom EA Examples](12-Custom-EA-Examples) — worked examples for adding custom Extension Attributes
- [Glossary](Glossary)

## What jamf-reports-community does not replace

For one-off API actions, direct inventory lookups, or broader Jamf automation, use
`jamf-cli` directly:

- [Jamf Concepts jamf-cli site](https://concepts.jamf.com/jamf-cli/)
- [jamf-cli Documentation Wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki)
- [jamf-cli README](https://github.com/Jamf-Concepts/jamf-cli)
- [jamf-cli Setup Guide](https://github.com/Jamf-Concepts/jamf-cli/wiki/Setup-Guide)
- [jamf-cli Configuration & Profiles](https://github.com/Jamf-Concepts/jamf-cli/wiki/Configuration-&-Profiles)

Use `jamf-reports-community` when the goal is recurring reporting, workbook generation,
visualization, or historical snapshots.
