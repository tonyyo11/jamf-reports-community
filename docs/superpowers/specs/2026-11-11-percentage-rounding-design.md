# Percentage rounding — design

Status: draft, awaiting Tony's approval. Branch `feat/percent-rounding` from `dev/2-12-0`.

## Problem

Every percentage the app shows has one decimal ("56.2%"). Some organizations want whole numbers
("56%") in what they read and forward. There is no shared formatter: about 100 sites build the
text themselves (`String(format: "%.1f%%")`, `"\(String(format: "%.1f", x))%"`,
`"\(Int(x.rounded()))%"`), in views, the workbook, the HTML report, alert cards and the AI input.
The workbook also has numeric percent cells styled `0.0%` (numFmt 164).

## The knob

```yaml
display:
  percent_decimals: 1   # 1 (default, today's output) or 0 (whole numbers)
```

- New top-level block `display:`, decoded by a `DisplayConfig` in `ConfigDecoder`, so it joins
  `ConfigSchema` through its `CodingKeys`. Documented in `config.example.yaml` (and its golden),
  `README.md` and the wiki config page.
- Workspace-level because it is an organization's choice for the reports it sends, and the
  scheduled runs on every Mac sharing the folder must agree. Not pinned in `SharedConfigPin`: it
  changes no path, host or retention and cannot point this Mac anywhere.
- A value other than `0` or `1` (2, "one", true) reads as 1, and Config Doctor names it in
  `valueRows` (warn, never fail), as for the other clamped values.
- Hand-edit only in this change. A Config screen control is an open question below.

### Rounding rule

Standard rounding to the chosen precision, half away from zero (56.5 → 57, 56.4 → 56). Not
"always up" or "always down": rounding up overstates a compliance figure (99.1% would read
100%), rounding down understates every good figure, and either one makes two screens that show
the same share at different precisions disagree by more than half a step. `String(format:)`
rounds half-to-even on the binary value, so the formatter rounds explicitly with
`.toNearestOrAwayFromZero` before printing.

**Guard at the ends, at both precisions.** A share above 0 never prints as 0, and one below 100
never prints as 100: 99.6 prints "99%" at 0 decimals and 99.96 prints "99.9%" at 1; 0.3 prints
"1%" / 0.04 prints "0.1%". "100%" means every device passed and "0%" means none did. This changes
today's default output for shares in 99.95..<100 and 0<x<0.05 (today "100.0%" / "0.0%"), which
is a fix and gets its own CHANGELOG line. Limit: a figure already stored rounded to a tenth
(`summary.json` shares, `OverviewLiveData`'s `pct`) that was 99.96 before storage is 100.0 and
prints "100%"; only the value as the formatter receives it can be guarded.

## The seam

One value type, `PercentFormat` (`Models/PercentFormat.swift`), nonisolated and `Sendable`:

- `decimals` (0 or 1); `PercentFormat.standard` is 1.
- `text(_ value: Double?) -> String`: "57%" / "56.7%", the dash for nil (absent is not zero).
- `rounded(_ value: Double) -> Double`: the guarded figure as printed, for code that compares
  or subtracts printed figures (`TrendChange`, the AI facts).
- `points(_ delta: Double) -> String`: "1 pp" / "0.4 pp".
- `text(_ value: Double, beside threshold: Double) -> String`: for a figure printed next to the
  threshold it was compared with. If rounding would reach or cross the threshold the raw value
  did not, it prints one decimal: at 0 decimals 89.6 against "below 90%" prints "89.6%", never
  "90% (below 90%)".

How each side gets it:

- **Engine** (`CoreDashboard`, `SchoolDashboard`, `HtmlReport`, the period report, `EASheets`):
  `config.display.percentFormat`, from the `ReportConfig` they already hold. Headless and CLI
  runs read the same config, so a scheduled workbook matches the GUI's.
- **Views**: `WorkspaceStore.percentFormat`, set when the active workspace's config loads, put
  into the environment once at `ContentView` (`\.percentFormat`); views read
  `@Environment(\.percentFormat)`. Static helpers that format (`SecurityPostureView.percent`,
  `AccessibilityDescriptors`, `MobileOverviewTile`, `TrendChange`) take a `PercentFormat`
  parameter. No global, no TaskLocal: SwiftUI bodies do not run inside a task that carries one.
- **Demo mode** reads no workspace, so it uses `.standard`.
- **Alert and webhook cards** (`MetricAlertEvaluator`, the scheduled-run facts): the workspace's
  format, with the `beside:` rule for "below/above N%" text.
- **AI input** (`FleetInsight`, `ReportNarrativeGenerator`): the same format, so the insight card
  never says "56.7%" beside a tile that says "57%". `FleetInsight.tenths` becomes
  `format.rounded`.
- **Group exports** (`FleetReportEmitter` CSV, `FleetWorkbookEmitter`) span several workspaces
  with no one config.yaml: they stay at `.standard`. If the workspaces disagree there is no right
  answer to pick.

## Percentage points

Keep CLAUDE.md's existing `TrendChange` rule and extend it to the chosen precision: a change is
taken between the figures as printed, and a change that rounds to nothing is "No change". At 0
decimals 56.4 → 56.6 prints 56% → 57% and "+1 pp"; 56.2 → 56.4 prints 56% → 56% and "No change",
never "+0 pp". The pp text has the same number of decimals as the figures. The count hero's
relative change ("9 (3.2%)") follows the format too.

## Where it applies

| Output | Change at `percent_decimals: 0` |
|---|---|
| Screens, tiles, pills, Trends hero, accessibility values | Text through `PercentFormat` |
| Workbook numeric cells (`.pct*` styles) | numFmt 164 becomes `0%`; the stored value keeps full precision |
| Workbook text cells (`CoreDashboard`'s `"%.1f%%"` cells, `percentLabel`) | The cell text itself is whole: a value change |
| CSV folder | Follows the workbook cells (numeric cells print with the format's decimals) |
| HTML report and PDF | Text through `PercentFormat`; bar widths unchanged |
| Alert cards | `PercentFormat`, `beside:` for threshold text |
| Standalone CSV exports (Patch Compliance, inventory) | Through `PercentFormat` |

Colours stay on the raw figure: `CoreDashboard.colorForPctString` parses the formatted text, so
at 0 decimals 94.6 would turn green (≥95). It takes the Double instead, and so does any other
site found reading a formatted percentage back.

### Not rounded

- Stored data: `summary.json`, snapshots, the alert ledger, thresholds and the comparisons that
  fire alerts, score calculations. Only display rounds.
- Geometry: CSS bar widths (`renderPercentBars`), SVG and chart coordinates, chart data.
- Parsers of jamf-cli and EA input (`parsePercentString`, `OSVersionName.percent`,
  `parseCompliancePct`) and the raw EA values on the custom EA tabs (`EASheets.writePercentage`
  prints what the EA reported).
- Axis ticks (`Int(pct)` on 0/25/50/75/100) and user-typed thresholds (`ConfigView`'s "Warning ≥
  N%").
- Sites that are already whole on purpose (pie labels in `ChartRenderer`, the HTML layout's
  lowest-agent note, `DevicesView`'s compact cell, the posture donuts' accessibility values, the
  EA drift callout) stay whole, but go through `PercentFormat(decimals: 0)` so the end guard
  applies to them too.

## Keeping the class closed

A test in the style of `testArgvShapedLinesMatchTheEnumeration` scans `app/Sources` and fails on
a `%.0f%%`, `%.1f%%`, `String(format: "%.1f", …))%"` or `Int(….rounded()))%"` literal outside
`PercentFormat.swift` and a short allow-list of the exclusions above. The PR body carries the
sweep grep.

## Localization

Numbers keep the existing POSIX formatting (`57%`, no locale spacing such as French "57 %"; that
is a separate question). GUI text around them still goes through `L()`; the formatter returns
the figure only, so no catalog key changes.

## Workbook and CHANGELOG

At the default nothing in a workbook changes except a share in 99.95..<100 or 0<x<0.05 (end
guard). At 0, text cells hold whole numbers and numeric cells display whole numbers. The
CHANGELOG gets a Changed note: "Workbooks: with `display.percent_decimals: 0` percentage text
cells hold whole numbers, and a share just below 100% or above 0% no longer prints as 100% or
0% at either setting. If a tool reads these workbooks, check it with a new workbook." No Power
BI specifics.

## Tests

- `PercentFormatTests`: both precisions, half-away ties (56.5, 0.05), the end guard (99.6, 99.96,
  0.3, 0.04, exactly 0 and 100, above 100, negative, NaN), nil, `points`, `beside:` at and
  around the threshold.
- `TrendChange` at 0 decimals: +1 pp, "No change" for a sub-step move, never "+0 pp".
- Decoder: absent → 1, 0, 1, 2 → 1 with a Doctor row, a string → 1 with a Doctor row;
  `ConfigSchema` knows the key; `config.example.yaml` golden.
- Workbook: numFmt is `0%` at 0 and `0.0%` at 1; a `CoreDashboard` text cell at 0; RAG colour at
  94.6 is yellow at both precisions.
- HTML: one tile and one table at 0. Alert card text with `beside:`.
- The literal-pin test.

## Open questions for Tony

1. **Config screen control?** Recommendation: a "Percentages: 56.7% / 57%" picker on Customize
   Reports, written through a scoped `saveBlock` writer like `HTMLReportConfigWriter`. Without
   it the key is hand-edit only, which works but nobody finds it.
2. **Group exports**: stay at one decimal (recommended), or follow the base profile's setting?
