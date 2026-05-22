# jamf-reports-community

Fleet reporting for Jamf Pro and Jamf School — a native macOS app, with an optional
Python CLI for headless and automated use. This wiki is the full setup and operating
guide; the [README](https://github.com/tonyyo11/jamf-reports-community) is the short
overview.

There are two ways to run the project. **The macOS app is the recommended path.** The
Python CLI is the optional path for headless servers, CI and Linux environments, and
scripted automation.

![Jamf Reports — Fleet Overview](images/overview.png)

## Pick your path

### The macOS app — recommended

A native SwiftUI app (macOS 14+) that collects data, generates reports, schedules
unattended runs, and tracks fleet health — all from a GUI, with no Python required. Read
these pages in order:

1. [Installation](01-Installation) — install the app and `jamf-cli`
2. [App Onboarding](02-App-Onboarding) — the guided first run
3. [Dashboards](03-App-Dashboards) — a tour of every screen
4. [Configuration & Templates](04-Configuration-and-Templates) — `config.yaml`, custom EAs, report templates
5. [Scheduling & Automation](05-Scheduling-and-Automation) — run modes and LaunchAgent jobs
6. [Historical Trends](06-Historical-Trends) — snapshots and the Trends screen

### The Python CLI — optional

A single-file script for headless and automated reporting. Read:

1. [Installation](01-Installation) — the Requirements section
2. [CLI Workflow](07-CLI-Workflow) — install, commands, the CSV and jamf-cli paths

### Reference for everyone

- [Jamf School](08-Jamf-School) — if you manage a Jamf School tenant
- [Diagnostics & Troubleshooting](09-Diagnostics-and-Troubleshooting)
- [Glossary](Glossary)

## Try it offline

No live Jamf tenant or credentials needed — the repo ships demo fixtures:

```bash
./scripts/demo.sh          # build every offline demo report
./scripts/demo.sh html     # or just one: html | xlsx | mobile | school
```

Output lands in `Generated Reports/demo/`.

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
