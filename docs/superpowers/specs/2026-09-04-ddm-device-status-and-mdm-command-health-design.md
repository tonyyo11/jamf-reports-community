# DDM device status and MDM command health (2.8.0) — design

Status: approved in brainstorming 2026-09-04; shapes verified against the maintainer's
prod server the same day, including a failed-command capture; awaiting spec review.
Inspiration: ScottEKendall/JAMF-Pro-Scripts (JAMFGetDDMInfo, JAMFClearFailedMDM).
Read side only. The app's mutating jamf-cli surface stays at zero.

## Problem

- The DDM Blueprints screen reads `pro report blueprint-status` and `ddm-status`,
  both Platform-only. Since 2.7.0 those kinds are skipped on non-platform
  profiles, so an on-prem instance never sees the screen populated — even though
  on-prem tenants run DDM software updates.
- The app has no fleet-wide view of failed or stuck MDM commands. `pro device`
  shows one Mac's history on demand; nothing aggregates it.

Both are answerable through the Jamf Pro API per device, which jamf-cli 1.24
already wraps: `pro ddm-status status-items <managementId>` and
`pro classic-computer-history get <id> --subset commands`. The one-call
`pro mdm-commands list --filter status==Failed` returns HTTP 500 on both test
tenants AND on prod (verified 2026-09-04), so the Classic per-device history call
is the only read path for MDM commands.

## Decisions (from brainstorming)

- Both fleet view and per-device panel (C).
- Fleet data unlocks the existing DDM screen (A); no Updates-screen join in 2.8.0.
- One per-device scan loop serves both features (A).
- Engine-side fan-out inside `ReportEngine.collect` (approach 1). A jamf-cli
  feature request for server-side reports is filed in parallel by the
  maintainer so the loop can be deleted when upstream ships them.
- Computers only. Pending age threshold is a fixed 7 days, no config key.
  Blueprint names come from the existing `blueprint-status` snapshot on platform
  profiles; otherwise the UUID is shown. No cross-reference file.

## 1. Scan loop and snapshots

Where: a phase at the end of `ReportEngine.collect`, scan tier, after the command
matrix. Reads the `computers` snapshot saved in the same run, or the newest on
disk when computers was not due. Skipped by `skipExpensiveCollections`.

Per managed Mac, two calls through the normal executor and codesign gate:

| Call | When |
|------|------|
| `pro classic-computer-history get <id> --subset commands` | every device |
| `pro ddm-status status-items <managementId>` | `general.declarativeDeviceManagementEnabled == true` |

Concurrency: task group, at most four jamf-cli processes at once.

Two new kinds, one array snapshot each, written once at the end via `saveSnapshot`
(manifest, retention, freshness counters and `[partial]` apply unchanged):

`ddm-device-status` — one row per DDM-enabled device:
`deviceId, name, managementId, osVersion, osBuild, reportDate, ddmReported (Bool),
declarations: [{identifier, active, valid, reasonCode?, reasonText?}],
softwareUpdate: {pendingOSVersion?, pendingBuild?, installState?, installReason?,
failureReason?, failureAt?, betaEnrollment?}`.
A 404 is recorded as `ddmReported: false`, never dropped.
**Never persisted:** `mdm.push-token`, `mdm.push-magic`, `server-token` values,
`security.certificate.list`, `content-cache.*` — the collector keeps an explicit
allow-list of status-item keys, not a deny-list.

`mdm-command-health` — one row per device:
`deviceId, name, failedCount, pendingCount, failedCommands: [String],
oldestPendingDays: Int?`.

Both join `knownCollectKinds` and `CollectionTier.scan`; `expectedKinds` treats
them as expected only when the expensive-collections toggle is off.

A run that dies mid-loop writes neither file; the prior snapshot stays current.

## 2. Decoders and services

Decoders in `JamfCLIDecoder.swift`, beside `DDMStatusRow`: identity-free rows,
every field optional, tolerant scalars. Both raw shapes are decoded at collect time.

Verified prod shapes (2026-09-04, macOS 27 device, Jamf Pro on-prem):

- Status items: `{statusItems: [{key: String, value: String|null, lastUpdateTime:
  String}]}`. `value` is JSON null for unset items (`softwareupdate.failure-reason`,
  `softwareupdate.pending-version`). Software-update facts live under SUB-KEYS:
  `softwareupdate.pending-version.os-version`, `.pending-version.build-version`,
  `softwareupdate.install-state`, `softwareupdate.install-reason.reason`,
  `softwareupdate.failure-reason`, `softwareupdate.beta-enrollment`. Device facts:
  `device.operating-system.version` / `.build-version`, `device.model.identifier`.
- Declarations: `management.declarations.configurations` (and `.activations`) is a
  string of one or more `{active=…, identifier=…, valid=…, server-token=…}` groups.
  One group was observed; the parser extracts every `{…}` group with a regex and
  reads `key=value` pairs inside, so a multi-group string needs no second code
  path. Failure `reasons` (`code=`, `description=`) were not present on a healthy
  device — the parser tolerates their absence and pins their presence only once a
  failing capture exists.
- History: `{commands: {completed: "" | {command: …}, failed: "" | {command: …},
  pending: "" | {command: …}}}`. **Each of the three buckets is an empty string
  when it holds nothing and an object otherwise**, and inside a bucket `command`
  is a single OBJECT for one entry and an ARRAY for several — the Classic API's
  XML-to-JSON single-element collapse. Both variants were observed on prod
  (2026-09-04, four devices: three clean, one with exactly one failed command as
  a bare object). The decoder therefore takes string-or-object at the bucket and
  object-or-array at `command`; the same tolerant-scalar class the repo already
  handles. Failed rows carry `failed_epoch`, `issued_epoch` (ms), `name`,
  `status` (the failure text, e.g. an App Store request timeout), `username`.
  Pending rows carry `issued_epoch`, `last_push_epoch` (ms), `name`, `status`,
  `username`; the age computation uses `issued_epoch`. Completed is hundreds of
  rows per device and is reduced to a count at collect time.

`DDMDeviceStatusService` (pure over the snapshot): per identifier, counts of
active / inactive / invalid / mixed devices (mixed = same identifier both active
and inactive on one device); software-update aggregation by pending version and
by failure reason; `ddmEnabledCount`, `ddmReportedCount`, and enabled-of-total
from `computers`. Identifier display name joined from `blueprint-status` when
present, else the UUID.

`MDMCommandHealthService` (pure): devices with any failed command; devices with
a pending command older than 7 days; most common failed command names. Rows carry
device id and name for deep-linking.

Both services expose `sourceDates` for the freshness chip row and health strip.

## 3. Surfaces

DDM screen: lock only when none of {platform blueprint snapshot, per-device
snapshot, `computers` DDM-enabled count} exist. Header strip (enabled N of M,
reported N, failing declarations N); Blueprints section only when the platform
snapshot exists (absent on-prem, not a placeholder); Declarations by identifier
with expandable device lists and reason text; Software updates (pending version
distribution, failure reasons with device lists). DRAFT — visual verification at
`PageScaffold.minSupportedWidth`.

Devices panel: two snapshot-fed sections above the live `pro device` detail:
"DDM" and "MDM commands", each with the snapshot date.

Audit: new "Command health" category with two findings — devices with failed
MDM commands; devices with a pending command older than 7 days. Take-action
routes to Devices. Remedy text points at the Jamf Pro record's Management tab;
no flush from the app.

Workbook: sheets "DDM Device Status" and "MDM Command Health", one row per
device, registered in `CoreDashboard.sheetPlan` and `FullInstanceTemplate`.
No HTML section in 2.8.0.

## 4. Failure handling

- Per-device 404 on status items → `ddmReported: false`; not an error.
- Exit 3 → existing auth-dead verdict, unchanged.
- Exit 5 on the first device of a call type stops that call type for the run;
  one log line names the privilege (Read Computers). The other call type continues.
- Exit 8 on a platform profile skips the Classic history call for the run with
  the existing refused-by-policy line.
- More than 25% of devices failing a call type → that kind is recorded failed and
  nothing is written. Below that, the snapshot is written and the log carries
  `[partial] <kind>: N of M devices did not respond`.
- No `computers` snapshot → one skip line, loop does nothing.
- Progress line to Run History every 100 devices.

## 5. Testing

- Fixtures captured from the maintainer's prod server 2026-09-04 (one
  status-items payload from a macOS 27 Mac with a pending DDM update; one history
  payload with `failed: ""` and `pending` rows; one history payload with a single
  failed command as a bare `command` object and `pending: ""`), scrubbed
  (serial/UDID/tokens/org-specific profile and app names replaced, completed list
  trimmed) before entering the repo. Still unobserved and therefore NOT
  fabricated: a multi-failure array, and a populated `softwareupdate.failure-reason`
  / declaration `reasons` group; those branches stay tolerant-absent until a
  capture exists.
- Decoder tests for both raw shapes; mutation-pinned tests on the declaration
  string parser.
- Service tests against hand-computed aggregates, including the Mixed rule and
  the 7-day boundary at exactly 7 days.
- Collect loop tests through the `locateJamfCLI` seam with a stub executable not
  named `jamf-cli`: concurrency cap, 25% rule, 404 path, exit-5 stop.
- One Golden Fleet case with one DDM-enabled and one DDM-disabled device
  asserting the screen's header numbers.
- Visual pass on the DDM screen and Devices panel by the maintainer.

## Out of scope

Force DDM sync, command flush, mobile devices, Updates-screen reason join,
HTML section, blueprint name cross-reference file, configurable pending threshold.
