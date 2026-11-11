# Getting Started

A step-by-step path from "never seen this project" to a first generated report, for a
Mac admin who already has a Jamf Pro tenant. Each step links to the page with the full
detail — this page is the one path through them in order.

## 1. Download the app

Get the latest notarized `.dmg` or `.pkg` from the
[Releases page](https://github.com/tonyyo11/jamf-reports-community/releases). Either
installs `JamfReports.app` — no Xcode or source build required.

## 2. Install jamf-cli

`jamf-cli` is Jamf's official command-line interface and powers live data collection.
Install it with Homebrew:

```bash
brew install Jamf-Concepts/tap/jamf-cli
```

This project needs jamf-cli v1.29.0 or later. With an older jamf-cli, collect, backup and
scheduled runs stop with a message to update it (Settings says the same); a scheduled
run that only generates from cached data does not call jamf-cli and is not stopped. See
[Installation](https://github.com/tonyyo11/jamf-reports-community/wiki/01-Installation) for the full requirements table and pre-built binary
links.

jamf-cli is required: every collect, backup and scheduled collect goes through it. Without it
the app can only show demo mode, or build reports from snapshots already in a workspace.

**Only use Jamf School?** On the Welcome chooser, choose **Connect Jamf School** — a
dedicated path that skips the Jamf Pro Authenticate and Validate steps and connects your
Jamf School tenant (Network ID + API key) directly, then routes reports to the Jamf School
engine (see [Jamf School](https://github.com/tonyyo11/jamf-reports-community/wiki/08-Jamf-School)).
jamf-cli still has to be *installed* to pass the Install CLI step (a free Homebrew binary,
no Jamf Pro server access needed), but you never enter Jamf Pro credentials. If anything in
Jamf School support looks off, please report it.

**No CSV mode.** Reports are built from jamf-cli data. The CSV report mode, the CSV
mapping step and the `csv-inbox` folder were retired in 2.11; see
[Running without jamf-cli credentials](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding#running-without-jamf-cli-credentials)
for what onboarding needs.

## 3. Create a read-only API role

A direct Jamf Pro profile (`jamf-cli pro setup`, used in the next step) takes an API client
you create yourself in Jamf Pro first, which jamf-cli 1.29 and later ask for by default. On
Jamf Cloud, jamf-cli recommends a Jamf Account integration at the environment level instead
(`jamf-cli platform setup`). Either way, use a **read-only** role — this
project only reads data. See [Installation → Jamf Pro API permissions](https://github.com/tonyyo11/jamf-reports-community/wiki/01-Installation)
for the exact privilege table.

## 4. Launch the app and start onboarding

Open `JamfReports.app`. On first launch you'll see a **Welcome chooser** with four
cards: **Connect with Jamf Account** (recommended for Jamf Cloud), **Connect a Jamf Pro
server**, **Connect Jamf School**, and **Try the demo first**.
Choose **Connect Jamf Pro** to start the guided onboarding flow (Jamf School-only
districts pick **Connect Jamf School** instead).

## 5. Follow the onboarding steps

The flow walks through seven steps — see [App Onboarding](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding) for the
full detail on each:

1. **Welcome** — a short intro to what onboarding will do.
2. **Install CLI** — confirms `jamf-cli` is installed and on `PATH` (shows the install
   command if not).
3. **Workspace** — pick a short profile name (for example `prod`). This
   becomes the workspace folder under `~/Jamf-Reports/<profile>/`. That location is
   the default, not a fixed one: **Settings → Workspace location** can move it to a
   shared team folder so several Macs build one pooled history — see
   [Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations).
4. **Authenticate** — connect with a Jamf Account integration (Platform API, recommended
   for Jamf Cloud; pick a region and enter the environment ID) or with your Jamf Pro API
   client credentials (OAuth2, for on-prem, GovCloud or any instance). The secret is
   never persisted by the app; setup has `jamf-cli` store the credentials in the macOS keychain
   and tokens are cached on disk.
5. **Validate** — the app confirms the connection works.
6. **Add products (optional)** — connect Jamf Protect here if you use it, or skip and add it
   later from the Data Sources screen. Jamf School uses its own workspace.
7. **First report** — for Jamf Pro, the app collects a snapshot (refresh and inventory
   data, not the per-device scans) and then generates a first report, so the dashboards
   have data to show. For Jamf School, this step only generates.

## 6. Your first collect and report

Step 7 above already ran a first collect and generate for you, on the Jamf Pro path. The
per-device scans (patch and update failure detail, DDM status, MDM command history) haven't
run yet — they run on the weekly schedule, or on demand via **Collect now** on Overview. From here on, use the
**Collect now** and **Generate Report** buttons on the Overview screen whenever you want
fresh data or a new report, or set up
[Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation) to run unattended.

## 7. Find your report

Generated workbooks and HTML reports land in:

```text
~/Jamf-Reports/<profile>/Generated Reports/
```

Open the folder from the **Generated** tab in the sidebar, or find it directly in
Finder.

## Where to go next

- [Dashboards](https://github.com/tonyyo11/jamf-reports-community/wiki/03-App-Dashboards) — a tour of every screen the app generates.
- [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust) — metric alerts and the dead-man switch for
  scheduled runs.
- [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates) — tune `config.yaml` for
  your fleet.
- [Period Reports](https://github.com/tonyyo11/jamf-reports-community/wiki/06c-Period-Reports) — once a few weeks of history exist, the
  start/end/change figures a quarterly write-up needs.
