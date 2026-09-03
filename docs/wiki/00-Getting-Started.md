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
partial-failure handling; the app itself currently tracks v1.28.0. On jamf-cli 1.24.0
through 1.27.0, the security report requires a Jamf Security Cloud subscription (see Known
Issues in the CHANGELOG) — this is fixed in 1.28.0, so upgrade to restore Security Posture,
the security score and the FileVault, SIP, firewall and Gatekeeper figures. Tenants that
cannot upgrade past 1.27.0 should pin jamf-cli to 1.23.x instead. See
[Installation](https://github.com/tonyyo11/jamf-reports-community/wiki/01-Installation) for the full requirements table and pre-built binary
links.

jamf-cli is optional — the app also works from a Jamf Pro CSV export and cached
snapshots with no jamf-cli installed. If you're skipping it, go to step 4.

**Only use Jamf School?** On the Welcome chooser, choose **Connect Jamf School** — a
dedicated path that skips the Jamf Pro Authenticate and Validate steps and connects your
Jamf School tenant (Network ID + API key) directly, then routes reports to the Jamf School
engine (see [Jamf School](https://github.com/tonyyo11/jamf-reports-community/wiki/08-Jamf-School)).
jamf-cli still has to be *installed* to pass the Install CLI step (a free Homebrew binary,
no Jamf Pro server access needed), but you never enter Jamf Pro credentials. Jamf School
support ships community-validated — the maintainer has no Jamf School tenant to test
against, so please report anything that looks off.

**Only have a CSV export?** jamf-cli still has to be *installed* to get through the Install
CLI step — Next stays disabled until the app detects it on `PATH` — even if you never
connect it to a real Jamf Pro tenant. The Authenticate step accepts a URL plus placeholder
client ID/secret without contacting the server, and Validate lets you continue even when
the connection check reports failure, so you can complete onboarding with placeholder Jamf
Pro credentials and map a CSV at the CSV step. (Installs set up before the Connect Jamf
School card can still use this same placeholder workaround, then connect Jamf School at
**Add products**.)
One honest caveat: scheduling and automation always collect via jamf-cli, so a CSV-only
workspace can't use managed automation, alerts, or the dead-man switch — reports there
are a manual export-CSV-then-Generate cycle.

## 3. Create a read-only API role

`jamf-cli pro setup` (used in the next step) can create the API client for you, or you
can create one yourself in Jamf Pro first. Either way, use a **read-only** role — this
project only reads data. See [Installation → Jamf Pro API permissions](https://github.com/tonyyo11/jamf-reports-community/wiki/01-Installation)
for the exact privilege table.

## 4. Launch the app and start onboarding

Open `JamfReports.app`. On first launch you'll see a **Welcome chooser** with three
cards — **Connect Jamf Pro**, **Connect Jamf School**, and **Try the demo first**.
Choose **Connect Jamf Pro** to start the guided onboarding flow (Jamf School-only
districts pick **Connect Jamf School** instead).

## 5. Follow the onboarding steps

The flow walks through eight steps — see [App Onboarding](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding) for the
full detail on each:

1. **Welcome** — a short intro to what onboarding will do.
2. **Install CLI** — confirms `jamf-cli` is installed and on `PATH` (shows the install
   command if not).
3. **Workspace** — pick a short, lowercase profile name (for example `prod`). This
   becomes the workspace folder under `~/Jamf-Reports/<profile>/`. That location is
   the default, not a fixed one: **Settings → Workspace location** can move it to a
   shared team folder so several Macs build one pooled history — see
   [Security & Operational Considerations](/wiki/10-Security-and-Operational-Considerations).
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
