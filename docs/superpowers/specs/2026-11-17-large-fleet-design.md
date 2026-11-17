# Large fleets — design

Status: approved by the owner on 2026-11-17, with the decisions recorded at the end. All of it
is for 2.12. Part L1 is built on the branch that carries this file. Written after a 2.12.0-rc1 report from a fleet of
about 5,900 Macs, where every manual refresh was refused because a scheduled run held the lock
for most of the day.

The aim: a 1,000-device, a 6,000-device and a 12,000-device environment each get a day's data,
a usable app while it is collected, and reports that open. The larger ones will also connect
Jamf Protect, the Platform API and Jamf Security Cloud.

## What is true today

Checked on `dev/2-12-0` at the 2.12.0-rc2 commit.

- One collect runs at a time, under the tick lock. A manual refresh is refused while a scheduled
  run holds it.
- The due check (`scheduleSkip`, `planSchoolCollect`) reads a source's last success. A source
  that has never landed is due in every unforced collect of its tier. The timeout backoff added
  in rc2 lives in the same-day retry and in self-repair, not in the planner.
- `jamf_cli.collect_skip` could not list `patch-status`.
- The summary is written once, after every source of the run and the device scan.
- The per-device scan (`ddm-device-status`, `mdm-command-health`) walks every Mac in one pass,
  4 calls at a time, weekly, and writes one snapshot per kind that holds the whole fleet. More
  than 25% of devices failing writes nothing. The School weekly scan has the same shape.
- Jamf Protect sources have no cadence: every run that reaches Protect collects all of them.
- A report is built in memory and written once.

### The reported failure

The run log (redacted by the reporter) shows `patch-status` only. jamf-cli asked for the patch
title configurations, shrank the page from 2,000 to 100 as each timed out, and gave up with
exit 1, "the server did not answer in time". rc1 then tried it again inside the run: 24 minutes
per run, repeated by the same-day retries and hourly self-repair. The request has no device in
it, and jamf-cli owns the paging, so nothing the app does per device can reach it.

### Measured (synthetic fleets, release build, Apple silicon, 32 GB)

Row shapes cloned from a small test tenant, 68 extension attribute rows per Mac, which is about
eight times the density of the one production export on hand.

| Macs | Workbook | Workbook peak memory | HTML report | HTML peak memory | Two days of snapshots |
|---|---|---|---|---|---|
| 1,000 | 8 s | 0.6 GB | 1.4 s | 0.2 GB | 69 MB |
| 6,000 | 41 s | 3.0 GB | 6.7 s | 0.7 GB | 482 MB |
| 12,000 | 82 s | 6.3 GB | 13 s | 1.5 GB | 772 MB |

The 12,000 workbook was measured alone (peak memory footprint); the other rows ran while builds
were going on and report resident memory, so they may read low. Memory grows with the fleet:
about 0.5 GB per 1,000 Macs at this density. On an 8 or 16 GB Mac the 12,000 workbook pages.

### Measured at production extension attribute density

The table above used 68 results per Mac. One production server returns 93 per Mac (152
defined), about 20 KB per Mac, with a few very long values (the longest about 147,000
characters). Fleets below copy that shape from a numbers-only profile, at that density and at
twice it, with 12 sites. The same build as above; other work was running on the Mac, so
memory may read low.

| Macs | Results per Mac | `ea-results` file | Workbook | Workbook peak memory | HTML peak memory | Tabs lost |
|---|---|---|---|---|---|---|
| 6,000 | 93 | 100 MB | 43 s | 3.1 GB | 0.9 GB | none |
| 6,000 | 186 | 201 MB | 67 s | 4.6 GB | 1.7 GB | none |
| 12,000 | 93 | 199 MB | 85 s | 6.3 GB | 1.8 GB | none |
| 12,000 | 186 | 402 MB | 35 s | 5.3 GB | 0.8 GB | EA Coverage |
| 20,000 | 93 | 333 MB | 55 s | 6.8 GB | 1.1 GB | EA Coverage, DDM Device Status |
| 20,000 | 186 | 671 MB | 57 s | 6.8 GB | 1.1 GB | EA Coverage, DDM Device Status |

What the last three rows show:

- Over the 256 MB limit the report still finishes, faster, because it has dropped the
  extension attribute tabs. The only sign is a `[skip]` line that says "No cached jamf-cli
  snapshot found for: ea-results", which is untrue: the snapshot is there and was refused for
  size. An unreadable snapshot is being reported as an absent one.
- `ddm-device-status` is not on the list of inventory kinds, so its limit is 64 MB, which the
  20,000-Mac fleet passes. Its tab is lost the same way. `mdm-command-health` has the same
  64 MB limit.
- Memory is 6 to 7 GB at 12,000 and 20,000 Macs even with the extension attribute rows
  refused, so the rest of the inventory is a large share of it.

Not measured: any screen in the app, the collect itself (no tenant of this size is available),
the device scan's time per device, and any Protect, Platform API or Security Cloud call at size.

## How each call scales

| Class | Sources | Grows with | Who pages | Answer |
|---|---|---|---|---|
| Fixed | overview, security summary, SOFA, sites, categories | nothing | — | run first |
| Fleet list | computers, mobile devices, EA results, Protect computers, Security Cloud risk list, School devices | devices | jamf-cli | L5 (memory, disk) |
| Server report | patch-status, policy-status, profile-status, app-status, update-status, benchmark reports | server work per title, policy or rule | jamf-cli or the server | L1, L2 |
| Failure scans | patch-device-failures, update-device-failures | devices, inside one jamf-cli call | jamf-cli | L1; already skippable |
| Per device | the device scan, the School scan | devices × calls, 4 at a time | the app | L3 |

Rings ("1,000 at a time, spread over the day and week") fit the last row only: it is the one
place where the app, not jamf-cli or the server, walks the fleet.

## L1 — The planner holds a source that keeps timing out (built)

- `StateFileStore.timeoutHoldUntil(report:)`: 20 hours after the last failure, once two
  failures in a row timed out (the app's limit, or jamf-cli's "the server did not answer in
  time"). 20 hours, not 24: a failure is stamped with its run's start, and a daily schedule that
  starts a few seconds earlier the next day must find the hold over.
- `planCollect` and `planSchoolCollect` skip the source until then with
  `CollectSkipReason.repeatedTimeouts`, unless the run is forced. The `[plan]` block lists it
  under "timed out repeatedly, left to the next day's run", and its `[skip]` line gives the time of the next
  automatic try.
- A skipped source records nothing, so the run is not Partial and the summary is written. The
  earlier failure stays on disk, so the health banner still names the source.
- Collect now forces, so a person who fixed the server is not kept waiting.
- `jamf_cli.collect_skip` accepts `patch-status`, and skips `patch-release-dates` with it.
  Patch screens and the patch score factor then have no data (the factor's weight drops out; it
  is never 0).
- `patch-release-dates` walks the `patch-status` snapshot and records nothing without one. It
  read as "not collected yet", which kept the refresh tier in hourly self-repair on the
  reported fleet. The freshness check now leaves it out until `patch-status` has landed.
- Jamf School: the same hold, through `planSchoolCollect`.

- `patch-status` and `patch-device-failures` share one streak and one hold
  (`sharedRequestKinds`): a later log from the same fleet, on rc2, showed the failures scan
  waiting 721 seconds on the same patch-title request the title report had already given up on.

Effect on the reported fleet: `patch-status` costs about 12 minutes on each of two runs, then
once a day, instead of 24 minutes several times a day; or nothing, when it is listed in
`collect_skip`.

Sibling sites found by `rg "CadenceResolver.isDue"`: the Jamf Pro and School device scans
already floor on the last attempt. Jamf Protect and Security Cloud have no due check at all;
that is L4, because it needs a cadence first.

## L2 — Short runs first, the summary early, a time budget per run

All five items are built (item 3, the early summary, for Jamf Pro only: a School run has no
slow tail to wait behind, and its summary is written straight after its few sources). The early
summary is written only when nothing attempted so far has failed. Items 1, 2, 4 and 5 cover Jamf
Pro and Jamf School. Benchmark reports and the dashboard
do not record a duration yet, so they keep their place. As built: the budget stops the run
before any further source, slow or not (the slow ones are last anyway); the app waits up to 30
minutes for the source in progress and does not yet name it in the status line; the pickup is
the background item's same-day retry (an hour later, then two, then four). The app's own
automatic collects (background refresh, self-repair, catch-up) stop the same way; the budget is
per workspace.

1. **Record how long each source took.** The run log already prints `<kind> took Ns`; keep the
   last value in the state folder (`<kind>.took`, outside the manifest).
2. **Order the run by it.** Sources with no record or a short one run first, in today's order;
   sources whose last duration was over a threshold (proposed: 2 minutes) run last, shortest
   first.
3. **Write the summary when its inputs have landed**, before the slow sources and the device
   scan. A later slow source that changes a summary figure rebuilds it, as a same-day collect
   already does (`freshSummaryIsBetter`).
4. **A budget per scheduled run**: 45 minutes of lock hold by default,
   `jamf_cli.run_budget_minutes` (clamped 10 to 240) for a slower server or Mac. When it is used up the
   run starts no further slow source or scan pass; what is left stays due and the next wake
   takes it. The log says `[info] run budget used; N sources left for the next run`. This is
   not Partial: nothing failed.
5. **A manual refresh interrupts a scheduled run between sources.** It waits for the source in
   progress, with the status line naming it ("Waiting for the scheduled run: collecting
   ea-results"), then the scheduled run stops, gives up the lock and logs
   `[info] stopped for a manual refresh; N sources left for the next run` (not Partial). Run
   History shows that notice on the scheduled run, and the app shows a notice that the
   scheduled run was interrupted and will pick up what is left. This is also a troubleshooting
   tool: a person can get the lock back without quitting anything. The run-now marker folder is the existing
   per-Mac place for such a request.

1,000 devices: no source crosses the threshold; nothing changes. 6,000 and 12,000: Trends
advance in the first minutes of the day's run, and no run holds the lock longer than the budget
plus one source.

## L3 — The per-device scan in passes (built, Jamf Pro and Jamf School)

The snapshot stays whole; the scan stops being all-or-nothing.

As built, differing from the list below: there is no envelope, since an older build sharing the
folder must still decode the file; the snapshot stays a bare array and each row carries
`scannedAt` (a row without it takes its file's stamp). The round's state
(`state/device-scan.round`) holds the round's start, the last pass, the ids a pass of this round
attempted, how many are left, and attempts and failures per call type. A peer can write it, so it
is read as untrusted: a date more than the clock-skew tolerance ahead, or a start older than the
row-age limit, reads as no round, and the attempts are intersected with the current targets. A
Mac is done for the round once attempted, answered or not, so a Mac that never answers cannot
hold the round open; it keeps its earlier row while that is within 21 days. A pass orders one
site's Macs before the next (`general.site.id`, numeric order, no site last), then oldest first.
An open round takes one pass a local day on any unforced run, whatever its tiers. The 25% rule is
judged over the round at its end; a stop (exit 3, 5, 6, 8, three timeouts) still ends the round
and records the failure. A pass that attempts no Mac writes and records nothing; an earlier
snapshot that cannot be read skips the pass. While a round is open and its last pass is within 2
days, data freshness does not report the two kinds. Instead of "scanned N of M in the last 7
days", the DDM screen and the Audit's command-health card show "Scan in progress: N of M Macs
scanned this round" only while a round is open; the workbook tabs carry a Scanned column and the
HTML report is unchanged. A forced scan (Collect now) scans the whole fleet; a forced run without
the scan tier (the app's background refresh) takes no pass. The `[ok]` and device-gap `[partial]`
lines print only when a round ends. Demo mode shows no line. `config.example.yaml` documents
`jamf_cli.scan_budget_minutes`. Jamf School is covered too (`school-device-detail`), with
the same `scannedAt`, round file, merge and round-level 25% rule. Where it differs: School has
no forced scan (every GUI collect passes `force`), so every pass is budgeted and an unreadable
earlier snapshot is replaced only by a scan of every device; the plan also reads the attempt
stamp, which a peer's pass writes when it starts; the budget replaces the one-hour deadline;
and the order is oldest first without locations, since the captured `school-devices` rows carry
none. The card reads "Scan in progress: N of M devices scanned this round", and the Device
Inventory tab gains a Scanned column last.

- Each row gains `scannedAt`. A pass picks the Macs with the oldest `scannedAt` first (never
  scanned first), scans as many as fit its time budget (30 minutes by default,
  `jamf_cli.scan_budget_minutes`, clamped 5 to 240), then writes one
  snapshot: the rows it scanned, plus the newest earlier row of every other Mac still in the
  `computers` snapshot. Readers keep reading the newest file as the fleet.
- A row older than a limit (proposed: 21 days) is dropped at merge, so a Mac that stopped
  answering reads as not scanned, never as its old state.
- The snapshot's envelope records `scanned: {met, of, since}`; the DDM screen, the Audit's
  command-health findings, the workbook tabs and the HTML section print "scanned 4,120 of
  12,000 Macs in the last 7 days". A finding count is a count of the Macs scanned, and says so.
- Cadence: a pass is due daily while any Mac's row is older than the scan cadence (7 days), so
  1,000 Macs finish in the first pass and the fleet's next pass is a week later, as today; a
  12,000-Mac fleet takes a pass a day until the week's round is done.
- Oldest-first under a time budget replaces fixed rings: it needs no ring size, adapts to the
  server's speed, and a Mac added mid-week is simply first in line.
- The 25% failure rule and the three-timeouts stop apply to a pass. A stopped pass writes what
  it scanned.
- Jamf School: the weekly scan (`school-device-detail`) takes the same passes and the same
  `scannedAt`.

Not covered by passes: `patch-device-failures` and `update-device-failures`, where jamf-cli
does the walking inside one call. They stay skippable and fall under L1.

## L4 — Protect, Security Cloud and the Platform API under the same planner

Built, except duration ordering for benchmark reports. A Protect-only environment keeps
collecting every source: a cadence skip there would land nothing and read as a dead run.

- Give `protectCommandMatrix` and `security-risk` a cadence (the refresh tier's 12 hours, held
  only within a local day, since the daily summary takes their figures from the run that landed
  them) and
  the L1 hold, through one planner call each, so a run that only came for a retried Jamf Pro
  source does not collect all of Protect again.
- Benchmark reports run per title already; record and order them by duration like any source
  (L2).
- The run budget (L2) covers the whole environment's run, not each product.

## L5 — Reading and writing at size

1. **Workbook memory.** Find the largest holders first (Instruments, the 6,000 fleet): the
   decoded `ea-results` rows, the EA Coverage tab's cells and the in-memory archive are the
   candidates. Target: under 1.5 GB at 12,000 Macs at this EA density. No design until
   measured.
2. **Screens.** Time Computers, Extension Attributes, Overview and Trends on the 6,000 and
   12,000 fleets with the existing signposts. Target on the reference Mac: first paint under
   2 s, no main-thread block over 250 ms. The app runs on macOS Sequoia 15 and on older Apple
   silicon, so a target is met only with half of it to spare.
3. **Disk** (built: Config Doctor's `retention.data_folder_size`). Two days of snapshots are 772 MB at 12,000 Macs and retention is off by default,
   which is a few hundred GB a year at daily inventory. Proposed: Config Doctor suggests
   retention when the data folder passes 20 GB; no default changes.

4. **Large snapshots** (agreed by the owner on 2026-11-17). Built: a snapshot refused for
   size is reported as refused, by name and size, in the report's log, on the skipped tab's
   line, in "Not included" and as a Needs attention item, never as "no snapshot"; and the
   per-device scan kinds (`ddm-device-status`, `mdm-command-health`, `school-device-detail`)
   are inventory kinds. Checked on the 12,000-Mac fleet at twice production density. The owner
   accepts losing those tabs at that size, as long as it is said. Not built: the rest of this
   item. Not covered yet: the app's own screens that read the same snapshot. An inventory snapshot
   over 256 MB (`BoundedFile.inventoryLimit`) is refused as unreadable. One production server
   holds about 20 KB of extension attribute results per Mac (93 results each, a few very long
   values), so `ea-results` reaches the limit near 12,800 Macs, and near 6,400 at twice that
   density. The limit exists because a workspace can be a shared folder and a planted file must
   not exhaust this Mac's memory, so it is not switched off:
   - A workspace on local storage holds only what this Mac's jamf-cli wrote. Its limit rises
     with no setting (proposed: 2 GB).
   - On shared storage (`CloudStorage.isSharedStorage`, or a workspace this Mac holds a pin
     for) the limit stays, and a refused snapshot gets a Config Doctor row naming the source and
     its size with a Confirm, "Allow large snapshots on this Mac". The answer is kept per Mac
     (Application Support, beside the shared-config pin), never in config.yaml, which every Mac
     sharing the folder can write. A configuration profile can set it for deployed Macs.
   - Every refusal for size raises a Needs attention item naming the source and the fix. A
     report never just loses a tab.
   - Check the collect side too: whether jamf-cli's output is bounded while it is captured,
     before it is saved.
   - Jamf School and mobile inventory use the same limit and the same rule.
   Follow-ups this does not replace: reading `ea-results` as a stream (a higher limit
   otherwise trades "refused" for a multi-GB decode); an optional cap on stored value length,
   off by default because it discards data; and, for 2.13 or later (owner, 2026-11-17),
   collecting only the extension attributes the workspace names (the mSCP ones, the security
   agents, the configured `custom_eas`), so compliance scoring and agent coverage keep working
   on a fleet whose full results are too large. That needs a jamf-cli call that returns chosen
   attributes only, which has not been checked.

## L6 — Sites

Status: agreed for 2.13 by the owner on 2026-11-17, not built. A reporting feature, so it gets
its own plan and its own pull request; only the scan order below rides with L3 in 2.12.

An organization can have 20,000 devices with 5,000 of them in one Jamf Pro site. Sites are how
such an organization reads its fleet, so the app should let it read by site.

### What is true today

- The `computers` snapshot carries each Mac's site as `general.site` (`id` and `name`, both
  text; a Mac in no site has id `-1`). Mobile devices carry `general.siteId`. The `sites`
  snapshot lists the sites (`id`, `name`). Nothing reads any of them.
- Seen on a test tenant (4 Macs, 2 sites) and on one production export (no sites defined, every
  Mac at `-1`). Not seen: a production server that uses sites.
- The computer list cannot be filtered by site: jamf-cli's `--filter` for `pro computers list`
  accepts about 60 fields and site is not among them. Lists are paged by jamf-cli already, and
  the source that fails on the reported fleet has no device or site in it. So collecting one
  site at a time is neither possible for the main inventory nor a fix for anything measured.
- A login limited to some sites is detected since 2.12 (`SiteScope`): its reports say they cover
  only what it sees. That stays as it is. What a login sees is decided by its API client and
  role; the per-site view groups whatever that login returned, with no further check.

### Three setups

| Setup | Detected by | What the app does |
|---|---|---|
| Site-limited login | `SiteScope` (2.12) | Unchanged: the workspace is that login's view |
| Whole-server login, sites in use | at least one site in `sites` and at least one device not at `-1` | Site filter, per-site reports and figures |
| Whole-server login, no sites | no sites, or every device at `-1` | Nothing site-related is shown |

Sites are detected, never typed in. A setting exists only for choices (below).

### Parts

1. **Model.** One reader of a device's site (computers and mobile devices) and one test for
   "sites in use". A device in no site is "No site", a group of its own, never dropped.
2. **Screens.** A site filter on Computers and Mobile Devices, and the site in the detail panel.
   Hidden when sites are not in use.
3. **Reports.** "This site only" when generating: the workbook, HTML and CSV folder hold that
   site's devices, with the site named on the cover and in the file name. Server-wide tabs that
   have no device rows (policies, patch titles, groups) are kept and marked as covering the
   whole server, in the tab's note row, so no tab or column moves between the two reports.
4. **Daily summary.** Per-site device count, stale count and the main security shares as
   `{met, of}` pairs keyed by site id, with the site's name beside it, so Trends and alert rules
   can follow one site. A figure a site does not report is absent, never zero. A site that is
   renamed keeps its history through the id.
5. **Scan order (with L3).** A scan pass takes the Macs of one site before the next, oldest
   first within it, so coverage reads by site. No change for a server without sites.
6. **Setting.** `sites.skip` (ids or names to leave out of per-site figures) only if someone
   asks for it; not in the first build.
7. **Jamf School.** School has locations, which the School device rows already carry
   (`locationId`). The same filter and "this location only" report apply; the summary figures
   are the School ones (managed, stale, OS current).

### Decisions

Taken (owner, 2026-11-17): sites go in 2.13; a one-site report keeps the server-wide tabs and
marks them.

Still needed before a plan:

1. Which per-site figures go in the summary first (proposed: devices, stale, FileVault, OS
   current), since every one is a new Trends series and alert key.
2. Whether the fleet workbook for report groups gets a per-site sheet.

### How it is tested

The generator builds a fleet with sites (`--sites`, `--largest-site`, `--unassigned`): 20,000
Macs in 12 sites with 5,000 in the largest and about 3% in none. Its workbook builds today in
69 s at 5.4 GB peak, 8 extension attribute rows per Mac. A one-site report for the largest site
should be about a quarter of that.

## How it is judged

`loop-eval` style, on the generator (kept outside the repository; it clones row shapes from a
small real workspace and holds no tenant data):

| Check | 1,000 | 6,000 | 12,000 |
|---|---|---|---|
| Workbook time | 10 s | 45 s | 90 s |
| Workbook peak memory | 0.7 GB | 1.5 GB | 1.5 GB |
| Longest lock hold of a scheduled run, slow-answer stub | budget + one source | same | same |
| Summary written after the run starts | 5 min | 5 min | 10 min |

These are figures for the reference Mac (Apple silicon, 32 GB, macOS Golden Gate 27). A slower
Mac or an older macOS gets the same order of work, not the same seconds, which is why both
budgets are settings.

A jamf-cli stub that answers each source after a set delay (and one that never answers) stands
in for the server, since no test tenant is this large.

## Upstream

jamf-cli stops shrinking a page at 100. A lower floor, or a per-title fetch for patch title
configurations, would let a slow server answer. A draft issue goes to the owner; nothing is
posted without a go-ahead.

## Order

1. L1 (this branch).
2. L2 items 1 to 3 (durations, order, early summary).
3. L4 (cadence and hold for Protect and Security Cloud).
4. L3 (scan passes): a data-shape change in two snapshots, their readers and two workbook tabs,
   so it gets its own plan and an announced workbook change.
5. L2 items 4 and 5 (budget, waiting refresh).
6. L5, each item after its measurement.
7. L6 (sites) on its own branch, after its decisions; its scan order lands with L3.

Micro-refresh (#421) stays out: it adds collects under the same lock.

## Decisions (owner, 2026-11-17)

1. The spec is approved and all of it goes into 2.12.
2. Time budgets get room for slower servers and Macs and for macOS versions before the newest:
   the defaults above are raised (45 and 30 minutes) and both are settings.
3. A manual refresh may interrupt a scheduled run between sources, with a notice (L2 item 5).
4. Scan passes, oldest first under a time budget, instead of fixed rings.
5. The workbook and layout changes L3 makes are approved; each is announced in the CHANGELOG.
6. Left at the proposed values, to be confirmed when built: the L1 hold (20 hours), the slow
   threshold (2 minutes), the scan row age limit (21 days), the wording "scanned N of M", and
   the disk suggestion at 20 GB.
