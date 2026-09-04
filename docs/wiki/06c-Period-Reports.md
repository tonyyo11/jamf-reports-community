# Period Reports

Trends is for looking at the shape of the fleet on screen. A **period report** is for
quoting: a workbook with a start figure, an end figure, and the change between them for
each metric you pick — the numbers a quarterly or annual write-up needs, without a manual
Jamf export.

It does not write the narrative. It produces the figures that go into one.

## Generating one

Open the **Generated** screen and click **Period report**. The sheet asks two things: the
window, and what goes in it. The button is disabled in demo mode.

The workbook lands in `Generated Reports/` alongside every other report. The filename
carries the period's resolved dates, so successive reports identify themselves rather than
being told apart only by timestamp:

```text
period-report-20260401-20260630-<profile>-<timestamp>.xlsx
```

## Choosing the window

Two kinds of window, because they answer different questions:

- **Rolling** — 4, 12, 26 or 52 weeks back from today. Good for "how are we trending
  now".
- **Calendar** — **Last full month**, **Last full quarter**, or **Custom dates**. This is
  what periodic reporting usually needs. A rolling twelve weeks generated on 15 July
  starts on 22 April and silently misses three weeks of an April–June quarter.

"Last full quarter" is the last complete **calendar** quarter — Jan–Mar, Apr–Jun, Jul–Sep,
Oct–Dec. That is safe whatever your fiscal year: a fiscal year changes which *number* a
quarter carries, not where its boundaries fall, and the report never prints the number. If
your organisation reports on genuinely offset boundaries, use **Custom dates**.

If no snapshot falls inside the window at all, no report is produced — there is nothing
honest to put in it.

## Every figure carries the date it came from

A period boundary rarely lands on a day that collected: the Mac was off, a collect failed,
or collection started mid-period. So the Summary sheet has **Start as of** and **End as
of** columns carrying the real snapshot date, not the date you asked for.

A boundary that resolved more than **three days** from the one you requested is marked in
the About sheet. Three days absorbs an ordinary weekend or one missed collect without
comment. Nothing is excluded and no arithmetic changes — the mark exists so you can decide
whether the drift matters before quoting that row.

**Change on a percentage is in percentage points**, rendered `+2.0pp`. FileVault moving
96% to 98% is `+2.0pp`, not `+2.1%`. Counts show a signed integer. A metric that was not
measured at a boundary reports no value rather than zero — "none" and "not measured" are
different answers.

## What can go in it

The picker offers what your workspace actually holds, so no two profiles necessarily
offer the same list.

**Fleet metrics** come from the daily summaries: managed devices, FileVault encrypted,
compliance rate, on current macOS, patch compliance, SIP, firewall, Gatekeeper, Secure
Boot, bootstrap token escrowed, XProtect, CVE posture, compliance benchmark score,
security score, EDR agent connected, and stale devices. A metric with no data anywhere in
the period is not offered — the app does not invite you to report on numbers it does not
have.

**Extension attributes** are discovered from your collected `ea-results`, so an
organisation with none sees fleet metrics and nothing looks broken, and an organisation
with eighty-eight sees eighty-eight. How each one is reported depends on whether you have
already configured it:

- **Configured** — an EA with a `true_value` under `custom_eas`, or a
  `connected_value` under `security_agents` — is reported as a count and percentage
  against that value, the shape that goes straight into a report table.
- **Not configured** — reported as a value distribution: one row per distinct value with
  its device count, at each boundary.

Configuring an EA upgrades it to a headline figure; nothing requires you to.

Distributions are capped at the 25 most common values, and the sheet says how many values
it left out rather than quietly showing a shortened table as the whole picture.

## Extension attributes are opt-in

Fleet metrics are selected by default. Extension attributes never are: their values come
from your own scripts and can be usernames, serials or certificate subjects, and this
workbook is meant to be forwarded.

Two things help you decide:

- The picker flags an attribute whose values are **nearly one per device** — the shape of
  a serial or hostname rather than a status — with a warning that including it puts
  per-device data in the workbook. The reading is taken at both ends of the period, since
  an attribute can be identifier-shaped at one boundary and not the other, and a very
  small fleet is never flagged on coincidence alone.
- When your reports are written to a synced folder, the picker names it, so "this will be
  readable by everyone in that folder" is visible at the moment you choose.

Your selection is remembered per profile. A metric that later disappears from the
workspace is dropped from the saved selection silently rather than shown as an error.

## The workbook

| Sheet | What it holds |
|---|---|
| Summary | `Metric, Start, End, Change, Start as of, End as of` — deliberately free of caveats so a rectangular selection copies straight into a document |
| Daily detail | One row per day, one column per selected metric, for charting or spot-checking the shape between the two endpoints |
| Value distributions | One block per selected unconfigured extension attribute — distinct values and device counts at each boundary. Present only when such an attribute is selected |
| About | The resolved period, profile, generation time, app version, and the coverage notes: which boundaries drifted, and which distributions were truncated |

The caveats live in About precisely so Summary stays paste-ready.

## Limits worth knowing

- **History starts when collection did.** An early period simply shows its real, shorter
  window with its real dates. Nothing is extrapolated.
- **No charts.** The daily series is in the workbook, and
  [Trends](https://github.com/tonyyo11/jamf-reports-community/wiki/06-Historical-Trends)
  charts on screen.
- **Device counts are point-in-time**, so a change in managed devices is enrollments minus
  unenrollments — a quarter with forty new and thirty-five retired Macs reads as "+5".
- **No command-line equivalent yet.** Period reports are generated from the app.

## See also

- [Historical Trends](https://github.com/tonyyo11/jamf-reports-community/wiki/06-Historical-Trends) — the snapshots this reads, and the on-screen charts.
- [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates) — configuring an extension attribute so it reports a figure rather than a distribution.
- [Data Provenance](https://github.com/tonyyo11/jamf-reports-community/wiki/11-Data-Provenance) — where each fleet metric comes from.
