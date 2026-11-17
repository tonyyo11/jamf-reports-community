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

Effect on the reported fleet: `patch-status` costs about 12 minutes on each of two runs, then
once a day, instead of 24 minutes several times a day; or nothing, when it is listed in
`collect_skip`.

Sibling sites found by `rg "CadenceResolver.isDue"`: the Jamf Pro and School device scans
already floor on the last attempt. Jamf Protect and Security Cloud have no due check at all;
that is L4, because it needs a cadence first.

## L2 — Short runs first, the summary early, a time budget per run

Items 1, 2, 4 and 5 are built (Jamf Pro and Jamf School). Benchmark reports and the dashboard
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

## L3 — The per-device scan in passes (built, Jamf Pro)

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
`jamf_cli.scan_budget_minutes`. Jamf School is not converted: its scan stamps the attempt when it
starts, treats its one-hour deadline as a failure that writes nothing, and takes 25% of the whole
fleet rather than of the attempts, so passes there need their own change.

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
3. **Disk.** Two days of snapshots are 772 MB at 12,000 Macs and retention is off by default,
   which is a few hundred GB a year at daily inventory. Proposed: Config Doctor suggests
   retention when the data folder passes 20 GB; no default changes.

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
