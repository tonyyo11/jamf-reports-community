# Jamf School per-device scan — design

Status: revised after plan review (2026-11-15), which sent the first draft back for rework. The owner asked for it in 2.12 ("Per device Jamf
school scan can come into 2.12"). Tracked in #305; it follows the Jamf School device health card
(`docs/superpowers/specs/2026-11-15-management-health-design.md`, "Jamf School").

A Jamf School device list row holds little: `{name, os, model, serialNumber, udid, isManaged,
isSupervised, lastCheckin, inTrash}`. `school devices get <udid>` adds three fields per device.
This change collects them with one call per device and shows them on the School screens and
workbook. It is the first new collect kind added after 2.12.0-rc1, so it is small and runs after
everything else a collect does: a scan that fails, stalls or is killed costs nothing but itself.

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

Revised after plan review (2026-11-15): the first draft ran the scan inside `schoolCollect`,
reused the Jamf Pro scan's private machinery and let a person force it. None of that held up
against the code; this section replaces it.

**Where it runs.** A step of its own in `CollectRouter.run`, after the School collect, the Jamf
Protect and Security Cloud add-ons and `finalize()` have all finished. Nothing the scan does can
delay or lose the summary, an add-on or the shared-workspace claim release. It never throws out of
the router and never changes the collect's result.

**When it runs.** All of:
- the run's tiers contain `.scan` (a School run for the scan tier alone collects `school-devices`
  as the scan's input and nothing else it would not otherwise collect);
- `jamf_cli.collect_skip` does not list `school-device-detail` (`ReportEngine.skippableKinds`
  learns the name);
- `school-devices` landed in this run;
- the last attempt is 7 days old or more (`ReportEngine.schoolDeviceScanInterval`), success or
  failure. A stamp ahead of now (a peer's clock on a shared workspace) reads as absent.

`force` never bypasses the cadence: every GUI collect and a School `jamf-cli-full` schedule pass
`force: true` today, so "force" cannot mean "a person asked". In 2.12 there is no way to rescan
inside the 7 days short of removing the state file; a Scan now button is left for #421.
The Settings "skip per-device commands" switch does not reach a School collect today and is not
part of this change; `collect_skip` is the off switch.

**Kind and state.** `school-device-detail`, written through `saveSnapshot`. It is NOT in
`knownCollectKinds` or `CollectionTier.tierMap` (the Jamf Pro `expectedKinds` filters that list, so
adding it would make every Jamf Pro workspace expect it); it has its own constant, like the
Protect kinds. Its last attempt and last failure are recorded in `StateFileStore` under the kind.

**Input.** The device rows `schoolCollect` landed in this run, handed to the router with the
collect's result (the bytes that were saved, not a re-read of the newest file, which on a shared
folder could be a peer's). Devices in School's trash and rows with no UDID are not scanned.

**The loop.** A separate, one-call-type School loop. It shares only `DeviceCallLimits`, the
bounded jamf-cli `run`, `save` and `exceedsFailureBudget` with the Jamf Pro scan, which is not
touched. Four calls at a time; each call has `deviceCallTimeout` (180 s). No Jamf Pro token probe
on any exit code.

**Bounds.** The scan stops, records the kind failed and writes nothing when any of these happens:
- failures exceed 25% of the targets (the target count is known up front, so this is checked as
  it goes, not at the end);
- the first 20 calls all fail (a dead API key or an outage costs seconds, not N calls);
- a 60-minute deadline for the whole phase passes (recorded as exit -2);
- a call exits 3, 5, 6 or 8 (recorded with that exit).

A call that exits non-zero, times out or returns no object is one device that did not respond.

**Results.**
- Lands with every device: `[ok]`.
- Lands with gaps (25% or fewer): `[info] school-device-detail: N of M devices did not respond`.
- Not written: `[warn] school-device-detail not written: <reason>`. Never `[partial]`: a
  `[partial]` line that names no retryable source makes the tick rerun the whole School collect
  and report an hour later, which no retry would fix (the `html.with_workbook` precedent).
- Zero devices to scan lands an empty snapshot, never none.
- The run log records `[info] school-device-detail took Ns`.

**Rows on disk.** An allow-list built before anything is saved:
`{udid, serialNumber, batteryLevel, deviceEnrollType, totalCapacity}`. No device name, no user.
A value of the wrong type is left out of the row; a device whose call returned none of the three
fields still gets a row, so "scanned, nothing reported" differs from "not scanned".

**Plan and skip lines.** Before the collect: `[plan] device scan: due | not due (last attempt: …)
| turned off (jamf_cli.collect_skip) | not selected (tier scan not selected)`. At run time, when
`school-devices` did not land: `[skip] school-device-detail: school-devices did not land this
run`, and nothing is recorded.

## Honesty chain (the new-source checklist)

| Step | This kind |
|---|---|
| `knownCollectKinds`, `CollectionTier` | not added, on purpose (see Kind and state) |
| `StateFileStore` | attempt and failure recorded; exit code kept |
| `FailureCause` | classified from the stopping call's envelope when there is one |
| Log wording | `[ok]`, `[info]` for gaps, `[warn]` for not written, `[skip]` for no input |
| `isCollectDead` | outside the verdict; the scan runs after it |
| `retryCouldHelp` | no `[partial]` line, so the tick's same-day retry is never triggered by the scan |
| `expectedKinds` / Data Freshness | not expected; the School Overview card says when the scan last ran and whether the last attempt failed |
| `CollectSourcesPlan` | listed under Jamf School with the skip wording |
| Command catalog | `CommandCatalog` learns `school devices get`; the fixture test covers it |
| Retention | swept like any dated snapshot |
| Account names | the allow-list holds none; `keep_account_names` does not apply |
| Fixture | one captured row with placeholder identifiers |

## Where it shows

One reader, `SchoolDeviceDetail` (rows joined to `school-devices` by UDID alone, compared
lowercased, as `SchoolFleetService` already joins), feeding `SchoolDeviceHealth` so every figure
still has one calculator.

| Surface | What |
|---|---|
| School Overview › Device health | Enrollment type breakdown (value as School gives it, capped), storage size breakdown, battery (below), and "last scanned <date> · N of M devices". With no scan: "Per-device details not collected yet". Last attempt failed: "last attempt failed <date>". Unreadable snapshot: "could not be read". |
| Workbook | The School "Device Inventory" tab gains three columns at the end (Enrollment, Storage, Battery when scanned); the Device Health tab's summary gains the breakdown rows. No tab or existing column moves. |
| Data Sources | the source and its skip reason, through `CollectSourcesPlan`. |
| Demo mode | derived for the demo School fleet; no workspace read. |

Not in 2.12: columns on the School Devices screen. Its seven columns already need more than the
minimum window width, so three more wait for a layout pass (#421).

Every figure is a neutral count with its denominator (devices scanned that reported the field).
Battery is a point-in-time reading, so it is worded with the scan date: "battery 1 to 20% when
scanned" (`SchoolDeviceHealth.lowBatteryPercent`, 20, a display constant) and, apart from it,
"battery reported as 0", because a 0 may be an empty battery or a device with none. Not in the
daily summary, Trends or alerts (#421).

## Not in this change

- School figures in the daily summary and Trends (#421).
- A config key for the scan interval or the battery cut.
- Jamf Pro: its device scan is unchanged.

## Build order

1. Collect: the router step, the School loop, cadence and state, skip, plan lines, catalog, tests
   with a stub jamf-cli (not named `jamf-cli`).
2. Reader and calculator figures; the card; workbook columns and rows; demo data; strings.
3. Docs: CLAUDE.md and AGENTS.md, CHANGELOG (Added, and Changed for the workbook columns),
   config.example.yaml (`collect_skip` value), wiki.

## Decisions (the owner was given these on 2026-11-15; recommendations stand unless changed)

| # | Question | Recommendation |
|---|---|---|
| 1 | Cadence | 7 days, fixed |
| 2 | Does a forced collect (any GUI collect, a daily `jamf-cli-full` School schedule) scan | No; nothing bypasses the cadence in 2.12 |
| 3 | Data Freshness banner for this kind | Not expected; the card shows the last scan and a failed attempt |
| 4 | Battery reading 0 | Shown apart as "reported as 0", not counted as low |
| 5 | Device name in the snapshot | Left out; joined by UDID |
| 6 | School Devices columns | Not in 2.12 (window width) |

## Open

- What `batteryLevel` 0 means on a device with no battery: needs one such device on a tenant.
- `deviceEnrollType` values other than `dep`.
- The unit of `totalCapacity` (read as gigabytes of storage).
- Throughput at four calls at a time on a large district, and School rate limits: measured only on
  15 devices in sequence.

## Test matrix

| Case | Expected |
|---|---|
| Tiers without `.scan` | no scan; plan line "not selected" |
| Managed scan run, tiers `[.scan]`, School workspace | collects `school-devices`, then scans |
| Last attempt 2 days old, any `force: true` collect | not due |
| A peer's last-attempt stamp in the future | read as absent; due |
| `collect_skip` lists the kind | turned off; nothing recorded |
| `school-devices` did not land | `[skip]`, nothing recorded |
| Device in trash; row with no UDID | not called |
| All respond | snapshot lands; rows hold only the allow-list |
| 25% do not respond; 26% | lands with the `[info]` gaps line; stops, kind failed, nothing written |
| First 20 calls all exit 1 | stops there, in seconds; `[warn]`, no `[partial]` |
| Alternating timeout and success | stops at the 25% budget or the 60-minute deadline |
| Exit 3 on a device | stops, exit 3 recorded, no `pro auth token` call |
| Zero devices | empty snapshot |
| Scan fails, stops or is killed mid-run | summary, Protect, Security Cloud and `finalize()` already done; router result unchanged |
| Scan not written, tick schedule | `retryCouldHelp` unaffected; no rerun an hour later |
| Jamf Pro workspace | kind not expected, never scanned |
| Wrong-type field | left out of the row; other fields kept |
| No scan snapshot; last attempt failed; unreadable snapshot | "not collected yet"; "last attempt failed"; "could not be read" |
| Battery 0, 15 and 80 | "reported as 0"; low; neither |
| Demo mode | no jamf-cli, no workspace read |
