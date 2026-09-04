# Period Report — design

_Status: design, not implemented. 2026-08-27._

## Problem

Quarterly and periodic reporting is a hand-assembly job. An operator writing a
narrative report needs a small set of fleet numbers — how many Macs, what share
encrypted, what share on the current OS, what compliance looked like — for a
**period**, with a before and an after. Today the app answers "what is true now";
it has no way to answer "what changed between these two dates".

The numbers exist. `snapshots/summaries/summary_<date>.json` has been written
daily for as long as the workspace has collected, and dated `ea-results`
snapshots are retained by default from 2.7.0. Nothing reads them as a period.

The report this feeds is a **narrative document written by a person**. This
feature does not write that document. It produces the figures that go into it.

## Non-goals

- **Not a narrative generator.** No prose, no "insights", no interpretation.
- **Not a replacement for Trends.** Trends is for looking; this is for quoting.
- **Not a fiscal calendar.** The report never names a quarter — see Decisions.
- **Not activity tracking.** Policies created, change requests, packages staged
  and similar effort metrics are hand-tracked by the operator. They are not fleet
  state and the app has no claim on them.

## Decisions

These were settled before design and constrain everything below.

### D1 — Extension attributes are discovered, never required

The repo's standing rule is that the code contains no org-specific values, and
EAs are the most org-specific data in Jamf: an attribute one organisation
depends on is one another has never defined.

So the metric catalogue is **built per profile from what that workspace actually
contains**. An org with no EAs sees the built-in fleet metrics and nothing looks
broken or missing. An org with eighty-eight sees eighty-eight offered. No EA name
appears anywhere in the source.

### D2 — A configured EA gives a figure; an unconfigured one gives a distribution

An EA value is an arbitrary string, so "the number" is not self-evident.

- EA **already configured** in `custom_eas` (boolean `true_value`) or
  `security_agents` (`connected_value`): emit a single count and percentage, the
  shape that goes in a report table.
- EA **not configured**: emit the value distribution — one row per distinct
  value with its device count.

Zero configuration still produces usable numbers for every EA; configuring one
upgrades it to a headline figure. Configuration is rewarded, never required.

### D3 — Every figure carries the date it actually came from

A period boundary rarely has a snapshot on it. The Mac was off, a collect failed,
or collection began mid-period.

The report therefore always prints the **real** date beside each figure, not the
date requested. `Start (as of 19 Apr)` is the output, not a footnote that appears
when something is wrong. A boundary materially adrift from the one requested is
marked so it reads at a glance.

The drift threshold is **3 days**: a boundary resolved more than three days from
the one requested is marked. Three days absorbs an ordinary weekend or a single
missed collect without comment, and flags anything an operator should think about
before quoting the figure. It is a presentation threshold only — nothing is
excluded by it, and no calculation changes.

Out-of-tolerance rows are **not** dropped. An omitted row gives the operator
nothing; a dated one lets them judge whether the drift matters for that metric.

This is also how the feature degrades honestly for workspaces whose history
begins at 2.7.0: an early period simply shows its real, shorter window.

### D4 — Two kinds of range, and the report never names a quarter

- **Rolling** — 4 / 12 / 26 / 52 weeks back from today. Reuses `TrendRange`.
  Good for "how are we trending now".
- **Calendar** — last full month, last full quarter, or an explicit start/end.
  This is what periodic reporting actually needs: a rolling twelve weeks
  generated on 15 July begins on 22 April and silently misses three weeks of an
  April–June quarter.

  "Last full quarter" means the last complete **calendar** quarter — Jan–Mar,
  Apr–Jun, Jul–Sep, Oct–Dec. This is safe for every organisation regardless of
  fiscal year, because a fiscal year shifts which *number* a quarter carries, not
  where its boundaries fall: a US federal FY starting 1 October still breaks on
  1 January, 1 April and 1 July. Since the report never prints the number (D4),
  the difference never surfaces. An organisation on a genuinely offset fiscal
  calendar uses the explicit start/end instead.

The output labels the period `1 Apr 2026 – 30 Jun 2026` and never `FY2026 Q3`.
Fiscal calendars differ between organisations — a US federal FY starts in
October, a commercial one in January — and the two source documents behind this
design disagree with each other about which quarter Apr–Jun is. A mislabelled
quarter in a report to management is worse than no label. The operator applies
their own naming in the narrative document.

## Architecture

Pure model, thin emitter — the shape `FleetWorkbookModel` / `FleetWorkbookEmitter`
already uses, so the aggregation is testable without touching a filesystem.

    ReportPeriod          value type: resolved start/end + how it was derived
    PeriodMetricCatalog   discovers which metrics this profile can offer
    PeriodReportModel     pure: summaries + ea-results + period -> rows
    PeriodReportEmitter   thin: model -> .xlsx via OOXMLWriter

### Why not extend `ReportTemplate`

Templates select sheets from **today's** snapshot; `includedSheets` has no
concept of a date range. Adding a period dimension would change the contract of
all eight existing templates to serve one new report, and every existing sheet
builder would have to grow a range parameter it ignores. A separate emitter
leaves the template system untouched.

### `ReportPeriod`

Carries the requested boundaries, the resolved ones, and the derivation so the
About sheet can state it plainly. Resolution is pure and unit-testable: given a
set of available snapshot dates and a requested boundary, it returns the chosen
date and the drift.

### `PeriodMetricCatalog`

Implements D1. Given a profile's summaries and newest `ea-results`, returns the
metrics that actually have data:

- **Fleet metrics** — the non-nil `DailySummary` fields across the period:
  total devices, mobile devices, FileVault %, compliance %, OS currency %, patch
  %, stale count, security score, SIP / firewall / Gatekeeper / Secure Boot /
  XProtect / CVE / mSCP %, action items P0–P2, EDR agent %. A metric that is nil
  for the whole period is not offered — the app does not invite the operator to
  report on data it does not have.
- **EA metrics** — every EA name present in `ea-results`, each tagged configured
  or unconfigured per D2.

### `PeriodReportModel`

Pure aggregation. For each selected metric: the start figure, the end figure, the
change, the real date of each boundary, and the daily series between them.
Percentages keep the `"%.1f%%"` string convention `CoreDashboard` and
`FleetWorkbookEmitter` already use; counts stay integers.

**Change on a percentage metric is expressed in percentage points**, rendered
`+2.4 pp`, never as a relative percentage. FileVault moving 96% -> 98% is
"+2.0 pp", not "+2.1%". Both are arithmetically defensible and they differ, so
the report states which it means — a figure quoted into a document written for
management must not be ambiguous. Counts show a signed integer. A metric with no
observation at a boundary reports no value rather than zero — the distinction
between "none" and "not measured" is load-bearing throughout this codebase.

### Workbook

Four sheets.

1. **Summary** — the paste-ready block. `Metric | Start | End | Change | Start
   as of | End as of`. Deliberately free of caveats and commentary so a
   rectangular selection can be copied straight out.
2. **Daily detail** — one row per day, one column per selected metric, so the
   operator can chart or spot-check the shape rather than trusting two endpoints.
3. **Value distributions** — one block per selected unconfigured EA: distinct
   values and device counts at each boundary. Only present when such an EA is
   selected.
4. **About** — resolved period, profile, generation time, app version, and the
   coverage notes: which metrics had a short window, which boundaries drifted,
   which days were missing. Separate from Summary precisely so Summary stays
   paste-ready.

No charts in the first pass. The daily series is present, Trends already charts
on screen, and twenty embedded charts would bury the numbers this report exists
to surface. Cheap to add later against `ChartRenderer`.

### Output

`Generated Reports/`, via `ExportNaming`, with the period in the kind so
successive reports are self-identifying rather than distinguishable only by
timestamp:

    period-report-20260401-20260630-<profile>-<timestamp>.xlsx

### UI

A "Period report" action in `ReportsView`, opening a sheet with period selection
(D4) and metric selection from the discovered catalogue (D1). Generated artifacts
stay listed with every other report.

The metric selection persists per profile in `@AppStorage`, as the custom
template's sheet selection already does — periodic reporting repeats, and
re-picking twenty metrics each quarter is the kind of friction that stops a
feature being used. A selection naming a metric no longer in the catalogue is
dropped silently on load rather than shown as an error.

## Deferred

Named here so they are decisions rather than omissions.

- **Apple Silicon / Intel split.** Wanted, and derivable from
  `hardware.modelIdentifier` in dated `computers` snapshots — `MobileFleetService`
  already classifies by model identifier and is the precedent. Deferred because
  it introduces a second historical data source with different availability, and
  the core value does not depend on it.
- **True enrollment counts.** `totalDevices` is point-in-time, so its delta is
  enrollments *minus* unenrollments: a quarter with forty new and thirty-five
  retired reads as "five enrolled". Real enrollment needs per-device first-seen
  data, available only from dated raw snapshots retained since 2.7.0. Agreed
  acceptable to build later with history beginning at 2.7.0, labelled as such.
- **CLI subcommand.** `jamf-reports period-report --from --to` fits the included
  CLI's existing pattern and would let periodic generation be scripted.
- **Charts.**

## Testing

The aggregation is pure, so it is tested directly:

- Boundary resolution: exact hit, drift within tolerance, drift beyond it,
  no snapshot before the start, a period entirely without data.
- D3: the reported date is the snapshot's own date, never the requested one.
  A drifted boundary is marked.
- D2: a configured EA yields a count and percentage; an unconfigured one yields a
  distribution; the same EA yields different shapes either side of configuration.
- D1: a profile with no EAs offers a catalogue of fleet metrics only and does not
  fail; a metric nil across the whole period is not offered.
- Nil versus zero at a boundary, both directions.
- D4: a rolling window and a calendar period ending on the same day resolve to
  different starts — the defect that motivates offering both.
