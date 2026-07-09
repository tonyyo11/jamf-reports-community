# Getting Started

A step-by-step path from "never seen this project" to a first generated report, for a
Mac admin who already has a Jamf Pro tenant. Each step links to the page with the full
detail — this page is the one path through them in order.

## 1. Download the app

Get the latest notarized `.dmg` or `.pkg` from the
[Releases page](https://github.com/tonyyo11/jamf-reports-community/releases). Either
installs `JamfReports.app` — no Xcode or source build required.

## 2. Install jamf-cli (optional, recommended)

`jamf-cli` is Jamf's official command-line interface and powers live data collection.
Install it with Homebrew:

```bash
brew install Jamf-Concepts/tap/jamf-cli
```

This project supports jamf-cli v1.18.0 or later, with v1.19.0+ recommended for full
partial-failure handling; the app itself currently tracks v1.22.0. See
[Installation](01-Installation) for the full requirements table and pre-built binary
links.

jamf-cli is optional — the app also works from a Jamf Pro CSV export and cached
snapshots with no jamf-cli installed. If you're skipping it, go to step 4.

## 3. Create a read-only API role

`jamf-cli pro setup` (used in the next step) can create the API client for you, or you
can create one yourself in Jamf Pro first. Either way, use a **read-only** role — this
project only reads data. See [Installation → Jamf Pro API permissions](01-Installation)
for the exact privilege table.

## 4. Launch the app and start onboarding

Open `JamfReports.app`. On first launch you'll see a **Welcome chooser** with two
cards — **Connect Jamf Pro** and **Try the demo first**. Choose **Connect Jamf Pro** to
start the guided onboarding flow.

## 5. Follow the onboarding steps

The flow walks through eight steps — see [App Onboarding](02-App-Onboarding) for the
full detail on each:

1. **Welcome** — a short intro to what onboarding will do.
2. **Install CLI** — confirms `jamf-cli` is installed and on `PATH` (shows the install
   command if not).
3. **Workspace** — pick a short, lowercase profile name (for example `prod`). This
   becomes the workspace folder under `~/Jamf-Reports/<profile>/`.
4. **Authenticate** — connect Jamf Pro with your API client credentials (or a Platform
   Gateway tenant ID). The secret is never persisted by the app; `jamf-cli` stores the
   resulting token in the macOS keychain.
5. **Validate** — the app confirms the connection works.
6. **CSV mapping** — optionally add a Jamf Pro CSV export for the sheets that need
   per-device export columns (Stale Devices, Security Agents, custom Extension
   Attributes). You can **Skip for now** and add one later.
7. **Add products (optional)** — connect Jamf Protect or Jamf School here if you use
   them, or skip and add them later from the Data Sources screen.
8. **First report** — the app generates a first report so the dashboards have data to
   show.

## 6. Your first collect and report

Step 8 above already ran a first collect and generate for you. From here on, use the
**Collect now** and **Generate Report** buttons on the Overview screen whenever you want
fresh data or a new report, or set up
[Scheduling & Automation](05-Scheduling-and-Automation) to run unattended.

## 7. Find your report

Generated workbooks and HTML reports land in:

```text
~/Jamf-Reports/<profile>/Generated Reports/
```

Open the folder from the **Generated** tab in the sidebar, or find it directly in
Finder.

## Where to go next

- [Dashboards](03-App-Dashboards) — a tour of every screen the app generates.
- [Automation Trust](05b-Automation-Trust) — metric alerts and the dead-man switch for
  scheduled runs.
- [Configuration & Templates](04-Configuration-and-Templates) — tune `config.yaml` for
  your fleet.
