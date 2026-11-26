# Change and aging views from data already on disk (2.13, wave B)

*   **Author:** Tony Young
*   **Status:** In Review (revision 2, after the Stage 5-8 review)
*   **Date:** 2026-11-25
*   **Epic:** [#421](https://github.com/tonyyo11/jamf-reports-community/issues/421), section
    "Surfacing data the app already holds"
*   **Predecessor:** a brainstorm brief and a review of revision 1, both kept outside the repo
    with the planning notes (`.dev/egm/`, not tracked)

--------------------------------------------------------------------------------

## Overview

Jamf Reports keeps dated snapshots of every source it collects and one daily summary per
workspace. Today it uses that history in three places only:

*   Trends: fleet figures over time.
*   Fleet Drift: two `computers` snapshots compared.
*   Patch Velocity: adoption of each title's latest version.

It never answers the questions an admin asks every morning:

*   What changed since the last collect?
*   How long has each Mac been in a gap (FileVault off, stale, failing a patch policy), and
    how long do gaps of each type take to close?
*   How fast does the fleet adopt each version of a third-party title, not only the newest?

This design answers them from data already on disk, with no new jamf-cli commands. It is one
design in four stages, each shippable on its own:

| Stage | What it adds | Reads |
| --- | --- | --- |
| B1 | Per-version patch history: every definition's release date, adoption per version, days to 90% across titles | Snapshots |
| B2 | Mac change view: two snapshots compared at collect time, counts in the day's summary | Snapshots |
| B3 | Mac aging and time-to-fix, from a per-Mac aging cache built from snapshots | Snapshots, through the cache |
| B4 | Mobile and Jamf School change and stale aging, the weekly digest webhook | Snapshots, summaries, the cache |

There is one calculator for "what changed": the two-snapshot comparison that Fleet Drift
already uses, extended in B2 and generalised to mobile and School devices in B4. The aging
cache is used for aging only. It is a cache, not a record: each Mac keeps its own, and
rebuilds it from the snapshots on disk whenever it cannot trust it.

## Terms

| Term | Meaning here |
| --- | --- |
| Snapshot | One dated JSON file a collect saves per source (`computers_20261124T091823.json`). |
| Kind | The source a snapshot belongs to, which is also its folder name (`computers`, `patch-status`). |
| Tier | How often a source is due. `computers` and `mobile-devices-list` are every 2 days (inventory tier); `patch-status` daily (refresh tier); `patch-device-failures` weekly (scan tier). |
| Landed | A collect saved a new snapshot of that source in this run. |
| Held | The collect skipped a due source on purpose (a timeout hold, `collect_skip`). |
| Complete observation | A snapshot the B3 cache may use to close a gap. Defined per source under "When a snapshot is complete". |
| Gate | The step in `CollectRouter.run` that decides whether this Mac collects now: the once-a-day guard (a full collect already ran today) and the shared-workspace claim. |
| Stand-down | The gate stopped the run because a peer Mac holds the claim or collected recently. |
| Tick lock | The per-Mac kernel lock every scheduled run and collect holds, so two never overlap on one Mac. |
| Stale rule | `StaleRule`: a Mac is stale when the largest age of the dates in `thresholds.stale_basis` is more than `thresholds.stale_device_days`. Mobile and School use their own rules (Technical Plan). |
| FileVault verdict | `SecurityControlPolicy.verdict`: the workspace's `security_policy` level for FileVault (fail, warning, ignore) applied to the raw value, with `filevault_off_hardware_encrypted` for a Mac whose internal disk is hardware-encrypted (Apple silicon or T2, from `HardwareEncryption`). "Warning" is amber, not a gap. |
| NFR | The not-for-resale Jamf Cloud test server the maintainer collects from. |

## The Problem

The data to answer these questions is on disk, but the app cannot read it cheaply or
honestly today.

**Re-reading raw history does not scale.** A `computers` snapshot is 57 MB at 6,000 Macs,
115 MB at 12,000 and 192 MB at 20,000 (the synthetic large-fleet workspace made by the
maintainer's generator, outside the repo). At one snapshot every two days, a year at 20,000
Macs is about 35 GB. Aging needs months of history per device, so it cannot come from
re-reading snapshots on each render.

**A full row per device per day is also too much.** Measured on the 20,000-Mac workspace
(2026-11-24): about 200 bytes of facts per device per day, 4 MB a day, 1.46 GB a year (86 MB
compressed). How often those facts change could not be measured at fleet scale, because the
generator copies every date between its two days. On the four real NFR Macs over eleven
snapshots, the last check-in, inventory and contact dates changed on nearly every collect
(22, 21 and 29 changes across 10 steps); FileVault and OS almost never did. Dates therefore
need a different record from values that rarely change.

**The sources do not arrive daily.** A device missing from a day that had no scan is not
fixed; it was not measured. Every observation carries its own source's collection time, and
a gap opens or closes only on a complete observation.

**Facts stored as verdicts cannot be re-judged.** Storing FileVault as on/off applies the
workspace's `security_policy.on_values`/`off_values` at write time, so a later edit would
leave history judged by the old rule. The cache keeps raw values and the inputs every verdict
needs, and verdicts are made when a view reads it.

**A shared history file would be fragile.** Several Macs, sometimes on different app versions,
write one workspace folder; workspaces merge; retention can sweep snapshots. A single history
file in the workspace would need trust rules for a file any peer can write, version rules,
merge rules and an order-independent replay. Keeping the cache per Mac and rebuildable avoids
all of that.

## Goals

1.  **What changed.**
    *   Macs (B2), then Jamf Pro mobile devices and Jamf School devices (B4): enrolled,
        removed, went stale, came back, OS version changed.
    *   Macs only: FileVault turned off, FileVault stopped reporting, started or stopped
        failing a patch policy, and benchmark rules newly failing (Platform API workspaces
        only).
    *   The baseline is the newest snapshot from an earlier local day, and the view prints
        both collection times. Patch changes read "since the last scan (date)".
    *   Agent coverage changes are fleet counts, compared between two daily summaries.
2.  **Aging and time-to-fix (B3, B4).**
    *   Gap types: FileVault (Mac), stale (Mac, mobile, School) and patch failures (Mac, per
        device per policy).
    *   Each view shows the gaps open now and their ages, and the median days to fix over
        gaps fixed in the last 90 days, with the number of gaps the median counts.
    *   A gap ends in one of three ways:
        *   **fixed**: the same device, still in the fleet, observed out of the gap;
        *   **stopped failing** (patch only): gone from a complete scan while the Mac is still
            in `computers`. The scan lists failing devices only and nothing on disk says a
            policy was removed, so patch gaps are never called fixed;
        *   **left**: the device is absent from a complete observation.
    *   A FileVault or patch gap that began before the cache's first day reads "at least N
        days" and is counted beside the median, not in it. Stale ages are exact, because the
        start comes from Jamf's own date.
    *   Nothing is estimated. The median of fixed gaps leaves out gaps still open, so the
        view always shows the open ages beside it.
3.  **Per-version patch history (B1).**
    *   Every definition's release date for each title the definitions walk reads, listed per
        title on the Patch screen.
    *   Daily adoption of each version while Jamf reported it as the newest, with observed
        days to 50% and 90%.
    *   A fleet figure of days to 90% across titles per period, with "superseded before 90%",
        "not yet at 90%" and "no release date" counted apart.
4.  **Weekly digest (B4).** An opt-in webhook card once a week per workspace with the
    figures that moved most since the newest daily summary at least 7 days older, with
    direction, plus the change counts. Aggregates only.
5.  **Surfaces.** An Overview section, a line on the success digest card (`full` detail only),
    Health Audit, the Patch screen, the workbook (new tabs, and sections appended to Fleet
    Drift) and the HTML report. Each figure names the rule in force and how far back its
    history reaches.
6.  **The house rules hold.**
    *   Identity joins by Jamf ID then serial (Jamf School: UDID then serial), never by name.
        A row with neither is counted, not joined.
    *   A fact no device reports is unknown, never 0.
    *   Webhook cards and on-device AI input carry aggregates only.
    *   No figure combines workspaces.

## Non-Goals

*   **New jamf-cli collection.** A later wave: per-version share through `patch-report`,
    deployment dates, change records and the software-installs title map.
*   **Per-device agent aging.** `ea-results` rows carry only a computer name, and names are
    reused. A later collect wave gets a real ID onto agent data, measured for snapshot size
    first. Wave B shows fleet agent coverage only.
*   **Owner view, remediation queue and goal lines.** A later wave. It reads current site,
    department and building from the newest snapshot, and can add location to the cache by
    rebuilding it.
*   **Re-aging stale history for thresholds under 14 days** (see the quiet-span floor).
*   **Moving or renaming anything in the Fleet Drift tab.** New sections are appended at the
    end, with a CHANGELOG "Changed" bullet.
*   **Estimating unobserved time.** No survival curves or interpolated fix dates.
*   **One history shared by every Mac.** Each Mac's cache is its own; after a retention
    sweep, two Macs can show different aging for the same period.
*   **Figures across workspaces.**

## Open Questions

*   **Patch failure rows on a real tenant.**
    *   No `patch-device-failures` snapshot on the test Macs has a failure row (NFR has
        seven, all empty), so `device_id` and `policy_id` are unverified against real data.
    *   Go/no-go: the patch parts (B2's patch counts and Fleet Drift section, B3's patch
        aging) ship hidden ("not measured") until a fixture captured from a tenant with a
        failing patch policy is in the tests.
    *   The maintainer captures it on the NFR server by scoping a patch policy that fails.
Answered:

*   Patch failure rows on a real tenant (2026-11-25): a patch policy failing a download on
    the NFR server (jamf-cli 1.38.0, Jamf Pro 11.34) gives `device_id` and `policy_id` as
    strings and `attempt` as text, and the device stays out of `device_failures` while its
    download is PENDING. The capture is a test fixture and the patch parts ship visible.

*   jamf-cli 1.38.0 pages `definitions` on its own (2026-11-25, NFR). Paging on 1.29-1.37 is
    unverified; a title with exactly 100 definitions reads "the 100 newest versions".

*   `computers` rows carry `general.site.id` and `userAndLocation.departmentId`/`buildingId`
    (2026-11-24). Wave B does not store them (Non-Goals).
*   The scan's `status_date` is the date of the latest status and moves with each retry, so it
    is not the start of a failure. A patch gap starts at the first scan that lists the pair.

## Critical User Journeys (CUJs)

### CUJ 1: Morning check after a collect (B2)

*   **Given**: a Jamf Pro workspace with `computers` snapshots from today and an earlier day.
*   **When**: the admin opens the Overview.
*   **Then**:
    *   A "Since <baseline time>" section lists each change type with a count.
    *   Each count opens Computers with exactly the Macs it counted, from the same two
        snapshots. Macs that left are listed from the baseline snapshot.
    *   A change type with no source on either side reads "not measured", never 0. A baseline
        over the read limit reads "could not be read: over the 256 MB limit".

### CUJ 2: How long have Macs been without FileVault? (B3)

*   **Given**: the cache holds at least one FileVault observation per Mac.
*   **When**: the admin opens Health Audit.
*   **Then**:
    *   The FileVault card shows open gaps by age band, and the median days to fix over the
        last 90 days with its count.
    *   It also shows "history from <date>" and the rule in force.
    *   A gap that began before the history start reads "at least N days".

### CUJ 3: A rule edit re-ages history (B3)

*   **Given**: `security_policy.on_values.filevault` changes, or `stale_device_days` moves
    from 30 to 21.
*   **When**: any aging view is read next.
*   **Then**: gaps are recomputed from the cached facts under the new rule, and the view names
    the rule in force. A stale threshold under 14 days says history before the change was
    recorded only for quiet periods of 14 days or more.

### CUJ 4: Shared workspace with an older Mac (B3)

*   **Given**: a 2.12 Mac and a 2.13 Mac share a workspace, and the 2.12 Mac collects for
    three days while the 2.13 Mac stands down.
*   **When**: the 2.13 Mac's next run ends.
*   **Then**: its cache applies the three days of snapshots the 2.12 Mac wrote, and the log
    says how many it applied.

### CUJ 5: Version history for a title (B1)

*   **Given**: daily `patch-status` and dated `patch-release-dates` snapshots, and a
    `patch-version-dates` sidecar, for a title.
*   **When**: the admin opens the Patch screen.
*   **Then**:
    *   The Version History card, with the title chosen in its picker, lists every version
        Jamf defines, with its release date.
    *   Each version that was the newest shows its adoption windows and their observed days
        to 50% and 90%.
    *   The fleet figure shows the median and 90th percentile of days to 90% over the last 90
        days, with the superseded, not-yet, already-at-90% and no-release-date counts beside
        it.

### CUJ 6: Patch failures that linger (B3)

*   **Given**: two complete weekly scans list Mac 1042 failing policy 17.
*   **When**: the admin opens Health Audit.
*   **Then**:
    *   The patch card counts the pair as open, aged from the first scan that listed it.
    *   When a later complete scan no longer lists it and Mac 1042 is still in `computers`,
        the pair closes as "stopped failing".
    *   The median days to stop failing is accurate to the scan interval, about 7 days.

### CUJ 7: Jamf School (B4)

*   **Given**: a Jamf School workspace with `school-devices` snapshots.
*   **When**: the admin opens the School Overview.
*   **Then**:
    *   The change section and stale aging use the School rules (last check-in only;
        unknown is not stale).
    *   FileVault and patch aging are absent, with "Jamf School does not report this".

### CUJ 8: Weekly digest (B4)

*   **Given**: the weekly digest is on and a usable webhook is set; two Macs share the
    workspace.
*   **When**: the background item runs in a new ISO week.
*   **Then**:
    *   One card goes out for the workspace, whichever Mac sends first.
    *   It lists the figures that moved most since the newest summary at least 7 days
        older, with that summary's date, plus the change counts.
    *   With under 7 days of summaries it says so instead.

## Technical Plan (Architecture)

### Where each stage gets its data

```text
                      collect (CollectRouter.run, under the tick lock)
                                      |
      +-------------------------------+
      |                               |
 patch definitions walk         Jamf Pro summary step (finalize)
 (refresh tier)                 (B2 change counts)
      |                               |
      v                               v
 patch-release-dates_<ts>       summary_<day>.json .changes --> Overview, success digest,
 patch-version-dates_<ts>                                        Fleet Drift (appended)
 (written only on a change)
      |
      v
 Patch screen, Version History tab, HTML

 snapshots on disk --> aging-cache fill (B3) --> Application Support/JamfReports/
                       started when a reader      aging-cache/<workspace>.json
                       needs the cache, and           |
                       after each GUI collect         v
                                               Health Audit, Overview line, Patch row,
                                               Gap Aging tab and HTML (generate awaits)
```

### B1: per-version patch history

**Every definition's release date.** `collectPatchReleaseDates` already holds each title's
whole definitions list in memory and keeps one entry (`latestDefinitionDate`). From the same
loop it now keeps every definition as a row of `patch-version-dates`:
`{title_id, title, version, release_date, absolute_order_id}`. The existing kind keeps its
shape. jamf-cli pages `definitions` on its own (measured on the NFR server with jamf-cli
1.38.0, 2026-11-25: Acrobat Reader returned 176 rows and Chrome 914 at `--page-size 100`, the
same as `--all`, as a bare array), so no flag changes. A row is about 220-280 bytes, so Chrome
alone is about 200 KB.

**Written only when it changes.** Definitions change only when a vendor ships a version, so
the sidecar is not written on every walk. After `patch-release-dates` is written, a pure
`patchVersionDatesUpdate` merges this walk's answers with the newest sidecar:

*   A title whose definitions call returned a JSON array is answered; `[]` gives one marker
    row `{title_id, title, no_versions: true}` ("Jamf lists no versions").
*   A title still in `patch-status` that did not answer (failed call, unsafe ID, a body that
    is not an array) keeps its earlier rows, marked `stale_since` with the stamp of the file
    they came from, kept unchanged on later carries. A title gone from `patch-status` is
    dropped.
*   Rows are sorted (title ID, order ID as a number, version), encoded with sorted keys and
    no pretty printing, and compared byte for byte with the newest sidecar. A new file is
    written, stamped at write time, only when the bytes differ, the newest file is missing
    or unreadable, or it is older than half the effective `snapshot_keep_days` (7 days at
    most, and 7 days when retention is off), so a retention sweep never leaves the folder
    empty.
*   Nil keys are left out; values are trimmed, and a blank value is nil; a definition with
    a blank version is dropped.

The sidecar is a sidecar of `patch-release-dates`, not a collect kind:

*   It is written only by that walk, and inherits its `collect_skip` entry, timeout hold and
    tier. A walk that stops early or where no title answered writes no sidecar.
*   It is not in `knownCollectKinds`, `CollectionTier` or `expectedKinds`, so Data Freshness
    never reports it.
*   The Patch screen reads "release dates not read" for a title in `patch-status` with no
    sidecar rows, "dates from <day>" for carried rows, and "could not be read" for a sidecar
    that exists but cannot be read, never "no dates".
*   A peer's sidecar is read like any snapshot; this Mac carries its rows forward under its
    own stamp. A 2.12 Mac ignores the folder.
*   Both patch release-date files are written through `AtomicInstall.write`, mode 0600.

**Adoption per version.**

*   `PatchVelocityBuilder.loadDailyRows` already reads every dated `patch-status` snapshot;
    each row's `latest` is now kept.
*   A version's window opens on the first day Jamf reports it as `latest` and closes on the
    first later day Jamf reports another version. A version that returns (A, then B, then A)
    gets a second window. "Newest" means what Jamf reported that day.
*   Adoption within a window is `on_latest / total` that day, as today. A crossing counts
    only when seen in the series.
*   Days to 50% and 90% count from the version's release date. The lookup key is
    (`title_id`, else the lower-cased title name) plus the trimmed version. Precedence: an
    answered sidecar row with a date, then the newest dated `patch-release-dates` row, then a
    carried sidecar row. One lookup is built per read. Dated `patch-release-dates` files older
    than 180 days (`releaseFileDays`) are not searched for older versions' dates; the newest
    file is always read, and the sidecar dates older versions. With no release date, the window keeps
    its series and has no days-to figure.
*   A day with the title missing, `total == 0` or a blank `latest` adds no point and does not
    close a window. A window with no points is dropped.
*   Each window has its own outcome, from its series alone: **crossed** (a later point reached
    90%), **already at 90%** (its first point was at or above 90%), **superseded** (closed
    below 90%) or **open** (still below 90%).
*   **The velocity card uses the same calculator.** Patch Velocity's release date, days to 50%
    and 90% and days behind come from each title's latest window (the window of the version
    on the newest day with a non-blank `latest`). Release dates therefore match by version as
    well as by title.

**Fleet figure.** Over the last 90 days on every surface:

*   Everything is counted in windows.
*   The median and 90th percentile of days to 90% over crossed windows that have a release
    date, placed by crossing date. They are shown when at least 5 crossed, else the count
    alone.
*   Four counts sit beside the median, never inside it:
    *   crossed windows with no release date ("no release date"), placed by crossing date;
    *   windows that closed below 90% ("superseded before 90%"), placed by close date;
    *   windows still below 90% ("not yet at 90%"), always counted;
    *   windows already at 90% when first seen ("already at 90%"), placed by start.

    Percentiles use the nearest-rank method on whole days, here and in `GapLedger`.

**Jamf School and mobile:** no patch titles, so nothing.

### B2: Mac change view

**Stages (2026-11-25).** B2 is built in three stages:

*   **B2a:** the Mac counts, the two Fleet Drift sections, the stored `computers` and
    `benchmarks` parts and the digest fact. `computerChanges` is built from this run's
    landed snapshot and the newest earlier-day file.
*   **B2b:** the patch half (`PatchFailureDrift` and the `patch` part). It waits for a
    `patch-device-failures` fixture captured from a failing patch policy, so the comparison
    is tested on a real shape.
    Built on 2026-11-25 against a failing patch policy captured on the NFR server
    (jamf-cli 1.38.0): `PatchFailureDrift.isEnabled` was dropped, a pair that drops off reads
    "No longer listed as failed" (a download still retrying is PENDING and not listed), and
    the baseline is the newest scan from an earlier day.
*   **B2c:** opening the Macs behind an Overview count in Computers. CUJ 1's "each count
    opens Computers" moves here; B2a shows counts only.

The baseline is decoded with the existing `ComputerDates.decodeSnapshot`, with no reduced
decode. The collect's peak memory is measured on a 20,000-Mac workspace, and a reduced
decode follows only if the peak passes the target.

**One FileVault reader.** Three places read FileVault today and disagree:

*   `DeviceInventoryService` reads `diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State`,
    then `operatingSystem.fileVault2Status`, then `diskEncryption.fileVault2Enabled`.
*   `CoreDashboard`'s security sheet skips the second field and maps the Bool to
    ENCRYPTED/UNENCRYPTED.
*   The new readers would make a third.

One static, `FileVaultValue.raw(computer:)`, returns the raw value by the first chain, with
the Bool spelled `"true"`/`"false"` as the Devices screen shows it today. All three use it,
so the verdict sees one spelling. The security sheet still shows ENCRYPTED/UNENCRYPTED for
`"true"`/`"false"`. One cell changes: a Mac whose partition state is blank and whose
`operatingSystem.fileVault2Status` is set now shows that status on the sheet instead of the
Bool. That gets a CHANGELOG "Changed" bullet. Hardware encryption comes from `HardwareEncryption.isHardwareEncrypted(computer:)`.
The verdict comes from `SecurityControlPolicy.verdict(for:value:hardwareEncrypted:)`, which
takes the raw value.

**FileVault transitions**, used by B2 and B3 alike:

| Before | Now | B2 change | B3 effect |
| --- | --- | --- | --- |
| on or warning | gap | turned off | gap opens |
| unknown | gap | (none) | gap opens at this observation |
| gap | on or warning | (none) | gap closes as fixed |
| on, warning or gap | unknown | stopped reporting | no change; "not reported since <date>" |
| any | any, at level `ignore` | (none) | FileVault aging hidden: "FileVault is not counted (security_policy)" |

**The comparison.** `SnapshotFleetDrift` already joins two `computers` snapshots by Jamf ID
then serial through `ComputerDateIndex` (unidentified and ambiguous counted, never joined by
name). It reports joined, left, OS changed, became stale and no longer stale, with the
large-change guard. B2 adds:

*   `ComputerDates` gains `fileVault` (raw), `neverInventoried` and `hardwareEncrypted`
    (from the seams above), read in `init(item:)`.
*   Two lists, FileVault turned off and FileVault stopped reporting, per the table. Both are
    nil, not empty, when either snapshot carries no FileVault field at all.
*   `PatchFailureDrift` compares the two newest complete `patch-device-failures` scans:
    pairs `(device_id, policy_id)` that started failing or stopped failing (stopped only
    while the Mac is in the newest `computers` snapshot at or before the newer scan). A row
    with either ID empty is counted and left out.
*   `BenchmarkRuleDrift` compares the two newest `compliance-rules` snapshots (one file per
    collect, rows carrying `benchmark`), decoded through `ComplianceBenchmarksService`'s
    lenient rule decoder. A rule is keyed by `benchmark` plus `ruleId`, else the rule title.
    It is newly failing when `failed` was 0 and is now above 0. A rule with `failed` nil on
    either side, or whose benchmark is in only one file, is not compared and is counted as
    "not compared". Absent on a workspace without that kind.

**Persisted counts.** The Overview cannot decode two 192 MB snapshots on each render, so the
counts are computed during the collect and written to the day's summary as a new optional
object, `DailySummary.changes`, with three parts: `computers`, `patch` and `benchmarks`.

*   Each part records:
    *   both snapshot stamps (the `yyyyMMdd'T'HHmmss` stamp in the file name);
    *   the rule it was judged under (stale days and basis, and a fingerprint: the first 8
        hex characters of a SHA-256 over the FileVault level, sorted `on_values`, sorted
        `off_values` and the hardware level, joined by `|`);
    *   its counts, every count Optional. The keys are in the implementation plan.
*   `becameStale` and `noLongerStale` are nil when Fleet Drift reports `staleNotCompared`.
*   A part is written only on a run where its source landed. The current side comes from
    rows reduced while the payload is in memory (`LandedSources` keeps `[ComputerDates]`, a
    few MB, not raw bytes).
*   The baseline is one bounded read of the earlier snapshot. A baseline over the read limit
    leaves the part with `baselineUnreadable` set and no counts, shown as "could not be
    read".
*   A part the run cannot compute keeps the earlier same-day value (`filling(from:)`).
    `numbersAreInRange` checks each part alone, and a bad part is dropped, not the summary.
*   A 2.12 Mac that rewrites the same day's summary drops `changes`. The Overview then reads
    the newest summary that has it and prints that day.

Agent coverage changes are not stored: the Overview and the digest compare
`securityAgentCoverage` between today's summary and the newest earlier one that has it.

**Surfaces.**

*   **Overview:** a "Since <baseline time>" section, one row per count. "Not measured" for
    an absent count, "could not be read" for an unreadable baseline, and the large-change
    note when set.
*   **Drill-through:** each count opens Computers with a change filter carrying the two
    stamps. The filter re-runs the comparison on exactly those two files, off the main
    actor.
    *   Macs that left are shown in a "Left since <date>" list built from the baseline file.
    *   If a file is gone it says "snapshot no longer on disk".
    *   If the rule changed it says "the rule changed since these counts".
*   **Success digest card:** in `full` detail, one `Changes` fact with counts only.
*   **Fleet Drift tab:** three sections appended after the existing ones:
    *   "FileVault changes";
    *   "Patch policy failures since the last scan";
    *   "Benchmark rules newly failing".

**When a snapshot is complete.** This matters to B2's patch counts and to every B3 exit.

| Source | Complete when |
| --- | --- |
| `computers`, `mobile-devices-list`, `school-devices` | The file decodes, and its comparison with the previous complete one does not trip the large-change guard (`SnapshotFleetDrift.largeChangePercent`, generalised in B4). A file over the guard is used only to open gaps and update values, never to close presence; it is logged and counted. Files written by 2.12 are judged the same way. |
| `patch-device-failures` | The file decodes as rows. `patchDeviceFailurePayload`'s fallback, which today saves `[]` for any stream with no `device_failures` rows (one section or several), stops saving and records an unlanded attempt with its own cause ("no device_failures section in jamf-cli output"). jamf-cli 1.29 and later always send the envelope, so this affects only unreadable output. |
| `patch-status`, `compliance-rules` | The file decodes. |

### B3: the aging cache

**A cache, per Mac, never the record.**

*   The cache is `~/Library/Application Support/JamfReports/aging-cache/<WorkspaceID.pathComponent>.json`:
    per Mac, 0600, written through `AtomicInstall.write`, read through `BoundedFile`.
*   No peer reads it, a merge does not move it, and the diagnostic bundle does not include it.
*   It holds facts derived from the snapshots in the workspace's data folder, and the views
    read it instead of the snapshots.
*   When it cannot be trusted, the source concerned is rebuilt from the snapshots on disk:
    *   no file, an unreadable file, or a `schemaVersion` (an integer, raised only when the
        layout changes) other than this build's;
    *   a snapshot stamped earlier than the newest one applied for its source (a peer's file
        that synced late, or a merge), that is not older than the source's first day.
*   A rebuild is resumable: the source's state records `rebuilding` and the stamp to resume
    from, so a later run continues it rather than starting again.
*   The cache is read up to `BoundedFile.snapshotLimit` (64 MB). A cache over that is not
    rebuilt (a rebuild would give the same size): the views say "aging cache too large" and
    A8 and A9 are reconsidered.

**What it holds: facts as spans, never verdicts.**

| Record | Key | Fields | Opens and closes |
| --- | --- | --- | --- |
| Observation log | source, snapshot stamp | complete, applied | One entry per applied snapshot; the source's first day is its oldest entry |
| Presence | device key | first seen, last seen | Opens on first sight; closes on the first complete observation without the device |
| Value span | device key, field (`fileVault`, `neverInventoried`, `hardwareEncrypted`, `osVersion`) | raw value, from, to | A new span starts when the value changes |
| Quiet span | device key, date field | Jamf's date (or "absent"), floor, first observation above the floor, end observation | Opens when the date's age at an observation passes the floor, or the date is absent where the source dates every device; closes on the first observation with a newer date |
| Patch failing span | Mac device key, policy ID | first scan, last scan, end scan | Opens on the first complete scan that lists the pair; closes on the first complete scan that does not |

*   **Device key.** The source plus the identifier, so ID spaces never collide:
    `computers:jamf:<id>`, else `computers:serial:<serial>`; `mobile:` (Jamf ID, then serial)
    and `school:` (UDID, then serial) likewise. Each device record keeps every identifier it
    has been seen with (`aliases`), and a row resolves against those through the
    `ComputerDateIndex` rule (or its B4 generalisation), so a row that carries an ID in one
    snapshot and only a serial in the next keeps one key. Ambiguous and unidentified rows are
    counted per observation, never stored.
*   **The floor (decided 2026-11-24).** The lower of 14 days and the stale threshold at write
    time, stored on each span. Weekly inventory and daily check-ins write nothing; a span
    marks a quiet period of two weeks or more. Any threshold at or above a span's floor
    re-ages it exactly.
*   **Patch spans** key on the Jamf ID from `device_id` joined to the Mac's `computers` key.
*   **School trash.** A School device in the trash is a value (`inTrash`), so it does not read
    as left.

**Gaps are judged when a view reads the cache.** A pure module, `GapLedger`, takes the cache,
the rules in force and the period:

*   **Mac stale.** It rebuilds `StaleInputs` from the quiet spans of the basis fields
    (`carriesDates` true for `computers`) and calls `StaleRule.age`. It does not
    re-implement the rule. At an observation where a basis field has no open quiet span, the
    date is known to be younger than the floor, so the rebuilt input uses the observation
    time itself (age 0), which is correct for every threshold at or above the floor. No
    "absent" spans are recorded for `contact`, because a missing Last Contact is unknown, not
    old (`StaleRule`).
*   **Mobile stale.** The inventory date's quiet spans against `stale_device_days`, through
    `MobileSummary.isStale`'s rule.
*   **Jamf School stale.** The last check-in's quiet spans; unknown is not stale
    (`SchoolFleetService`'s rule).
*   **FileVault.** `SecurityControlPolicy.verdict(for:value:hardwareEncrypted:)` over the
    value spans, per the transition table.
*   **Patch.** The patch failing spans.

Open stale ages need no cache: the views read them from the newest snapshot through
`StaleRule.age`. The cache adds the stale time-to-fix median and the history of closed gaps.

| Event | Effect |
| --- | --- |
| First observation in a gap | Gap opens. Stale opens at Jamf's date plus the threshold, which can be before the first observation. FileVault and patch open at the observation. |
| FileVault or patch gap open at the source's first day | Age reads "at least N days"; left out of the median and counted beside it |
| Complete observation out of the gap | Closes as fixed (patch: stopped failing) at that observation's time |
| Device absent from a complete observation | Closes as left; takes precedence over every other exit at the same observation |
| Value unknown | No change; the gap stays open and shows "not reported since <date>" |
| Off, on, off | Two gaps |
| A quiet span's date moves older (a restored record) | The span stays open; the newer date already seen stands |
| Rule change | Every gap is re-judged on the next read; the view names the rule in force |

**Periods.** The median counts gaps that closed as fixed (or stopped failing) in the period,
keyed by the close date, shown with its count when that count is at least 5.

*   Every surface: the last 90 days.
*   The weekly digest: none (it carries counts only).

**The fill (decided 2026-11-25: fill on read).** The cache's only readers are views and
report generation, so the fill runs where it is read, never inside a collect:

*   **In the app:** a view that needs the cache (Health Audit, the Overview line, the Patch
    row) starts a fill off the main actor when it opens and shows "filling" until it
    catches up. A finished GUI collect also starts one in the background, so the views are
    usually current already.
*   **Report generation** (the Gap Aging tab and HTML section, from the GUI, a scheduled
    run or the CLI) awaits the fill, up to its budget, before it writes them, then uses what
    the cache holds and says "filling: M snapshots left" if it did not catch up.
*   **Nothing else runs it.** No collect path, background tick or CLI collect waits on it,
    and the weekly digest does not need it (it reads summaries and `changes`).
*   **Lock.** One fill per workspace per Mac at a time, through a `flock` on
    `Application Support/JamfReports/aging-cache/<workspace>.lock` (the `TickLock` kind). A
    second caller that finds it busy does not wait: a view shows "filling", a generate run
    waits up to its budget for the lock and then reads the cache as it is.
*   **Stop.** An explicit stop closure passed in: the budget (10 minutes, counted from the
    fill's own start) or, in the app, a cancelled view task.
*   **What it does:**
    1.  Read the cache. If it is missing, unreadable or of another `schemaVersion`, rebuild
        every source.
    2.  List each source's snapshots through the existing snapshot listing
        (`FileManager.snapshotFolderEntries`, which drops sync-conflict copies and
        `manifest.json`), keeping those not in the observation log and not older than the
        source's first day. A snapshot stamped earlier than the newest applied one marks its
        source for a rebuild.
    3.  Apply snapshots oldest first, per source. A file that is not downloaded stops that
        source at that file, and nothing newer of the same source is applied until it
        arrives. "Not downloaded" is `CloudStorage.isDataless(_:)`, a new check: the
        `SF_DATALESS` flag from `lstat` (File Provider: iCloud Drive, OneDrive, Dropbox,
        Box) or a ubiquitous item whose downloading status is not current. A dataless file
        is never opened, so the fill never triggers or waits on a download.
    4.  A snapshot over its read limit is logged as skipped in the observation log (so it is
        not seen as late again) and named in the views.
    5.  Stop on the stop closure and write what it applied; the next fill resumes.
*   **Logging.**
    *   It writes one line to the caller's log (the generate run's log, or `AppLogger` in the
        app): `[info] aging cache: applied N snapshots (…); M left; rebuilding computers (late
        file 2026-11-20); waiting on 1 not downloaded`. Never `[partial]`.
    *   The views say "history from <date>". While snapshots are left, they say "filling: M
        snapshots left" or "rebuilding". While a file waits to download, they say "waiting
        for a file to download".
*   **Snapshots over the read limit** (above about 26,000 Macs for `computers`) cannot be
    read by the fill and are skipped and named ("N snapshots too large to read"). Fleets that
    size get aging only if A9's reduced digest is adopted, which the 50,000 and 100,000-Mac
    runs decide.
*   **Size bound.** Spans that closed more than the effective retention days ago
    (`SharedConfigPin.effectiveRetention`, `snapshot_keep_days`, 365 by default even when
    retention is off; 0 means keep every span) are dropped on write, with their
    observation-log entries, and the source's first day moves forward to match. Files older
    than the first day are then ignored by the listing, so they are never "late".
    `snapshot_keep_count` does not apply.

**Retention.** The cache is not in the workspace, so the retention sweep never touches it.
Once raw snapshots are swept (`mode: delete`) or moved to `_archive` (`mode: archive`, which
the fill does not read), only the cache holds that history. A rebuild after a sweep loses the
starts of gaps from before it, and those gaps then read "at least N days". The Config
retention copy says so.

**Reading it.** Views read the cache off the main actor, keep the decoded value per workspace
until the file's stamp changes, and record a signpost around the read and `GapLedger`. The
kept value clears on a profile switch, and demo mode never reads the cache (demo data comes
from `DemoData`).

### B4: mobile, Jamf School, weekly digest

*   **Change view.** `SnapshotFleetDrift` is generalised over a `DriftDevice` protocol
    (identifiers, dates, OS) with three conformers:
    *   `ComputerDates`;
    *   mobile rows from `MobileDeviceInventoryItem` (`mobileDeviceId`, `general.serialNumber`
        else `hardware.serialNumber`, `general.udid`, `general.lastInventoryUpdateDate`,
        `general.osVersion`), stale through `MobileSummary.isStale`'s rule;
    *   School rows through `SchoolFleetService` (UDID then serial, trash kept apart).

    Each uses its platform's stale rule. Mobile and School get enrolled, removed, went stale,
    came back and OS changed, persisted as `changes.mobile` and `changes.school` with the
    same rules as `changes.computers`. FileVault, patch and benchmark rows are absent with
    "<platform> does not report this".
*   **Stale aging.** From the cache, on the Mobile Devices screen and the School Overview,
    and in a School "Gap Aging" workbook tab.
*   **Weekly digest.**
    *   **Key.** `notify.weekly_digest` (boolean, default false; a non-boolean reads as off
        and Config Doctor names it), pinned with the other `notify` keys in `SharedConfigPin`.
    *   **When.** On the background item's tick, after its due schedules ran, once per ISO
        week per workspace. It uses the workspace-scoped `DayMarker.sendOnce` (the
        `overdue-notify` pattern), keyed `YYYY-'W'ww` on `Calendar(identifier: .iso8601)`.
    *   **Which workspaces.** The heartbeat's targets (`notifyTargets`), each through
        `SharedConfigPin.effectiveNotify`. The marker is named `weekly-digest`.
    *   **What.** Today's summary against the newest summary at least 7 days older. The
        candidates are the `TrendSeries.Metric`s the workspace offers that have a value in
        both. Each is ranked by the size of its change: percentage points for a share, and
        for a count its change as a percentage of the larger of the two values. The top 5 with
        a change that does not round to nothing are listed, each worded through
        `TrendChange` ("FileVault on: 91.2% → 93.0% (+1.8 pp, better)"). Facts: `Week`
        (`2026-W48`), `Since` (the baseline summary's date), the up to 5 figures, then
        `Changes` (the same text as the success card).
    *   **`minimal` detail** sends `Week`, `Since` and `Changes` only.
    *   **With under 7 days of summaries,** the card says so.

### Surfaces by stage

| View | Mac | Mobile (Jamf Pro) | Jamf School |
| --- | --- | --- | --- |
| Change counts | B2: Overview, digest line, Fleet Drift tab | B4: Mobile Devices screen | B4: School Overview |
| Stale aging | Open ages: newest snapshot. Time-to-fix: B3, on Health Audit, the Overview line, the "Gap Aging" tab and the HTML report | B4: Mobile Devices screen, Gap Aging tab | B4: School Overview, School Gap Aging tab |
| FileVault aging | B3, same surfaces as stale | Not reported | Not reported |
| Patch failure aging | B3: Health Audit, Patch screen, Gap Aging tab | No patch titles | No patch titles |
| Per-version patch history | B1: Patch screen (Version History card), "Patch Version History" tab, HTML Patching group | None | None |
| Benchmark rules newly failing | B2: Overview, Fleet Drift tab (Platform API only) | None | None |
| Weekly digest | B4 | B4 | B4 |

The on-device AI insight gets the open-gap counts and medians only (B3), through
`FleetInsightInput`.

## Risks and Mitigations

| Risk | Failure mode | Mitigation | Residual |
| --- | --- | --- | --- |
| Partial snapshot | A truncated `computers` file closes every gap as left | The large-change guard marks it not complete; presence never closes on it | A real mass retirement over the guard closes gaps one complete snapshot late |
| Late or merged snapshot | Spans built out of order | The source is rebuilt from disk | A rebuild takes several runs at 20,000 Macs; the views say "rebuilding" |
| Cloud-evicted file | A hole in history | The source waits at that file | A file that never downloads holds that source back; the views say so |
| Retention sweep | Rebuild loses gap starts from before the sweep | Rebuild only when needed; "at least N days" | Two Macs can show different aging |
| Snapshot over the read limit | B2 baseline unreadable; rebuild skips the file | Current side from memory; "could not be read" wording | Above about 26,000 Macs, B2's counts need two days in a row landed on this Mac |
| Memory in collect | `LandedSources` holding raw bytes | Keep reduced rows only (a few MB); one bounded baseline read | Peak is measured in B2 (NFR) |
| Fill never runs | Nothing reads the cache, so it falls behind | It fills on the next read; generate awaits it | The first read after a long absence shows "filling" |
| Cloud-evicted file opened | The fill triggers or blocks on a download | `CloudStorage.isDataless` before any read | — |
| Unverified patch rows | Wrong joins in B2 and B3 | Patch parts hidden until a captured fixture exists | — |
| 2.12 rewrite of today's summary | `changes` erased | Overview reads the newest summary that has it, with its date | — |
| Rule change | Persisted B2 counts judged under the old rule | The rule is stored with the counts; the drill-through says it changed | — |
| Version mismatch between Macs | — | The cache is per Mac; a different version means a rebuild | — |

## Alternatives Considered

### A1: A full row per device per day

*   **Pros**: Simple to write; any view can be derived from it.
*   **Cons**: About 1.46 GB a year at 20,000 Macs (measured row size). A day with no source
    reads as "unchanged" unless every row carries its source's time.
*   **Why not**: Size grows with fleet × days, and views would still need spans.

### A2: Store gap verdicts

*   **Pros**: Smallest record; views read it directly.
*   **Cons**: A gap is judged under one rule, so a rule edit cannot re-age history (CUJ 3).
*   **Why not**: The cache keeps facts, so rule edits re-age.

### A3: Every date change per date field

*   **Pros**: Any threshold re-ages.
*   **Cons**: About one record per active Mac per collect per date field; millions a year at
    20,000 Macs.
*   **Why not**: Quiet spans above a floor keep the facts that matter for staleness at a
    fraction of the size.

### A4: Stale gaps stamped with the rule in force

*   **Pros**: Simplest stale record.
*   **Cons**: A threshold change restarts stale history. Re-aging then needs a full rebuild
    from raw snapshots, about 35 GB read at 20,000 Macs, and is impossible after a sweep.
*   **Why not**: Quiet spans re-age with no rebuild.

### A5: A 7-day floor

*   **Pros**: Re-ages thresholds from 7 days up.
*   **Cons**: With weekly inventory, every Mac's inventory date passes 7 days once a week:
    about 1 million spans a year at 20,000 Macs.
*   **Why not**: A 14-day floor removes that churn; few fleets set a threshold under 14 days.

### A6: One shared, authoritative history file in the workspace (revision 1)

*   **Pros**: Every Mac sees the same history; history survives sweeps.
*   **Cons**: It needs trust rules for a file any peer can write (future stamps, a less
    complete store winning), version rules so an older Mac does not overwrite a newer store,
    a merge rule, and an order-independent replay or checkpoints for late files. It is also
    a second "what changed" calculator.
*   **Why not**: The Stage 5-8 review traced about 20 findings to it. A per-Mac cache that can
    be rebuilt has none of them.

### A7: Append-only change files with periodic full copies

*   **Pros**: Conflict-free with several writers.
*   **Cons**: Compaction, and a read that merges a full copy plus change files.
*   **Why not**: Only one writer per cache once it is per Mac.

### A8: SQLite, or files split per source and month

*   **Pros**: Partial writes; no whole-file rewrite.
*   **Cons**: SQLite files are known to corrupt on synced folders, and they would be a new
    dependency (the cache is not synced now, but the workspace was the first design).
    Splitting adds a file set to keep consistent.
*   **Why not**: The cache is expected to stay small (measured in B3); revisit at 50 MB.

### A9: A reduced digest beside each snapshot

*   **Pros**: B2 and rebuilds read 4 MB instead of 192 MB per snapshot. It keeps working
    above the 256 MB read limit.
*   **Cons**: A new file kind in the workspace that peers write, with its own trust,
    retention and version rules.
*   **Why not, for now**: Reduced rows in memory cover the current side. The digest is
    adopted only if the 50,000 and 100,000-Mac runs show rebuilds or baselines are
    unacceptable.

### A10: Compare raw snapshots at render time

*   **Pros**: No new file.
*   **Cons**: Two 192 MB decodes per Overview render at 20,000 Macs, and no aging.
*   **Why not**: B2 runs the same comparison at collect time, and on a click.

### A11: Read a window of raw snapshots

*   **Pros**: No cache.
*   **Cons**: 90 days at 20,000 Macs is about 45 snapshots, about 8.6 GB to decode per
    aging view, and history ends where retention cuts.
*   **Why not**: The cache reads a few MB.

### A12: Fill once behind a done marker (the Jamf School backfill pattern)

*   **Pros**: An existing pattern.
*   **Cons**: Not resumable; never fills holes from peers or rollbacks.
*   **Why not**: The fill runs after every run.

### A13: Store FileVault as on/off

*   **Pros**: Smaller.
*   **Cons**: A verdict under today's values.
*   **Why not**: Raw value plus hardware and never-inventoried facts.

### A14: Location IDs in the cache now

*   **Pros**: The owner view would have location history from day one.
*   **Cons**: A span on every move for fields no wave-B view reads.
*   **Why not**: The owner view mainly needs the current location, and a later wave can
    rebuild the cache with location added.

### A15: New collection for per-version share, deployment dates, change records and the title map

*   **Pros**: An accurate per-version share for every version.
*   **Cons**: New commands (`patch-report`, policy logs, App Installers), each with a
    timeout hold, a Data Sources switch and a captured fixture.
*   **Why not, in wave B**: A later wave; B1's version list is its base.

### A16: Per-device agent aging from `ea-results`

*   **Pros**: Asked for in the epic.
*   **Cons**: Rows carry a computer name only, and names are reused.
*   **Why not**: A later collect wave gets a real ID onto agent data first.

### A17: Rework the Fleet Drift tab

*   **Pros**: A cleaner tab.
*   **Cons**: Breaks report readers set up on its layout.
*   **Why not**: Sections are appended only.

## Non-Functional Requirements

*   **Memory and time.**
    *   B2 keeps reduced rows, not raw bytes, and reads one baseline. Peak memory of a
        20,000-Mac collect is measured before and after B2; the target is under 1 GB more
        than today.
    *   The fill decodes one snapshot at a time and frees it.
*   **Cache size.** Measured on the large-fleet workspace after a synthetic year in B3.
    Revisit A8 and A9 above 50 MB.
*   **Privacy.**
    *   The cache holds device keys (Jamf ID, serial, UDID), OS versions and FileVault
        values; no names, users or locations.
    *   It is per Mac, 0600, and outside the workspace, so it never syncs.
    *   Webhook cards and AI input carry counts only.
*   **Rollout and rollback.**
    *   New summary fields are optional, so 2.12 reads a 2.13 summary as before.
    *   2.12 ignores `patch-version-dates/` and the cache.
    *   A rollback and return rebuilds only if the version changed.
    *   No feature flag: each stage ships whole.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Paths are relative to `app/Sources/JamfReports/` unless they start with `app/` or the repo
root. Each stage is its own PR into the dev branch, merged in the order B1, B2, B3, B4. B1 and
B2 can be built in parallel; B2 rebases on B1 and resolves `CHANGELOG.md` with
`changelog-union`. Every stage adds its new user-visible strings through `L(...)`, runs
`app/scripts/sync-strings.zsh --prune-stale` and translates the new keys into every shipped
language (`app/Localization/Localizable.xcstrings`, checked by `LocalizationCatalogTests`).
Workbook tabs, HTML text, webhook cards and log lines stay English.

### Stage B1: per-version patch history

#### 1. `Engine/ReportEngine.swift`, `Engine/ReportEngine+CollectPlan.swift` (Modify)

*   `patchVersionDatesKind = "patch-version-dates"` beside `patchReleaseDatesKind`
    (`ReportEngine+CollectPlan.swift`). Not in `knownCollectKinds`, `CollectionTier` or
    `expectedKinds`.
*   In `collectPatchReleaseDates`, collect `answered` (title ID to rows) for titles whose body
    parses as an array, and the walked title IDs. After `writePatchReleaseDates` succeeds,
    read the newest sidecar, call `PatchReleaseDateService.patchVersionDatesUpdate`, and on
    `changed` write through `writePatchVersionDates(_:stamp:dataDir:)` with a stamp taken at
    write time. `refreshAfter` comes from `patchVersionRefreshInterval(_:)` over the effective
    retention. Log `[info] patch-version-dates: N title(s), unchanged` or `[ok]
    patch-version-dates: N title(s)`; a failed write is one `[warn]` and does not change the
    walk's result.
*   `writePatchReleaseDates` and the new writer both use `AtomicInstall.write(data, to:,
    mode: 0o600)` inside a 0700 folder, as `saveSnapshot` does.

#### 2. `Services/PatchReleaseDateService.swift` (Modify)

*   `struct PatchVersionDate: Codable` (`title_id`, `title`, `version`, `release_date`,
    `absolute_order_id`, `stale_since`, `no_versions`; nil keys omitted).
*   `enum VersionDatesRead { absent, unreadable(String), rows(...) }` and
    `versionDates(dataDir:)`, the newest sidecar through `BoundedFile.readSnapshotLogged`.
*   `patchVersionDatesUpdate(...)` and `patchVersionRefreshInterval(_:)`, both pure.
*   `releaseDateLookup(dataDir:)` (and a test seam over rows), with the key and precedence in
    the Technical Plan.
*   Drop the "Python twin" line in the header.

#### 3. `Engine/PatchVelocityBuilder.swift` (Modify)

*   `VersionWindow`, `VersionVelocity` and `FleetVersionSummary` (fields in the Technical
    Plan), `versions(days:lookup:)` (internal; `DayRows` becomes internal) and
    `summary(_:periodDays:now:)`.
*   `computeWithVersions(dataDir:releaseRows:now:)` is the one entry point: it reads the
    sidecar once (before the empty-history check), builds one lookup through
    `releaseDateLookup(releaseRows:dataDir:versionDates:now:)`, and returns the velocities,
    the windows and the sidecar read. The workbook (one cached call per run), the HTML report
    and the Patch screen all call it. `compute(dataDir:releaseRows:now:)` keeps its signature
    and returns its velocities.
*   `patchVersionDatesUpdate` takes no stamp: the earlier file's stamp travels in
    `VersionDatesRead.rows(stamp:)`.

#### 4. Workbook: `Engine/CoreDashboard.swift`, `Engine/Templates/ReportTemplate.swift`, `Engine/Templates/FullInstanceTemplate.swift`, `Models/Models.swift` (Modify)

*   `SheetID.patchVersionHistory`, raw value "Patch Version History", in the sheet plan after
    Patch Velocity.
*   The tab has columns Title, Version, Released, Window start, Window end, Days to 50%,
    Days to 90%, Outcome, then the fleet figure for the last 90 days.
*   It is skipped with `[skip] Patch Version History: no patch-status history` when there are
    no windows.
*   Added to `FullInstanceTemplate` and to the patch group of `CustomSheetGroup.allGroups`.
*   An entry in `CoreDashboard.sheetManifestDescriptions`.

#### 5. HTML: `Engine/Templates/ReportTemplate.swift`, `Engine/HtmlReport+Inputs.swift`, `Engine/HtmlReport+Sections.swift`, `Engine/HtmlReport+Layout.swift`, `Engine/Templates/FullInstanceTemplate.swift` (Modify)

*   `SectionID.patchVersionHistory`, a member of the Patching group in
    `HtmlDetailGroup.members`.
*   The data is loaded once in `Inputs`.
*   The block shows the fleet figure and a capped table of the 10 slowest versions to 90%,
    or a "Not included" reason.
*   Listed in Full Instance's `htmlSections`.

#### 6. `Views/PatchView.swift` (Modify)

*   A "Version History" card after the velocity card. It has a title picker over titles with
    definitions, the chosen title's versions (version, release date, windows, days to 90%),
    and the fleet figure for the last 90 days.
*   A title missing from the sidecar reads "release dates not read". Loaded off the main
    actor with the velocity card.
*   In demo mode the card shows `DemoData` version history, even though the velocity card
    stays hidden there.

#### 7. Tests (Create/Modify)

*   `app/Tests/JamfReportsTests/Engine/PatchVelocityBuilderTests.swift`:
    *   windows on `latest` changes and re-entry;
    *   the four outcomes;
    *   the release-date basis only;
    *   placement by period;
    *   the minimum of 5;
    *   nearest rank;
    *   the name fallback.
*   `app/Tests/JamfReportsTests/PatchReleaseDateServiceTests.swift`:
    *   sidecar round-trip with a null date;
    *   the existing kind unchanged (golden);
    *   the lookup order, newest file winning.
*   `app/Tests/JamfReportsTests/PatchVersionHistorySheetTests.swift` (Create): the tab's
    columns and skip line.
*   An HTML section case in the existing HTML layout suite.

### Stage B2: Mac change view

#### 8. `Services/FileVaultValue.swift` (Create); `Services/DeviceInventoryService.swift`, `Engine/CoreDashboard.swift` (Modify)

*   `enum FileVaultValue { static func raw(computer: [String: Any]) -> String? }`. It reads:
    1.  `diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State`;
    2.  then `operatingSystem.fileVault2Status`;
    3.  then `diskEncryption.fileVault2Enabled`, as `"true"`/`"false"`.

    Blank is nil.
*   `DeviceInventoryService.recordFromComputer` and the security sheet
    (`CoreDashboard.swift` around 2534) call it. The sheet maps `"true"`/`"false"` to
    ENCRYPTED/UNENCRYPTED for display only.

#### 9. `Services/ComputerDates.swift` (Modify)

*   Add `fileVault: String?`, `neverInventoried: Bool`, `hardwareEncrypted: Bool?`, read in
    `init(item:)` through `FileVaultValue`, `NeverInventoried` and
    `HardwareEncryption.isHardwareEncrypted(computer:)`.
*   A never-inventoried Mac's FileVault is nil (`NeverInventoried`: it reports no control).
*   `struct ComputerSnapshot { rows: [ComputerDates]; fileVaultReported: Bool }`, where
    `fileVaultReported` means any row has a FileVault value.
*   `ComputerDates.decodeComputerSnapshot(_:) -> ComputerSnapshot?`.
*   `decodeSnapshot` stays for its callers (`ComputerDateIndex(snapshot:)`,
    `SecurityScoreInputs`, `ReportEngine.swift` around 911).

#### 10. `Engine/SnapshotFleetDrift.swift` (Modify)

*   `init(current: ComputerSnapshot, currentAt:, prior: ComputerSnapshot, priorAt:, rule:
    StaleRule, policy: SecurityControlPolicy)`. The old initializer stays as a convenience
    with `.default` policy for the existing tests.
*   `fileVaultOff: [ComputerDates]?` and `fileVaultStoppedReporting: [ComputerDates]?`, nil
    when either side has `fileVaultReported` false. Judged per the transition table through
    `policy.verdict(for: .fileVault, value:, hardwareEncrypted:)`; empty lists at `ignore`.
*   `static func baselinePair(dataDir: URL) -> (current: (URL, Date), prior: (URL, Date))?`
    replaces the private `driftSnapshots()`.
*   Three sections appended to `writeFleetDrift` after the existing ones:
    *   **"FileVault changes":** columns Computer, Serial, Jamf ID, Before, Now; empty text
        "No changes"; "Not compared (no FileVault data in one snapshot)" when nil.
    *   **"Patch policy failures since the last scan":** columns Computer, Jamf ID, Policy,
        Policy ID, Change; empty text "No changes"; "Not measured" while
        `PatchFailureDrift.isEnabled` is false.
    *   **"Benchmark rules newly failing":** columns Benchmark, Rule ID, Rule, Failing devices;
        empty text "No changes"; "No compliance-rules history" when absent.

#### 11. `Engine/PatchFailureDrift.swift`, `Engine/BenchmarkRuleDrift.swift` (Create)

*   `struct PatchFailureDrift { static let isEnabled = false; init(current:
    [PatchFailureRow], currentAt: Date, baseline: [PatchFailureRow], baselineAt: Date,
    computers: ComputerDateIndex) }`.
    *   Output: `startedFailing` and `stoppedFailing` (`[PatchFailureRow]`), plus `leftOut`
        (empty ID) and `notInComputers` (`device_id` matching no Mac), both `Int`.
    *   `static func scanPair(dataDir:) -> (current: URL, baseline: URL)?`: the two newest
        scan files.
*   `struct BenchmarkRuleDrift { init(current: [Rule], baseline: [Rule]) }`.
    *   Output: `newlyFailing: [Rule]` and `notCompared: Int`.
    *   It uses `ComplianceBenchmarksService`'s rule decoder, made internal
        (`decodeRules`).

#### 12. `Engine/ReportEngine.swift` (Modify)

*   Only the non-envelope fallback changes (the final `return Data("[]".utf8)`). A 1.29
    envelope whose `device_failures` data is `[]` or null stays a healthy zero.
*   `patchDeviceFailurePayload` returns `PatchFailurePayload` (`.rows(Data)`,
    `.noDeviceSection`, `.unreadable`) instead of `Data?`. The caller records an unlanded
    attempt for both failure cases. `.noDeviceSection` logs `[warn] patch-device-failures: no
    device_failures section in jamf-cli output; not saved`, and `.unreadable` keeps today's
    "output is not JSON" text.
*   Update the doc comment.
*   `saveSnapshot` returns the URL it wrote (`@discardableResult`).

#### 13. `Services/SummaryJSONParser.swift` (Modify)

The new Codable types:

```text
FleetChangeSummary { computers: ComputerChanges?, patch: PatchChanges?,
                     benchmarks: BenchmarkChanges?, mobile: DeviceChanges?,   // B4
                     school: DeviceChanges? }                                 // B4
  JSON keys: "computers", "patch", "benchmarks", "mobile", "school"
ComputerChanges { current_stamp, baseline_stamp, current_count, prior_count: Int?,
  stale_days, stale_basis: [String],
  filevault_rule: String (8 hex), baseline_unreadable: Bool?, large_change_percent: Int?,
  joined, left, os_changed, became_stale, no_longer_stale, filevault_off,
  filevault_stopped_reporting, unidentified, ambiguous: Int? }
PatchChanges { current_stamp, baseline_stamp, started_failing, stopped_failing,
  left_out, not_in_computers: Int? }
BenchmarkChanges { current_stamp, baseline_stamp, newly_failing, not_compared: Int? }
DeviceChanges (B4) { current_stamp, baseline_stamp, current_count, prior_count,
  stale_days, baseline_unreadable,
  large_change_percent, joined, left, os_changed, became_stale, no_longer_stale,
  unidentified, ambiguous }
```

*   `DailySummary.init(from:)` decodes `changes` with `try?`, and each part with `try?`, so a
    malformed part becomes nil.
*   `FleetChangeSummary.validated()` drops any part with a negative count, or with
    `joined`/`left` above `max(current_count, prior_count)` (a part missing either count fails
    that check). It runs in `DailySummary.init(from:)`, right after `changes` is decoded, so
    `numbersAreInRange`, which does not look at `changes`, never sees a bad part.
*   `filling(from:)` takes each part whole from the newer summary when present, else from
    the older one.
*   `freshSummaryIsBetter` counts a part present only in the new summary as an upgrade.

#### 14. `Engine/ReportEngine+EnvironmentFinalize.swift`, `Engine/ReportEngine.swift` (Modify)

*   `LandedSources` gains `computerSnapshot: (stamp: String, snapshot: ComputerSnapshot)?`
    and `patchFailures: (stamp: String, rows: [PatchFailureRow])?`.
    *   They are set at the per-kind save (`ReportEngine.swift` around 3503) from the payload
        already in memory, using the URL `saveSnapshot` returns.
    *   No raw bytes are kept.
*   The finalize call of `emitSummaryJSON` (around 2939) builds the parts:
    *   `computers` when `computerSnapshot` is set, against
        `SnapshotFleetDrift.baselinePair`'s prior file. A baseline that `BoundedFile` refuses
        for size sets `baseline_unreadable`.
    *   `patch` when `patchFailures` is set and `PatchFailureDrift.isEnabled`.
    *   `benchmarks` when `compliance-rules` landed.
*   The early summary (around 2850) and the generate path (around 239) build no parts. A
    collect without the router (`landedSources` nil) has no `changes`.

#### 15. `Views/OverviewView.swift`, `Models/OverviewLayout.swift` (Modify)

*   `OverviewSection.changes` ("Since last collect"), declared second, after `aiInsight`.
    Its position is now part of the standard order.
*   `availability(in:products:)` gains `EnvironmentProducts`. `.changes` is offered when
    `products.has(.jamfPro)` and the composition allows Macs; the existing call sites pass
    `store.environmentProducts`.
*   The section reads the newest summary that has `changes`. When that is not today, it
    prints its day.
*   It shows:
    *   one row per count;
    *   "Not measured" for nil, "Could not be read: over the 256 MB limit" for
        `baseline_unreadable`, and the large-change note;
    *   agent coverage changes from `securityAgentCoverage` in two summaries;
    *   in B3, the oldest-gap line.

#### 16. Drill-through: `Views/DevicesView.swift`, `App/ContentView.swift`, `Services/WorkspaceStore.swift` (Modify)

*   `struct ChangeFilter: Sendable { kind: ChangeKind; currentStamp: String; baselineStamp:
    String; ruleFingerprint: String }`.
*   Carried in the navigation user info under `changeFilter`, held in
    `WorkspaceStore.pendingChangeFilter` beside `pendingDevicesFilter`, and forwarded by
    `ContentView`.
*   `DevicesView` loads the two files by stamp, off the main actor, runs `SnapshotFleetDrift`
    and filters to those Macs.
*   It shows:
    *   "Left since <date>" as a list from the baseline file;
    *   "Snapshot no longer on disk" when a file is gone;
    *   "The rule changed since these counts" when the fingerprint differs.

#### 17. `Services/ScheduledRunSignals.swift` (Modify)

*   `successFacts(..., changes: FleetChangeSummary? = nil)`. In `full` detail it adds
    `Changes`, for example "+3 enrolled, −1 removed, 2 went stale, 1 came back, 1 FileVault
    off, 2 FileVault not reported".
    *   Zero and nil counts are left out.
    *   It reads "No changes" when every count is 0.
    *   The fact is absent when no part exists.
*   The caller at `ScheduledRunSignals.swift` around 145 passes the newest summary's
    `changes`.

#### 18. Tests (Create/Modify)

*   `app/Tests/JamfReportsTests/Engine/SnapshotFleetDriftTests.swift`:
    *   transitions under `on_values`;
    *   the hardware rule;
    *   never-inventoried;
    *   `ignore`;
    *   nil when unreported;
    *   golden rows of the existing sections and of the three new ones.
*   `app/Tests/JamfReportsTests/Engine/PatchFailureDriftTests.swift` and
    `app/Tests/JamfReportsTests/Engine/BenchmarkRuleDriftTests.swift` (Create).
*   `app/Tests/JamfReportsTests/FileVaultValueTests.swift` (Create): the chain, the Bool
    spelling, and the sheet's display mapping.
*   `app/Tests/JamfReportsTests/PatchScanFailureSectionsTests.swift`:
    `testComplianceOnlyStreamYieldsNoFailuresRatherThanComplianceRows` and
    `testPolicySectionWithoutDeviceSectionYieldsNoFailures` now expect nil and the new
    `[warn]`.
*   `app/Tests/JamfReportsTests/FleetChangeSummaryTests.swift` (Create):
    *   round-trip;
    *   a malformed part dropped alone;
    *   `validated()`;
    *   `filling(from:)` per part;
    *   `freshSummaryIsBetter`.
*   `app/Tests/JamfReportsTests/SameDaySummaryRebuildTests.swift`:
    *   a run without `computers` keeps the morning's part;
    *   a 2.12-shaped rewrite falls back.
*   `app/Tests/JamfReportsTests/WebhookNotifierTests.swift`: the `Changes` text, and its
    absence in `minimal` mode.
*   The Overview layout suite: `.changes` in second place, offered only on Jamf Pro.
*   `app/Tests/JamfReportsTests/ChangeFilterTests.swift` (Create): the filter counts the same
    set as the part, and shows the gone-file and rule-changed notes.

### Stage B3: the aging cache

#### 19. `Models/AgingCache.swift` (Create)

```text
AgingCache { schemaVersion: Int (1), sources: [SourceKey: SourceState],
             devices: [DeviceKey: DeviceRecord] }
SourceState { firstDay: Date?, log: [LogEntry], rebuilding: Bool, resumeFrom: String? }
LogEntry { stamp: String, complete: Bool, outcome: applied | skippedTooLarge }
DeviceRecord { aliases: Set<String>, presence: [Span], values: [Field: [ValueSpan]],
               quiet: [DateField: [QuietSpan]] }
Span { from: Date, to: Date? }                      ValueSpan { value: String?, from, to }
QuietSpan { jamfDate: Date? (nil = absent), floorDays: Int, firstAbove: Date, end: Date? }
PatchSpan { deviceKey, policyId, firstScan: Date, lastScan: Date, endScan: Date? }
```

*   Every field is `decodeIfPresent`.
*   `SourceKey` is `computers`, `patch`, `mobile` or `school`.

#### 20. `Engine/AgingCacheBuilder.swift` (Create)

*   `struct SourceObservation { source; stamp: String; at: Date; complete: Bool; rows:
    [ObservedDevice] }`, with `ObservedDevice { identifiers: [String]; values: [Field:
    String?]; dates: [DateField: Date?] }` (patch: `PatchObserved { jamfID; policyId }`).
*   `static func apply(_:to:floorDays:) -> AgingCache`, implementing the event table.
*   `complete` for an inventory source is computed here: the observation is compared with
    the cache's open presence set through the large-change rule (`largeChangePercent`
    generalised as `LargeChange.percent(joined:left:current:prior:)`), so no second file is
    read.
*   `static func pruned(_:closedBefore:) -> AgingCache`.
*   Reducers: `computers` through `ComputerSnapshot` and patch through `PatchFailureRow`.
    Mobile and School follow in B4.

#### 21. `Engine/AgingCacheStore.swift` (Create), `Services/CloudStorage.swift` (Modify)

*   Folder: `AppSupport.directory()/aging-cache/`. Paths `<WorkspaceID.pathComponent>.json`
    and `.lock`.
*   `load(workspace:) -> LoadResult { cache, needsRebuild }`, reading through
    `BoundedFile.read` with `snapshotLimit` and `followSymlinks: false`.
*   `write(_:workspace:)` through `AtomicInstall.write`, 0600.
*   `pending(dataDir:cache:) -> [SourceKey: Pending]`, where `Pending` holds `files`,
    `rebuildFrom`, `waitingOn` and `tooLarge`.
*   `CloudStorage.isDataless(_ url: URL) -> Bool`: `lstat` `st_flags & SF_DATALESS`, or the
    ubiquitous downloading status not `.current`.

#### 22. `Engine/AgingCacheFill.swift` (Create)

*   `static func fill(workspace: WorkspaceID, dataDir: URL, rules: GapRules, lock: LockMode,
    shouldStop: @Sendable () -> Bool, onLine: (CLIBridge.LogLine) -> Void) async ->
    FillResult`, with `enum LockMode { skipIfBusy, wait(until: Date) }`: views pass
    `skipIfBusy`, generate passes `wait`.
*   `struct FillResult { applied: Int; left: Int; rebuilding: [SourceKey]; waitingOn: Int;
    tooLarge: Int; finished: Bool; lockBusy: Bool }`. `FillState` (in `GapSummary`) carries
    the same fields from the cache's source states, so views show "filling: M left",
    "rebuilding", "waiting for a file to download" and "N too large to read".
*   `AgingCacheStore.LoadResult.needsRebuild` is a `Set<SourceKey>`.
*   Runs the loop in the Technical Plan and writes one `[info]` line.
*   Callers:
    *   **Views:** item 24.
    *   **After GUI collects:** `WorkspaceStore+Refresh.swift`'s `recordingCollect`
        completion starts a detached fill with a 10-minute `shouldStop`.
    *   **Generate:** item 26.

#### 23. `Engine/GapLedger.swift` (Create)

*   `struct GapRules { stale: StaleRule; fileVault: SecurityControlPolicy; mobileStaleDays:
    Int; schoolStaleDays: Int }`.
*   `struct GapLedger { init(cache:rules:now:periodDays: Int = 90) }`.
*   `func summary(_ type: GapType) -> GapSummary { openAges: [(DeviceKey, Int, atLeast:
    Bool)]; median: Int?; count: Int; atLeastCount: Int; exits: [Exit: Int]; historyStart:
    Date?; floorNote: Bool; state: FillState }`.
*   It calls `StaleRule.age` and `SecurityControlPolicy.verdict`, with nearest-rank medians.

#### 24. `Views/AuditView.swift`, `Views/GapAgingSection.swift` (Modify/Create)

*   A "Gap aging" card per type:
    *   age bands 0-13, 14-30, 31-90 and over 90 days;
    *   the median with its count;
    *   the history start, the rule and the fill state.
*   Built in `AuditView.loadCached`. On open it starts a fill (no lock wait) and reloads
    when it ends.
*   The decoded cache is kept per workspace by stamp, cleared on a profile switch, never
    read in demo mode.

#### 25. `Views/OverviewView.swift`, `Views/PatchView.swift`, `Intelligence/FleetInsight.swift` (Modify)

*   The oldest-gap line in the `.changes` section ("Oldest open gap: FileVault 41 days,
    stale 112 days"); stale from the newest snapshot.
*   The patch aging row on the recent-failures card.
*   `FleetInsightInput.fleet(current:previous:gaps: [GapType: GapSummary]? = nil)` adds the
    open-gap counts (`.count`, `lowerIsBetter`) and medians (`.number`, `lowerIsBetter`).
    Its caller in `OverviewView` passes them.

#### 26. Workbook and HTML: `Engine/CoreDashboard.swift`, `Engine/Templates/ReportTemplate.swift`, `Engine/Templates/FullInstanceTemplate.swift`, `Engine/Templates/OperationalTemplate.swift`, `Engine/Templates/SecurityPostureTemplate.swift`, `Models/Models.swift`, `Engine/HtmlReport+Inputs.swift`, `Engine/HtmlReport+Sections.swift`, `Engine/HtmlReport+Layout.swift`, `Engine/HtmlReport+Glance.swift`, `Engine/ReportEngine.swift` (Modify)

*   `ReportEngine.generate` and `generateHTML` await `AgingCacheFill.fill` with one
    10-minute deadline covering the lock wait and the fill together, before the sheets and
    sections that read it.
*   With no `ReportEngine.workspace` (tests, library use), there is no cache: the tab is
    skipped with `[skip] Gap Aging: no workspace`, and the HTML section is listed under
    "Not included".
*   `SheetID.gapAging`, the "Gap Aging" tab after Management Health, in the same templates
    as Management Health (Full Instance, Operational, Security Posture) and its
    `CustomSheetGroup` group.
    *   It holds a summary per type, then open gaps: Jamf ID, Serial, Type, Opened, Age,
        "at least".
    *   Its manifest description goes in `sheetManifestDescriptions`.
*   `SectionID.gapAging` in the Security and compliance group, loaded in `Inputs`, listed in
    the same templates' `htmlSections`.
*   `attentionItems` gets "N Macs have had FileVault off for more than 30 days", anchored to
    the section.

#### 27. `config.example.yaml` (repo root), `docs/wiki/10-Security-and-Operational-Considerations.md` (Modify)

*   The retention comment covers the aging cache:
    *   it is per Mac and outside the workspace, and is never swept;
    *   spans are dropped after `snapshot_keep_days` (0 keeps all);
    *   gap starts are lost on a rebuild after a sweep.

#### 28. Tests (Create)

*   `app/Tests/JamfReportsTests/Engine/AgingCacheBuilderTests.swift`:
    *   every row of the event table;
    *   the floor per span;
    *   absent spans, and none for `contact`;
    *   aliases across an ID-then-serial row;
    *   keys that never collide across sources;
    *   a large-change observation never closes presence.
*   `app/Tests/JamfReportsTests/Engine/GapLedgerTests.swift`:
    *   the stale count at a past observation equals `StaleRule` over that raw snapshot;
    *   FileVault likewise;
    *   medians need 5;
    *   "at least" kept out of the median;
    *   left wins;
    *   unknown keeps a gap open;
    *   `ignore` hides FileVault;
    *   0 keep days keeps all.
*   `app/Tests/JamfReportsTests/Engine/AgingCacheFillTests.swift`:
    *   resume after the stop;
    *   a late file rebuilds, resumably;
    *   a dataless file holds its source and is never opened;
    *   an oversized file is logged once and not seen as late;
    *   files older than the first day are ignored;
    *   another `schemaVersion` rebuilds;
    *   a busy lock: a view skips, generate waits.
*   `app/Tests/JamfReportsTests/GapAgingSheetTests.swift` (Create): the tab's columns, and
    the HTML section and attention sentence.

### Stage B4: mobile, Jamf School, weekly digest

#### 29. `Engine/DriftDevice.swift` (Create), `Engine/SnapshotFleetDrift.swift` (Modify)

*   `protocol DriftDevice { identifiers: (primary: String?, serial: String?); dates for its
    stale rule; osVersion: String? }`.
*   Conformers:
    *   `ComputerDates`;
    *   `MobileDriftDevice`, built from `MobileDeviceInventoryItem`;
    *   `SchoolDriftDevice`, from `SchoolFleetService.Device`, trash left out and counted.
*   `DriftDeviceIndex` generalises `ComputerDateIndex`'s rule.
*   `SnapshotFleetDrift` becomes generic over the device, with a stale closure per platform.

#### 30. `Engine/ReportEngine.swift`, `Engine/ReportEngine+SchoolSummary.swift` (Modify)

*   `changes.mobile` in the finalize summary step when `mobile-devices-list` landed.
*   `changes.school` in `writeSchoolSummary` when `school-devices` landed.

#### 31. `Engine/AgingCacheBuilder.swift`, `Engine/GapLedger.swift` (Modify)

*   Mobile and School reducers, and their stale rules.

#### 32. `Views/MobileFleetView.swift`, `Views/SchoolOverviewView.swift`, `Engine/SchoolDashboard.swift` (Modify)

*   A change card and a stale-aging card, with "<platform> does not report this" lines.
*   The School "Gap Aging" tab, appended last, with its fill awaited in `schoolGenerate`.

#### 33. Config key: `Engine/ConfigDecoder.swift`, `Services/NotifyConfigStore.swift`, `Views/NotificationsCard.swift`, `Services/SharedConfigPin.swift`, `Services/ConfigDoctorService+Values.swift`, `config.example.yaml` (Modify)

*   `NotifyConfig.weeklyDigest`, from `notify.weekly_digest`, decoded like `heartbeat` (a
    non-boolean reads as off; `fileReadBooleanRows`).
*   The writer, a switch, the pin and an example entry.

#### 34. `Services/ScheduledRunSignals.swift`, `App/Tick.swift` (Modify)

*   `notifyWeeklyDigests(profiles:now:)`, modelled on `notifyHeartbeats`.
*   It sends through the workspace `DayMarker(name: "weekly-digest").sendOnce(day:
    weekKey, …)`, with `weekKey` from `Calendar(identifier: .iso8601)` formatted
    `YYYY-'W'ww`.
*   Called from the tick's post-run hook.

#### 35. Tests (Create/Modify)

*   `app/Tests/JamfReportsTests/Engine/DriftDeviceTests.swift`: the mobile and School joins,
    trash, and their stale rules.
*   `app/Tests/JamfReportsTests/Engine/GapLedgerTests.swift`: mobile and School cases.
*   `app/Tests/JamfReportsTests/WeeklyDigestTests.swift`:
    *   the week key across 2026-12-28 to 2027-01-03;
    *   one card for two Macs;
    *   under 7 days;
    *   `minimal`;
    *   ranking across units;
    *   top 5.
*   `app/Tests/JamfReportsTests/NotifyConfigTests.swift`: the key, the pin and the Doctor
    row.

### Every stage

#### 36. Demo data: `Models/DemoData+Summaries.swift`, `Models/DemoData+Operations.swift`, `app/Tests/JamfReportsTests/DemoData*Tests.swift` (Modify)

*   Demo `changes` in the demo summaries, plus demo version history and gap aging. All are
    derived from the shared 524-Mac facts and asserted against them.

#### 37. `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` (repo root) (Modify)

*   One Added bullet per stage.
*   Changed bullets for:
    *   each new tab;
    *   the Fleet Drift sections;
    *   the security sheet's FileVault cell;
    *   the patch-failure fallback.
*   A short section per stage in CLAUDE.md, mirrored to AGENTS.md.

#### 38. `docs/wiki/06b-Patch-Velocity.md`, `docs/wiki/03-App-Dashboards.md`, `docs/wiki/05-Scheduling-and-Automation.md`, `docs/wiki/08-Jamf-School.md` (Modify)

*   Version history, the change and aging cards, the weekly digest, and what Jamf School
    gets and why.

### Verification Plan

*   **Build:** `cd app && swift build --build-tests`, also in the `ci-macos15-xcode16.4` VM
    for the Swift 6.1 floor.
*   **Unit tests:** each suite above with `swift test --filter`, then the full suite on the
    stage's branch tip (`/tip-test`, the repo's skill that builds and tests a ref in a clean
    worktree).
*   **Large fleet:** extend the maintainer's large-fleet generator (outside the repo) to move
    check-in and inventory dates and FileVault values between days, and to write a year of
    snapshots. Record in the stage PR:
    *   B2's collect peak memory (target: under 1 GB more than today);
    *   the fill's time per snapshot;
    *   a full rebuild's time;
    *   the cache's size (revisit A8 and A9 above 50 MB).

    The other numbers are informational.
*   **Stress (approved 2026-11-24):** generate 50,000 and 100,000-Mac workspaces. Snapshots
    are then about 480 MB and 960 MB, over the 256 MB read limit. Check that:
    *   the collect keeps working;
    *   B2's current side comes from memory and its baseline reads "could not be read";
    *   the fill names the oversized files;
    *   nothing runs out of memory.

    Also run the builder, `GapLedger` and `PatchVelocityBuilder` on synthetic caches and
    patch histories at those sizes, and record time and peak memory. A9 is decided on these
    numbers.
*   **Real data:** the NFR workspace. Enable `PatchFailureDrift.isEnabled` and the patch
    aging only with the captured failing-patch fixture in the tests.
*   **Visual:** the Overview section, the Health Audit cards and the Patch cards at
    `PageScaffold.minSupportedWidth` in demo mode. Commits are marked `DRAFT — needs visual
    verification` for the maintainer's pass.

--------------------------------------------------------------------------------

*Drafted with EGM*
