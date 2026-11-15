# Jamf School per-device scan — design

Status: draft for plan review (2026-11-15). The owner asked for it in 2.12 ("Per device Jamf
school scan can come into 2.12"). Tracked in #305; it follows the Jamf School device health card
(`docs/superpowers/specs/2026-11-15-management-health-design.md`, "Jamf School").

A Jamf School device list row holds little: `{name, os, model, serialNumber, udid, isManaged,
isSupervised, lastCheckin, inTrash}`. `school devices get <udid>` adds three fields per device.
This change collects them with one call per device and shows them on the School screens and
workbook. It is the first new collect kind added after 2.12.0-rc1, so it is small and off the
critical path of a collect: a scan that fails never fails the School collect.

## What is true today

Checked 2026-11-15 on a test School tenant with real devices (15 devices: Macs and iPads;
aggregates only) with jamf-cli 1.37.0.

- `school devices get <udid> --output json` returns one object:
  `{UDID, name, serialNumber, model{identifier, name}, os{prefix, version}, isManaged,
  isSupervised, lastCheckin, batteryLevel, deviceEnrollType, totalCapacity}`. Two key sets were
  seen across the 15 devices, so a key can be absent.
- `batteryLevel`: an integer from 0 to 100. Three devices reported 0 or 1; nothing says whether
  that is an empty battery or a device that does not report one.
- `deviceEnrollType`: a string; only `dep` was seen.
- `totalCapacity`: an integer no larger than 2048, read as gigabytes; the unit is not stated by
  jamf-cli.
- Every call exited 0 and took 0.7 to 0.9 seconds. A UDID School does not know exits 1 with the
  generic error and no hint, so a missing device cannot be told from a network failure.
- Cost: about 0.8 s a device. 5,000 devices is about 67 minutes in sequence and about 17 minutes
  with four at a time.
- Nothing in the app runs `school devices get` today. `schoolCollect` runs the fixed
  `schoolCommandMatrix`, then Jamf Protect when connected.

## The scan

A phase at the end of `schoolCollect`, after the matrix and the daily summary, before Jamf
Protect. It is the School twin of `runDeviceScanPhase` and reuses its machinery rather than
copying it: the bounded task group (`deviceScanConcurrency`, 4), `DeviceCallLimits`
(`deviceCallTimeout` 180 s; three timed-out calls in a row stop the scan), and the same markers.

- **Kind:** `school-device-detail`, one snapshot per scan, written through `saveSnapshot`.
- **Input:** the newest `school-devices` snapshot from this run (never a cached one from an
  earlier day: if `school-devices` did not land this run, the scan does not run). Devices in
  School's trash and rows with no UDID are left out.
- **Rows on disk:** an allow-list, built before anything is saved:
  `{udid, serialNumber, batteryLevel, deviceEnrollType, totalCapacity}`. No device name, no user.
  A value of the wrong type is left out of the row; a device whose call returned none of the
  three fields still gets a row with its identifiers, so "scanned, nothing reported" differs from
  "not scanned".
- **Cadence:** due when the last attempt is more than 7 days old
  (`ReportEngine.schoolDeviceScanInterval`). Enrollment type and capacity do not change, and a
  battery level is a point-in-time reading whatever the cadence. A failed attempt advances the
  cadence, as in the Jamf Pro scan, so a tenant that always fails is not scanned every run.
- **Force:** only a person's Collect now (`force: true` from the GUI) runs it early. A School
  `jamf-cli-full` schedule forces its collect on every run (`forcesCollect(for:)`); that force
  does NOT reach the scan, or a daily report schedule would scan the district daily. The
  implementation passes the scan its own flag.
- **Turned off by:** Settings' "skip per-device commands" switch (`skipExpensive`) and
  `jamf_cli.collect_skip: [school-device-detail]`. `ReportEngine.skippableKinds` learns the name.
- **Results:**
  - A call that exits non-zero, times out or returns no object is one device that did not respond.
  - Strictly more than 25% of devices not responding: the kind is recorded failed, nothing is
    written, and the run logs `[partial] school-device-detail did not land`.
  - Otherwise the snapshot lands; with gaps it logs
    `[partial] school-device-detail: N of M devices did not respond` with
    `deviceScanGapsMarkerSuffix`, which Run History shows and the same-day retry ignores.
  - Three timeouts in a row stop the scan and record the kind failed with exit -2.
  - Exit 3, 5, 6 or 8 on a device stops the scan for the run and records that exit, as in the
    Jamf Pro scan. (School 401/403 exit 1 today; this covers a jamf-cli that classifies them.)
  - Zero devices to scan lands an empty snapshot, never none.
- **Never fatal:** the scan runs after the summary is written; no outcome of it throws
  `collectDead`, changes the collect's exit, or stops Jamf Protect from running.
- **Plan lines:** `planSchoolCollect` adds
  `[plan] device scan: due | not due (last attempt: …) | turned off (…)`, in the Jamf Pro
  wording.
- **Shared workspace:** the claim and stand-down the School collect already has cover the scan;
  nothing new.
- **Tick lock:** the scan runs inside the collect's hold. At four at a time, 20,000 devices is
  about 70 minutes; the 6-hour lock give-up is not approached. The run log records the scan's
  duration (`[info] school-device-detail took Ns`).

## Honesty chain (the new-source checklist)

| Step | This kind |
|---|---|
| `knownCollectKinds`, `CollectionTier` | added; scan tier |
| `StateFileStore` | success and failure recorded; failure exit code kept |
| `FailureCause` | classified from the stopping call's envelope when there is one |
| `[partial]` / `[skip]` wording | the shared markers above |
| `isCollectDead` | the scan is outside the verdict |
| `retryCouldHelp` | gaps marker is not retried; a failed scan is not retried the same day (cadence advanced) |
| `expectedKinds` / Data Freshness | NOT expected: a School workspace's banner stays as it is. The School Overview card says when the scan last ran instead |
| `CollectSourcesPlan` | listed under Jamf School with the skip wording |
| Command catalog privileges | `CommandCatalog` learns `school devices get`; the catalog fixture test covers it |
| Retention | swept like any dated snapshot |
| Account names | the allow-list holds none; `keep_account_names` does not apply |
| Fixture | one captured row with placeholder identifiers |

## Where it shows

One reader, `SchoolDeviceDetail` (rows joined to `school-devices` by UDID, compared lowercased,
then serial), feeding `SchoolDeviceHealth` so every figure still has one calculator.

| Surface | What |
|---|---|
| School Overview › Device health | Enrollment type breakdown (value as School gives it, capped), storage size breakdown, "battery at N% or less when scanned" as a neutral count with the scan date, and "last scanned <date> · N of M devices". With no scan: "Per-device details not collected yet". Unreadable snapshot: "could not be read". |
| School Devices | Three columns: Enrollment, Storage, Battery (when scanned). A dash for a device with no row. |
| Workbook | The School Device Inventory tab gains three columns at the end; the Device Health tab's summary gains the breakdown rows. No tab or existing column moves. |
| Data Sources | the source and its skip reason, through `CollectSourcesPlan`. |
| Demo mode | derived for the demo School fleet; no workspace read. |

Every figure is a neutral count with its denominator (devices scanned that reported the field).
Battery is worded with its scan date because it is stale the hour after. Not in the daily summary,
Trends or alerts (#421).

The low-battery cut is `SchoolDeviceHealth.lowBatteryPercent` (20), a display constant, not a
config key.

## Not in this change

- School figures in the daily summary and Trends (#421).
- A config key for the scan interval or the battery cut.
- Jamf Pro: its device scan is unchanged.

## Build order

1. Collect: the kind, the phase, cadence, skip, plan lines, state, catalog, tests with a stub
   jamf-cli (not named `jamf-cli`).
2. Reader and calculator figures; card, School Devices columns, workbook columns; demo data;
   strings and catalog entries.
3. Docs: CLAUDE.md and AGENTS.md, CHANGELOG (Added, and Changed for the workbook columns),
   config.example.yaml (`collect_skip` value), wiki.

## Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| 1 | Cadence | 7 days, fixed |
| 2 | Does a daily `jamf-cli-full` School schedule scan every run | No; the scan keeps its own cadence |
| 3 | Data Freshness banner for this kind | Not expected; the card shows the last scan |
| 4 | Battery reading 0 or 1 | Shown as reported; not counted as low unless the device also reports a non-zero capacity (see Open) |
| 5 | Device name in the snapshot | Left out; joined by UDID |

## Open

- What `batteryLevel` 0 means on a device with no battery (an Apple TV, a Mac mini): needs one such
  device on a tenant. Until then a 0 is shown as 0 and counted in the low-battery figure.
- `deviceEnrollType` values other than `dep`.
- The unit of `totalCapacity`.

## Test matrix

| Case | Expected |
|---|---|
| `school-devices` did not land this run | no scan; plan line says why |
| Last attempt under 7 days ago, scheduled run, `jamf-cli-full` forced collect | not due |
| Collect now | runs |
| `skipExpensive` on; `collect_skip` lists the kind | turned off; nothing recorded |
| Device in trash; row with no UDID | not called |
| All respond | snapshot lands; rows hold only the allow-list |
| 25% do not respond; 26% do not respond | lands with the gaps marker; kind failed, nothing written |
| Three timeouts in a row | stopped, exit -2 recorded, `[partial]` |
| Exit 3 on a device | stopped, exit 3 recorded |
| Zero devices | empty snapshot |
| Any scan failure | School collect exit unchanged, summary written, Protect still runs |
| Wrong-type field | left out of the row; other fields kept |
| No scan snapshot; unreadable snapshot | "not collected yet"; "could not be read" |
| Device with no scan row | dashes in the three columns |
| Demo mode | no jamf-cli, no workspace read |
