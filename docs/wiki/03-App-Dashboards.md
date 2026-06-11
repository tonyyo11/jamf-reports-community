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
  Data source: daily summary digest (tier 3) — see [Data Provenance](11-Data-Provenance).
- **Fleet Overview** — a multi-profile roll-up: one card per workspace with per-profile
  health signals, so MSPs and teams can scan every tenant at once.
  Data source: daily summary digest (tier 3) aggregated across profiles.
- **Devices** — the device inventory table with search, sort, and a Priority Action
  filter. The detail panel shows a per-device risk breakdown.
  Data source: per-device snapshots of computers and mobile-device inventory (tier 1).
- **Device Lookup** — find one device by serial, hostname, asset tag, or ID.
  Data source: per-device snapshot of computer detail from `pro device <id>` (tier 1).
- **Trends** — historical charts over archived snapshots. See
  [Historical Trends](06-Historical-Trends).
  Data source: daily summary digest (tier 3) over time; see Data Provenance for metric
  definitions.
- **Health Audit** — instance health findings plus computer-group hygiene (empty and
  unused smart/static groups).
  Data source: `pro report policy-status` (tier 2) and group lists (tier 1).
- **Generated** — the library of reports already produced, with actions to generate new
  workbooks, HTML reports, and inventory CSVs.
  Data source: generated report catalog (no single tier; see [Data Provenance](11-Data-Provenance) for report composition).

![Devices](images/devices.png)

## Posture

![Security Posture](images/security-posture.png)

- **Security Posture** — a weighted Security Score ring, per-control KPIs (FileVault,
  SIP, firewall, Gatekeeper), prioritized action items, and an OS-version donut.
  Data source: `pro report security` (tier 2) aggregates and device inventory (tier 1).
- **Compliance Posture** — a compliance-band distribution donut (Pass / Low / Med-Low /
  Medium / High / No Data), control-coverage gaps, and a per-OS breakdown.
  Data source: per-device EA results for mSCP/STIG baselines (tier 1) and device inventory
  (tier 1).
- **Compliance Benchmarks** — per-benchmark compliance rates and device counts from the
  Jamf Platform API. Experimental; requires `platform.enabled: true`,
  `experimental.platform_features_enabled: true`, and a platform-auth jamf-cli profile.
  Shows a locked state when the Platform API gate is closed.
  Data source: Jamf Platform API `compliance-devices` (tier 1) and device inventory (tier
  1).
- **Offline Outreach** — stale devices bucketed into outreach tiers (31–90 / 91–180 /
  180+ days) with a one-click clipboard mail-merge of the affected users.
  Data source: per-device last-check-in dates from device-compliance (tier 1) and device
  inventory (tier 1).

## Operations

![Patch Compliance](images/patch-compliance.png)

- **Patch Compliance** — per-title patch compliance with a failures drawer; exports to
  CSV and PNG.
  Data source: `pro report patch-status` per-title (tier 2); per-device failures from
  `--scan-failures` (tier 1).
- **OS Updates** — managed software-update plan state, failed plans, and devices in an
  error state.
  Data source: `pro report update-status` plan summaries (tier 2); per-device failures
  from `--scan-failures` (tier 1).
- **DDM Blueprints** — Declarative Device Management blueprint deployment status and
  declaration details from the Jamf Platform API. Experimental; requires the same three
  Platform API gates as Compliance Benchmarks above. Shows a locked state when the gate
  is closed.
  Data source: Jamf Platform API blueprint definitions and device assignments (tier 2).
- **Policies & Profiles** — a two-tab screen: policy configuration findings, and
  configuration-profile deployment status.
  Data source: `pro report policy-status` (tier 2) and `pro report profile-status` (tier
  2).
- **Extension Attributes** — per-EA coverage (percent of fleet populated) and top-value
  distributions.
  Data source: per-device EA results (tier 1) and device inventory (tier 1).

## Fleet

![Mobile Fleet](images/mobile-fleet.png)

- **Mobile Fleet** — iOS/iPadOS device counts, compliance signals, OS-version
  distribution, and a device/profile inventory.
  Data source: per-device mobile device inventory (tier 1) and profiles (tier 2).
- **Jamf Protect** — Protect alerts, agent health, and insights. Shows an explicit
  "Protect not detected" state for tenants that do not run Jamf Protect.
  Data source: Jamf Protect GraphQL API (separate OAuth2 credentials, tier 2).

## Automation

- **Schedules** — create and manage LaunchAgent jobs for unattended collection and
  reporting. See [Scheduling & Automation](05-Scheduling-and-Automation).
  Data source: no tier (configuration and schedule management).
- **Run History** — streamed output from past collect and generate runs.
  Data source: no tier (local log files, not API data).

## Configuration

- **Config** — the `config.yaml` editor. See
  [Configuration & Templates](04-Configuration-and-Templates).
  Data source: no tier (configuration only).
- **Customize** — choose which sheets a generated workbook includes and which metrics the
  Overview score cards show.
  Data source: no tier (user preferences).
- **Data Sources** — the inputs surface: cached `jamf-cli` data, the CSV inbox, and
  snapshot status.
  Data source: no tier (local workspace cache status).
- **Backups** — snapshot and compare Jamf Pro configuration backups.
  Data source: `jamf-cli pro backup` exports (tier 2).

## System

- **Settings** — app preferences: the jamf-cli install/update check, connections, the
  collection-cadence preset, diagnostics, and Sidebar Visibility.
  Data source: no tier (app configuration).
