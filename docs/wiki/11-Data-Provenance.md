# Data Provenance

Every number in the app comes from somewhere. Understanding the data source helps you
know what a screen shows (live snapshots or a once-per-day digest), when it updates, and
whether a metric includes all devices or just the ones you've collected data for.

The app uses three distinct data tiers. Most screens read one tier; some read two.

## Three data tiers

### Tier 1 — Per-device records

Raw `jamf-cli` API snapshots where each row is a device or device-related object. These
are the most detailed data: you can drill down to a specific device and see what it is.

Tier 1 kinds include:

- `ea-results` — one row per device's Extension Attribute result
- `device-compliance` — one row per device's per-rule compliance failures
- `computers` (device inventory) and `mobile-device-inventory-details`
- `patch-device-failures` and `update-device-failures` — per-device scan failures
- `compliance-devices` — Jamf Platform API per-device control compliance
- `ddm-device-status` — one row per DDM-enabled device's declaration and
  software-update status
- `mdm-command-health` — one row per device's failed and pending MDM command counts

Feeds these screens:

- **Devices** table and detail panel
- **Device Lookup**
- Failure drawers in **Patch Compliance** and **OS Updates**
- **Extension Attributes** coverage and value distributions
- **Compliance Benchmarks** (Platform API)
- **Compliance Posture** mSCP/STIG band distributions
- Per-device drill-down in error lists

### Tier 2 — Server-side aggregates

Pre-rolled summary reports from Jamf that return already-aggregated counts, percentages,
or status summaries, not per-device rows. These are real and current but lack the
per-device detail of Tier 1. If you need to see which devices failed, a Tier 2 report
alone won't tell you — you need the paired `--scan-failures` collection (Tier 1) to get
that detail.

Tier 2 kinds include:

- `pro report security` — FileVault, SIP, firewall, Gatekeeper percentages per the fleet
- `patch-status` — per-title compliance percentage and version distribution
- `update-status` — software-update plan summary and state counts
- `profile-status` — configuration-profile deployment status and rollup failures
- `policy-status` — policy configuration findings

Feeds these screens:

- **Security Posture** — FileVault/SIP/firewall/Gatekeeper rates and KPI counts
- **Patch Compliance** title-level compliance percentages
- **OS Updates** plan state and error summary
- **Policies & Profiles** configuration findings and policy counts

### Tier 3 — Daily digest

Once per collection run, the app writes one `summary.json` file containing about 15
aggregated fleet metrics for that day: total devices, compliance percent, patch percent,
FileVault percent, stale device count, security score, and related rolled-up numbers. The
first collect/generate run of a given day writes the summary; a later run the same day
replaces it only when it is strictly better — for example it measured a metric the first
run could not (stale count, real mSCP bands instead of the proxy). One caveat: a
generate-time rewrite does not know which inputs were fetched live, so an upgraded
summary may omit the `collectionSources` map the morning collect recorded.

This is not live data. It is a snapshot of the fleet state at the time of collection.

Feeds these screens:

- **Overview** — all KPI cards and donut charts
- **Trends** — all timeline charts
- **Fleet Overview** — per-profile health signals across all workspaces
- **Stability index** on the Overview

Do not expect these screens to update immediately when a device changes. They reflect the
most recent collection run, which may be hours or days old depending on your schedule.

## CSV-only workspaces

None of the three tiers above populate without a jamf-cli connection. A workspace running
on a CSV export alone (no jamf-cli, or jamf-cli installed but never authenticated) only
populates **Devices** and **Offline Outreach** — both render from CSV columns plus
`custom_eas` / `security_agents`, not from any jamf-cli tier. Every other screen in this
document stays empty until jamf-cli is connected and collecting. See
[App Onboarding → Running without jamf-cli credentials](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding) for how a CSV-only setup
gets through onboarding in the first place.

## Summary field derivations

This table shows where each Overview KPI number comes from:

| Metric | Data source | Tier |
|--------|-------------|------|
| Total Devices | Security report; falls back to inventory-summary | 2 |
| FileVault % | Security report FileVault encrypted / total | 2 |
| SIP % | Security report SIP enabled / total | 2 |
| Firewall % | Security report firewall enabled / total | 2 |
| Gatekeeper % | Security report Gatekeeper enabled / total | 2 |
| Compliance % | EA results (real mSCP/STIG bands) OR 4-control proxy from security report — check config for `complianceIsProxy` | 1 or 2 |
| Patch % | Unweighted mean of per-title compliance from `patch-status` | 2 |
| Stale Count | Device-compliance rows with last-check-in older than `stale_device_days` threshold | 1 |
| OS Currency % | Latest macOS version count from SOFA feed / total devices from inventory-summary | SOFA + 2 |
| Security Score | Weighted composite of FileVault, SIP, firewall, Gatekeeper, compliance, EDR agent, and other factors — weights configurable in **Customize** | 2 + config |
| mSCP Bands | Pass/Low/Med-Low/Medium/High/No Data distribution from EA results per device | 1 |

## Zero vs. unknown

A metric that cannot be computed is shown as "—" (em-dash) and is excluded from the
Stability index and other aggregates. It does not count as 0%.

Examples:

- If you have not collected `ea-results` yet, Compliance % shows "—".
- If you have not collected `patch-status` yet, Patch % shows "—".
- If a device has no last-check-in date, it does not count toward Stale Count.

This is intentional: missing data does not drag down your health scores. When you add that
data source to your collection schedule, the metric appears and the index recalculates.

## Freshness

A strip above every screen reports data sources that are **failing** (two or more
consecutive collect failures) or **stale** (past three times their tier cadence), so a
source that stopped collecting is visible wherever you are working rather than only on the
screen that reads it. Per-source success and failure counts are kept in the workspace's
state files. See
[Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust).

**Patch Compliance, Security Posture, OS Updates, and Devices** each show a row of
per-kind freshness chips — one per raw jamf-cli kind that screen reads, showing the age of
the newest on-disk snapshot for that kind. A kind the screen expects but has never
collected renders a distinct red "never" chip rather than silently omitting it, so a
data source that stopped being collected is visible rather than invisible. A kind you have
turned off via Settings' **Skip expensive collections** toggle is not "expected" and does
not get a "never" chip.

**`jamf_cli.max_cache_age_hours`** (default `168`, i.e. 7 days) governs how the Tier 3
digest treats old cache: past this age, the daily digest reports the kind as absent
instead of serving the old snapshot as if it were current. This only applies to the
digest — the xlsx/HTML report sheets still render whatever cache exists, with their own
"data as of" subtitles, because a stale-but-complete report is more useful than an empty
one. Set the value to `0` or below to disable the age check and keep cache forever.

Both the digest's age check and its "which file is newest" pick are based on the
**timestamp encoded in the snapshot's filename**, not the file's modification time on
disk — so a cloud-sync provider (iCloud, SharePoint) re-stamping mtimes on sync cannot
make a fresh snapshot look old, or vice versa.

A snapshot recovered from a truncated file (a "salvaged" day) is excluded from the EA
coverage-drift comparison in Config Doctor — a partial day would otherwise be
misread as a real coverage change.

## Collection tiers and the "Collect now" button

Collection is split into three API-cost tiers. The per-device kinds (ea-results,
patch/update device failures, device-compliance) are expensive, so the app gates them
behind collection-tier prompts.

See [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation) for the full collection
mechanics and presets.

The **Collect now** button in the app (visible in **Data Sources**) runs a full, forced
collection across all tiers, ignoring cadence limits and freshness checks. Use it when
you need the latest numbers right away.

## Report-only kinds

Many kinds are collected for the Excel and HTML reports but do not appear in any app
screen. These include:

- Policies, scripts, packages — excel **Policies** and **Scripts** sheets
- Sites, buildings, departments — excel demographic slicing
- Categories, app-status, software-installs — excel app-centric sheets
- Group lists (smart-computer-groups, classic-mobile-device-groups) — excel and HTML
  group hygiene analysis
- Audit and patch release dates — supporting data for trend calculations

This is intentional. The app focuses on device posture and compliance; detailed policy
audit trails and app inventories are report outputs, not interactive screens.

## Cross-reference: Historical Trends and period reports

The **Trends** screen reads `summary.json` snapshots. See
[Historical Trends](https://github.com/tonyyo11/jamf-reports-community/wiki/06-Historical-Trends) for details on how these files are managed and
how the trend timeline is built from them.

A [period report](https://github.com/tonyyo11/jamf-reports-community/wiki/06c-Period-Reports)
reads the same Tier 3 summaries between two dates, plus your collected `ea-results`, and
prints the real snapshot date beside every figure — so a start date the fleet has no
snapshot for is stated rather than assumed.
