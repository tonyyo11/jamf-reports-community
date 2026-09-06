# jamf-reports-community

Fleet reporting for Jamf Pro and Jamf School — a native macOS app. This wiki is the full
setup and operating guide; the [README](https://github.com/tonyyo11/jamf-reports-community)
is the short overview.

![Jamf Reports — Fleet Overview](images/overview.png)

## Getting started

A native SwiftUI app (macOS 15+) that collects data, generates reports, schedules
unattended runs, and tracks fleet health — all from a GUI. Read these pages in order:

1. [Getting Started](https://github.com/tonyyo11/jamf-reports-community/wiki/00-Getting-Started) — zero-context path to a first report
2. [Installation](https://github.com/tonyyo11/jamf-reports-community/wiki/01-Installation) — install the app and `jamf-cli`
3. [App Onboarding](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding) — the guided first run
4. [Dashboards](https://github.com/tonyyo11/jamf-reports-community/wiki/03-App-Dashboards) — a tour of every screen
5. [AI Insights](https://github.com/tonyyo11/jamf-reports-community/wiki/03b-AI-Insights) — on-device fleet insights (macOS 27+)
6. [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates) — `config.yaml`, custom EAs, report templates
7. [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation) — run modes and the bundled background item
8. [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust) — metric alerts and the automation dead-man switch
9. [Historical Trends](https://github.com/tonyyo11/jamf-reports-community/wiki/06-Historical-Trends) — snapshots and the Trends screen
10. [Patch Velocity](https://github.com/tonyyo11/jamf-reports-community/wiki/06b-Patch-Velocity) — adoption speed and days-behind tracking
11. [Period Reports](https://github.com/tonyyo11/jamf-reports-community/wiki/06c-Period-Reports) — start/end/change figures for a quarter or any window
12. [Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line) — the included `jamf-reports` CLI for scripting
13. [Data Provenance](https://github.com/tonyyo11/jamf-reports-community/wiki/11-Data-Provenance) — what each dashboard's numbers are based on

### Reference for everyone

- [Jamf School](https://github.com/tonyyo11/jamf-reports-community/wiki/08-Jamf-School) — if you manage a Jamf School tenant
- [Diagnostics & Troubleshooting](https://github.com/tonyyo11/jamf-reports-community/wiki/09-Diagnostics-and-Troubleshooting)
- [Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations)
- [Custom EA Examples](https://github.com/tonyyo11/jamf-reports-community/wiki/12-Custom-EA-Examples) — worked examples for adding custom Extension Attributes
- [Glossary](https://github.com/tonyyo11/jamf-reports-community/wiki/Glossary)

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
