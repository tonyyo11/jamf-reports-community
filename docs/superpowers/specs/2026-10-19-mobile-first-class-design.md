# Mobile devices as first-class devices — design

Status: M1 to M5 shipped in 2.12. Of M6, the Fleet Overview device tiles that need no P10 data
shipped in 2.12 (Mac models, mobile device types, operating systems, last seen); storage and App
Installers wait on P10 (2.13), and the encryption tile and the product cards are not built. This builds on the environment model
([2026-10-19-environment-model-design.md](2026-10-19-environment-model-design.md), D1–D14
accepted). It replaces that spec's section 10, the multi-environment view, as section 6 here
explains. Epic #207 L5 (carried into #284) is the backlog item.

The sidebar step is done in 297b4c04: the Fleet group sits under Reports and holds Computers,
Mobile Devices, Device Lookup, Jamf Protect and Groups & Searches.

## 1. Rules

- A fact about mobile devices appears only when the environment has mobile devices
  (`mobile-devices-list` lists at least one), and a fact about Macs only when it has Macs.
  A figure that cannot exist in this environment is left out, never shown as 0 or "No data".
  A figure that could exist after a collect or a setup step uses `OverviewUnavailable`, as today.
- Every new figure comes from data the app already collects: `mobile-devices-list` (GENERAL,
  HARDWARE, SECURITY, USER_AND_LOCATION), `classic-ios-profiles`, the `update-device-failures`
  scan and the cached SOFA iOS feed. Mobile battery and storage are already in HARDWARE
  (section 9), so they need a reader only, not new collection.
- No config key is added. Mobile staleness reuses `thresholds.stale_device_days`.
- The app stays read-only. It never offers lock, wipe, lost mode or an OS update.

## 2. One definition per mobile fact

`MobileFleetService.Snapshot` already computes most facts. The summary, Overview, Trends,
Audit and Fleet Overview all read them from there, so no screen counts differently.

| Fact | Definition | Counted over |
|---|---|---|
| Managed | `general.managed == true` | all mobile devices |
| Supervised | `general.supervised == true` | managed devices that report the flag |
| Passcode compliant | `passcodeCompliant(of:)` | devices that report it |
| Data protection | `dataProtected(of:)` | devices that report it |
| Activation Lock on | `activationLockEnabled(of:)` | devices that report it. A neutral count, not good or bad: it is right on a personal device and blocks reassignment on an org one |
| Jailbreak detected | `jailbreakStatus(of:)` | devices that report it |
| OS current | the version is at least the newest release of its own major in SOFA's iOS/iPadOS feed (the `SOFAFeedService.isCurrent` rule, iOS platform) | devices with a version the feed's majors cover. An untracked major is unknown, not behind |
| Stale | `general.lastInventoryUpdateDate` more than `stale_device_days` ago (`>`, like Macs) | devices with a parseable date (`DateParser`) |
| Update errors | rows in the `update-device-failures` scan's `error_devices` whose `device_type` is not a computer | the scan's rows |

Notes:

- A share is counted over the devices that report the field. An unsupervised or older record
  leaves fields out, and counting a missing field as a failure would invent bad news. Every
  share is stored with its count, so a screen can say "112 of 115 reporting".
- A record with no GENERAL or SECURITY data (`deviceType` "Unknown" on the test tenant) counts
  toward the device total and toward no share.
- OS versions arrive as both `17.5` and `17.5.0`. Count them through `OSVersionName`, which
  today normalises macOS only.
- `thresholds.stale_basis` does not apply. The record has `general.lastContactDate`, but it was
  null on every device of the test tenant, so staleness uses last inventory update for now and
  each mobile staleness label says "last inventory". Use last contact once a tenant fills it and
  its meaning is checked.

## 3. Overview

### 3.1 Mixed fleet (Macs and mobile devices)

- Managed Devices (existing): already shows both counts. Its sparkline stays one series: the
  Macs, or on a fleet with no Macs the `mobileManaged` series (the 2.11 decision that Managed
  Computers is one series; mobile devices are their own metrics, 4.1).
- **Mobile Devices**, a new half-width `OverviewSection` (`mobileDevices`; the raw value is
  persisted, never rename it). It has four lines and nothing more:
  1. Devices: iPad / iPhone / Apple TV counts, from the summary's `mobileFormFactorCounts`
     (every mobile device; a type with none is left out). A summary written before that map
     shows the managed mobile device count instead.
  2. OS current: share and count, against SOFA's iOS feed.
  3. Passcode compliant: share and count.
  4. Needs attention: jailbreaks + unmanaged + update errors, as one number that links to the
     Audit's Mobile Devices section (section 5). The line is hidden when the number is 0.

  The section opens Mobile Devices. Its subtitle names the snapshot date. The `isHalfWidth`
  pairing puts it beside macOS Distribution. A saved layout gets it at the end, shown
  (`OverviewLayout.normalized`).
- Score cards: mobile metrics (section 4) join the picker. None is in the default selection
  for a mixed fleet, which keeps today's Overview unchanged until the user picks one.
- The fleet AI insight (`FleetInsightInput.fleet`) gains the four lines above as facts when
  mobile devices exist.

Left off the Overview on purpose: supervision breakdown, Activation Lock, data protection,
enrollment method, the per-version OS table and the device list. Mobile Devices holds them, one
click away.

### 3.2 Mobile-only environment (no Macs)

`OverviewSection` gains `availability(in: EnvironmentComposition) -> .shown | .leftOut(reason)`.
A section whose data can never exist here is left out, not shown as an Unavailable notice:

| Section | Mobile-only |
|---|---|
| Managed Devices | shown, mobile only |
| Mobile Devices | shown |
| Score Cards | shown, filtered (below) |
| AI Fleet Insight | shown (mobile facts) |
| macOS Distribution, Top Failing Rules, Security Agents, Recent Activity | left out: "no Macs in this environment" |
| Workspace Status | shown |

- Score cards: the saved selection is filtered by `TrendSeries.Metric.isOffered(under:)`, which
  gains the composition: a Mac metric is not offered with no Macs, and a mobile metric is not
  offered with no mobile devices. When nothing in the selection is offered, the mobile default
  set shows: mobile OS current, passcode compliant, supervised and data protection. The stored
  selection is never rewritten, so switching back to a Mac environment restores it
  (`isOffered`'s rule today).
- The Customize sheet lists left-out sections greyed with their reason, so the reason is
  visible and nothing looks broken.
- The result is a short page: device counts, four facts, four score cards, the insight and
  workspace status. Nothing on it is about Macs.

`EnvironmentComposition` (Macs > 0, mobile > 0, from the newest `computers`, `inventory-summary`
and `mobile-devices-list` snapshots, and from the summary when no snapshot is read) is the
device half of the environment spec's `EnvironmentProducts`. It is built first (M1 below)
because it needs no profile slots.

## 4. Trends and the daily summary

### 4.1 One Trends screen

Mobile series join the existing Trends screen: one range picker, one AI card, one export.
A separate mobile Trends would duplicate all three. `TrendSeries.Metric` gains:

| Metric (raw value) | Series | Polarity |
|---|---|---|
| `mobileManaged` | managed mobile devices (count) | neutral |
| `mobileOSCurrent` | OS current share | higher is better |
| `mobilePasscode` | passcode compliant share | higher is better |
| `mobileSupervised` | supervised share | higher is better |
| `mobileDataProtection` | data protection share | higher is better |
| `mobileStale` | stale count | lower is better |
| `mobileJailbroken` | jailbreak count | lower is better |

The Managed Devices hero (`.managedDevices`) plots one series, the Macs (labelled Managed
Computers since 2.11); mobile devices are the `mobileManaged` metric beside it, not a second
line. Each metric is offered only when the environment has the device type, as in
3.2. `TrendChange` words changes as it does today: percentage points for shares, whole
devices for counts.

### 4.2 Summary fields

`DailySummary` gains one optional object. Today's top-level `mobileDeviceCount` stays where it
is (summary.json schema compatibility).

```json
"mobile": {
  "managed": 118,
  "supervised":     {"met": 100, "of": 118},
  "passcode":       {"met": 110, "of": 115},
  "dataProtection": {"met": 109, "of": 115},
  "activationLock": {"met": 40,  "of": 115},
  "osCurrent":      {"met": 90,  "of": 112},
  "stale": 6,
  "jailbroken": 0,
  "unmanaged": 2,
  "updateErrors": 3
}
```

- `mobile` is absent when the environment has no mobile devices. An inner pair is absent when
  no device reports that field. `osCurrent` is absent without a SOFA iOS feed. `updateErrors`
  is absent when no scan has run. No field is ever written as 0 for "unknown".
- The writer is the same summary step that writes `mobileDeviceCount`, including
  `ReportEngine.mobileOnlySummary`, so a mobile-only fleet gets the whole object.
- `DailySummary.filling(from:)` and `freshSummaryIsBetter` include `mobile` (a same-day
  rebuild keeps a value it cannot measure). `numbersAreInRange` checks `met <= of`.
- Alert metric keys (`MetricAlertEvaluator.Metric`): `mobile_os_current_pct`,
  `mobile_passcode_pct`, `mobile_supervised_pct`, `mobile_data_protection_pct`,
  `mobile_stale_count`, `mobile_jailbroken_count`. Each pct is `met / of`, and an absent pair
  never fires. config.example.yaml's `alerts:` comment lists them in the same PR as their reader.
- The environment spec's section 8 row ("`mobileEncryptedPct`, `mobilePasscodePct`,
  `mobileSupervisedPct`") is replaced by this object. Its `lastSeenBuckets`,
  `mobileFormFactorCounts` and `osMajorCounts` stay as written there, for Fleet Overview (section 6).

### 4.3 Backfill

`TrendStore` follows its agent-coverage backfill (`backfillAgentCoverage`): a second phase off
the main actor, after the first paint.

- A summary without `mobile` takes it from the newest `mobile-devices-list` snapshot stamped
  that same local day (sync-conflict copies and manifests excluded, a salvaged truncated
  snapshot not used). Same day only, unlike the `mobileDeviceCount` backfill's cache-age
  window: a share from a snapshot days older would read as that day's figure.
- At most the newest 21 such days are read, and each decode is cached per session (as
  `AgentBackfillCache` is). Older days stay absent.
- `osCurrent` is never backfilled: the cached SOFA feed is today's, and judging an old version
  list against today's releases would mark devices behind that were current then.
  `updateErrors` is not backfilled either (M-D14): the scan runs on its own cadence, so most
  past days have none, and the figure reads absent, never 0.
- Nothing is written back to disk. Backfill is read-time, as today.

## 5. Health Audit

A **Mobile Devices** section, app-computed like `ContactGapSection`, hidden when the environment
has no mobile devices. Each finding names a count and opens Mobile Devices filtered to those
devices (the donut filter pattern from #207 A3).

| Finding | Severity | From |
|---|---|---|
| Jailbreak detected | high | `mobile-devices-list` SECURITY |
| Not managed | medium | GENERAL `managed == false` |
| Passcode not compliant | medium | SECURITY |
| Data protection off | medium | SECURITY |
| OS behind the current release | medium | GENERAL `osVersion`, SOFA iOS feed |
| Software update errors | medium | `update-device-failures` `error_devices` with a mobile `device_type` (#207 L5 noted that `device_type` is never shown) |
| No inventory update in more than `stale_device_days` | low | GENERAL `lastInventoryUpdateDate` |

- Unsupervised and Activation Lock are not findings: either can be intended. They stay as counts on
  Mobile Devices.
- Tracking: each finding's count is the matching `mobile` summary figure, so the Audit
  compares today with the previous summary ("3 fewer than on 2026-10-18"). Trends and
  alert rules get the history with nothing extra. The audit AI insight
  (`FleetInsightInput.audit`) counts them by name with no device names.
- `classic-ios-profiles` carries `{id, name}` only, so it yields no finding. It stays as the
  profile count on Mobile Devices.
- `pro audit` (jamf-cli 1.31.1) returned five findings on the test tenant. None is mobile by
  name. Whether "Unencrypted devices" counts mobile devices is not known. If it does, its row is
  superseded by the data protection finding here, as `withoutSupersededRows` does for MDM
  commands.
- The HTML report's "Needs attention" gets the same rules (#207 L5: it has no mobile rules).

## 6. Fleet Overview shows one environment

The maintainer's direction (2026-10-19): Fleet Overview shows the active workspace only, and two workspaces never
appear on one screen. Today it lists every initialised profile, two different Jamf Pro servers
included. This replaces the environment spec's section 10 multi-environment view. It changes
how D8 and D13 apply, not what they decide.

**Fleet Overview = what this environment holds**, product by product. The Overview answers how
healthy the environment is. Fleet Overview answers what is in it.

- Header: the workspace name and the products present (the environment spec's slots).
- Device tiles, computers and mobile devices side by side in each (the Jamf Insights
  dashboard, applied to one environment): managed devices (model family / form factor),
  encryption (FileVault / data protection), last seen (under 1 day, under 7 days, 7 days or
  more: D8's fixed buckets), OS (share per major against SOFA's macOS and iOS feeds), storage
  (after P10), and App Installers status (after P10, macOS only). A tile with one device type
  shows that type alone. A tile with no data source is left out. Built in 2.12
  (`FleetDeviceMapTile`): one tile per map and device type, with counts per OS major rather
  than a share against SOFA; encryption, storage and App Installers are not built.
- Product cards: Jamf Pro or Jamf School (device counts, newest collect, failing sources),
  Jamf Protect (computers, the `DeviceCorrelation` match counts, alerts by severity), and later
  Security Cloud (risk counts, coverage). Each card names its profile and snapshot date and opens
  that product's screen. Counts are never added across products.
- Source: the active environment's newest daily summary (D13 still holds: the summary carries
  the small aggregate maps), plus the product cards' own snapshots. The drill-down to another
  profile (`drilledProfile`) and the cross-profile list, stability average and issues-only
  filter go. The profile switcher in the sidebar changes what Fleet Overview shows.

**Cross-environment figures leave the screen.** They exist only in report-group exports: the
fleet CSV and workbook (`FleetReportEmitter`, `FleetWorkbookEmitter`, `FleetRollup`), on demand
from Reports and on a schedule from Automation. Each export names every environment it covers.
These exports already exist, already keep each environment's figures apart, and are what an MSP
sends a client. D8's fixed buckets keep the exported last-seen figures summable.

## 7. Build plan

M1 to M5 need only `EnvironmentComposition`, not the profile slots, so they can start before
the environment spec's P1. Each phase is one PR with its caller.

| # | PR | Tests |
|---|---|---|
| M1 | Fleet Overview shows the active workspace only: drop the cross-profile list, drill-down and averages, and keep its existing cards for the one workspace. `EnvironmentComposition` | Two initialised workspaces, only the active one read. Switching the profile reloads. Needs visual verification at `PageScaffold.minSupportedWidth` |
| M2 | Summary `mobile` object written by the summary step and `mobileOnlySummary`, from `MobileFleetService` facts. `filling(from:)`, `freshSummaryIsBetter`, range checks. Alert keys and their config.example.yaml comment | Fixtures from a real jamf-cli `mobile-devices-list` answer (not hand-written). Absent object for no mobile, absent pair when unreported, `met <= of`, an alert on an absent pair never fires. OS current against a SOFA iOS fixture, untracked major unknown |
| M3 | Trends mobile metrics and the two-line Managed Devices hero. Same-day backfill with the 21-day cap and per-session cache | Backfill takes the same-day snapshot only, never `osCurrent`, conflict copies skipped. `isOffered` by composition |
| M4 | Overview `mobileDevices` section, `availability(in:)`, left-out sections in Customize, score card filtering with the mobile default set, insight facts | Mixed, mobile-only and Mac-only layouts. Selection never rewritten. Needs visual verification |
| M5 | Audit Mobile Devices section, HTML "Needs attention" mobile rules, Mobile Devices filters for each finding | Each finding from fixtures. Hidden with no mobile devices. Change against the previous summary |
| M6 | Fleet Overview device tiles and product cards (after the environment spec's P9 and P10 for storage, App Installers and the aggregate maps). The map tiles shipped in 2.12; storage and App Installers wait on P10, encryption and the product cards are not built | No cross-product totals. A one-type tile. Left-out tiles. Needs visual verification |

### Changes to the environment spec's phases

- **P8** (product-aware screens): the Overview and Trends composition rules move to M3 and M4.
  P8 keeps tabs, Config tabs, report sections, the Protect-only environment and School.
- **P9** (summary fields): the mobile fields move to M2. P9 keeps `products`, the Protect and
  Security Cloud figures and the aggregate maps (`lastSeenBuckets`, `modelFamilyCounts`,
  `mobileFormFactorCounts`, `osMajorCounts`, `storageBuckets`).
- **P11** (multi-environment view) becomes M6: one environment, no selector, no "N of M
  environments" on screen. `FleetRollup` gains the new fields for the report-group exports
  only. Order: M6 needs P9 and P10.

## 8. Decisions

All 13 recommendations were accepted on 2026-10-19.

| # | Decision | Recommendation |
|---|---|---|
| M-D1 | How much mobile goes on a mixed-fleet Overview | One half-width Mobile Devices section with four lines. No mobile score card by default |
| M-D2 | Sections a mobile-only environment cannot fill | Left out with a reason in Customize, not shown as Unavailable notices |
| M-D3 | Score cards on a mobile-only environment | Filter the saved selection by composition, and show the mobile default set when nothing is left. Never rewrite the selection |
| M-D4 | One Trends or a separate mobile Trends | One Trends with mobile metrics, offered when mobile devices exist |
| M-D5 | Summary shape | One optional `mobile` object with `{met, of}` pairs. `mobileDeviceCount` stays top-level |
| M-D6 | Share denominator | Devices that report the field, stored with the share so screens say "of N reporting" |
| M-D7 | Backfill | Same-day snapshots only, newest 21 days, read-time. OS currency never backfilled |
| M-D8 | Mobile staleness | `lastInventoryUpdateDate` against `stale_device_days`. `lastContactDate` exists but was null on the test tenant: adopt it only once a tenant fills it. `stale_basis` does not apply, and there is no new key |
| M-D9 | Which mobile conditions are Audit findings | The seven in section 5. Unsupervised and Activation Lock stay as counts, not findings |
| M-D10 | Recent Activity on the Overview | Stays Mac-only, and is left out on a mobile-only environment. Mobile has only a last-inventory date, and mixing date meanings in one list misleads |
| M-D11 | Where cross-environment figures live | Report-group exports only (fleet CSV and workbook, on demand and scheduled). No on-screen cross-environment view |
| M-D12 | When Fleet Overview stops mixing workspaces | Now (M1), before the environment phases. It needs nothing from them |
| M-D13 | Lost-mode text in the saved `mobile-devices-list` snapshot (section 9) | Drop `lostModePhoneNumber`, `lostModeLocation`, `lostModeMessage` and `lostModeFootnote` at collect and keep `lostModeEnabled`. No reader uses them, and the snapshot can sync to a shared folder |
| M-D14 | `updateErrors` backfill (accepted by Tony on 2026-11-12) | None. A past day's figure stays absent: the scan's own cadence leaves most days without one |

## 9. Checked against a test tenant (2026-10-19)

One read-only run of jamf-cli 1.31.1 on a test tenant: `pro mobile-devices list` with the four
sections `collect` passes (105 records, 103 iOS and 2 "Unknown" with no GENERAL or SECURITY),
`pro audit`, `pro report update-status --scan-failures` and `pro app-installers-deployments
list`. Only key names, types and counts were read, not values.

- The section flags work: every section not asked for (applications, certificates, network,
  profiles, groups) is null.
- GENERAL has `managed`, `supervised`, `osVersion`, `lastInventoryUpdateDate` (ISO 8601 with a
  2- or 3-digit fraction, `DateParser` reads both), `lastEnrolledDate`, `lastContactDate`
  (null on every record), `deviceOwnershipType`, `sharedIpad`, `udid` and `managementId` (the
  `DeviceCorrelation` keys for a mobile source). It has no `passcodeCompliant`,
  `dataProtectionEnabled`, `activationLockEnabled` or `jailbreakDetected`: SECURITY carries them,
  and `MobileFleetService` reads SECURITY first.
- SECURITY has booleans `passcodeCompliant`, `passcodePresent`, `dataProtected`,
  `activationLockEnabled`, `jailBreakDetected` and `lostModeEnabled`, and `hardwareEncryption`
  (a number). `lockdownModeEnabled` was null everywhere. It also has the lost-mode text fields
  `lostModePhoneNumber`, `lostModeLocation`, `lostModeMessage` and `lostModeFootnote`, empty on
  this tenant but saved raw in the snapshot (M-D13).
- HARDWARE has `batteryLevel` (0–100), `usedSpacePercentage` (0–98 seen), `capacityMb` and
  `availableSpaceMb`. `batteryHealth` was "UNKNOWN" on every record. Mobile storage and battery
  therefore need no new collection. The environment spec's section 8.1 row is confirmed, and the
  storage tile's mobile half reads `usedSpacePercentage`.
- `update-status --scan-failures` returned no data: the tenant has Managed Software Update Plans
  off (`.softwareUpdatePlansOff`). The mobile `device_type` values of `error_devices` are still
  unverified.
- App Installers: the read commands are `pro app-installers-deployments list`, `get`,
  `installation-summary` and `computers` (per deployment). The rest of that command group writes
  and is never called. The tenant has no deployments, so the shape is unverified. The "installed
  in 30 days / pending in 24 hours" figure needs one call per deployment.
