# Dashboards

The app organizes its screens into sidebar groups. This page is a tour of each group.
Every non-core screen can be hidden from **Settings → Sidebar Visibility**; the core
screens (Overview, Devices, Data Sources, Settings) cannot be hidden.

Most dashboards read cached `jamf-cli` snapshots already on disk — opening a dashboard
does not issue new API calls. Data is refreshed by collection (see
[Scheduling & Automation](05-Scheduling-and-Automation)).

## Reports

![Fleet Overview](images/overview.png)

- **Overview** — the fleet home screen: headline KPIs, an OS-distribution donut, top
  failing compliance rules, security-agent coverage, and recent activity.
- **Fleet Overview** — a multi-profile roll-up: one card per workspace with per-profile
  health signals, so MSPs and teams can scan every tenant at once.
- **Devices** — the device inventory table with search, sort, and a Priority Action
  filter. The detail panel shows a per-device risk breakdown.
- **Device Lookup** — find one device by serial, hostname, asset tag, or ID.
- **Trends** — historical charts over archived snapshots. See
  [Historical Trends](06-Historical-Trends).
- **Health Audit** — instance health findings plus computer-group hygiene (empty and
  unused smart/static groups).
- **Generated** — the library of reports already produced, with actions to generate new
  workbooks, HTML reports, and inventory CSVs.

![Devices](images/devices.png)

## Posture

![Security Posture](images/security-posture.png)

- **Security Posture** — a weighted Security Score ring, per-control KPIs (FileVault,
  SIP, firewall, Gatekeeper), prioritized action items, and an OS-version donut.
- **Compliance Posture** — a compliance-band distribution donut (Pass / Low / Med-Low /
  Medium / High / No Data), control-coverage gaps, and a per-OS breakdown.
- **Compliance Benchmarks** — per-benchmark compliance rates and device counts from the
  Jamf Platform API. Experimental; requires `platform.enabled: true`,
  `experimental.platform_features_enabled: true`, and a platform-auth jamf-cli profile.
  Shows a locked state when the Platform API gate is closed.
- **Offline Outreach** — stale devices bucketed into outreach tiers (31–90 / 91–180 /
  180+ days) with a one-click clipboard mail-merge of the affected users.

## Operations

![Patch Compliance](images/patch-compliance.png)

- **Patch Compliance** — per-title patch compliance with a failures drawer; exports to
  CSV and PNG.
- **OS Updates** — managed software-update plan state, failed plans, and devices in an
  error state.
- **DDM Blueprints** — Declarative Device Management blueprint deployment status and
  declaration details from the Jamf Platform API. Experimental; requires the same three
  Platform API gates as Compliance Benchmarks above. Shows a locked state when the gate
  is closed.
- **Policies & Profiles** — a two-tab screen: policy configuration findings, and
  configuration-profile deployment status.
- **Extension Attributes** — per-EA coverage (percent of fleet populated) and top-value
  distributions.

## Fleet

![Mobile Fleet](images/mobile-fleet.png)

- **Mobile Fleet** — iOS/iPadOS device counts, compliance signals, OS-version
  distribution, and a device/profile inventory.
- **Jamf Protect** — Protect alerts, agent health, and insights. Shows an explicit
  "Protect not detected" state for tenants that do not run Jamf Protect.

## Automation

- **Schedules** — create and manage LaunchAgent jobs for unattended collection and
  reporting. See [Scheduling & Automation](05-Scheduling-and-Automation).
- **Run History** — streamed output from past collect and generate runs.

## Configuration

- **Config** — the `config.yaml` editor. See
  [Configuration & Templates](04-Configuration-and-Templates).
- **Customize** — choose which sheets a generated workbook includes and which metrics the
  Overview score cards show.
- **Data Sources** — the inputs surface: cached `jamf-cli` data, the CSV inbox, and
  snapshot status.
- **Backups** — snapshot and compare Jamf Pro configuration backups.

## System

- **Settings** — app preferences: the jamf-cli install/update check, connections, the
  collection-cadence preset, diagnostics, and Sidebar Visibility.
