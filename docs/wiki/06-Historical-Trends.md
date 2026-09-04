# Historical Trends

Jamf Pro shows you current state. A reporting program needs point-in-time history. The
project's model is simple: save a snapshot every run, then build timelines from those
snapshots later. Jamf will not reconstruct past state for you on demand.

## The Trends screen

![Historical Trends](images/historical-trends.png)

The app's **Trends** screen plots fleet metrics over time — compliance, FileVault rate,
patch posture, device counts, and a weighted stability index. A metric picker switches
the hero chart; comparison charts stack compliance bands and overlay multiple series.

The trend range defaults to four weeks and is configurable in **Settings → Data &
Charts** (up to roughly a year of history).

Title-level patch adoption speed (days to 50%/90% adoption after a release) is a
separate view on the Patch screen, not a Trends metric; see
[Patch Velocity](https://github.com/tonyyo11/jamf-reports-community/wiki/06b-Patch-Velocity).

Trends is for looking. When you need the same history as *figures to quote* — a start, an
end, and the change over a quarter or any other window — generate a
[period report](https://github.com/tonyyo11/jamf-reports-community/wiki/06c-Period-Reports)
from the Generated screen instead. It reads the same `summary.json` snapshots described
below, plus your collected extension attributes.

## Compliance band history

When `compliance.baselines` (see [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates))
configures more than one mSCP/STIG baseline, the compliance band chart shows a
baseline picker — each baseline keeps its own independent band series, and counts are
never summed across frameworks.

Some `ea-results` snapshot files are recovered from a truncated download rather than
decoded whole. A day recovered this way is marked on the band chart with a warning
triangle and a caption explaining it, so a partially-recovered day is never read as a
real change in fleet compliance. Salvaged days are also excluded from the Extension
Attributes screen's coverage-drift comparison for the same reason — a truncated
snapshot would otherwise look like a genuine coverage drop.

## summary.json snapshots

Every collect or generate run writes one `summary.json` file to:

```
~/Jamf-Reports/<profile>/snapshots/computers/summaries/
```

Each file is a per-day aggregate — date, total devices, compliance percentage, FileVault
percentage, patch percentage, and related metrics. The Trends screen reads this directory;
one file equals one point on the timeline. The first run of a given day writes that day's
summary; later runs the same day leave it in place. See [Data Provenance](https://github.com/tonyyo11/jamf-reports-community/wiki/11-Data-Provenance)
for details on where each metric comes from.

Because the cadence determines the granularity, **build the collection cadence first**
(see [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation)). Weekly collection produces
weekly trend points; irregular collection produces irregular timelines.

## Two historical stores

Trend data uses two on-disk stores, kept separate on purpose:

- **CSV snapshot history** (`snapshots/`) — dated Jamf Pro CSV exports. The trend source
  for export-only data: Extension Attributes, compliance failure lists, department and
  manager slicing.
- **jamf-cli JSON history** (`jamf-cli-data/`) — cached API responses. The trend source
  for API-native summaries: OS adoption from `inventory-summary`, device-state trend from
  `device-compliance`, security posture from `security`.

The app's Trends screen reads these `summary.json` snapshots. Treat `snapshots/`
and `jamf-cli-data/` as append-only — generated workbooks and PNGs are disposable output,
not the historical record.

## HTML report timeline

The self-contained HTML report renders a macOS adoption timeline once two or more
OS-version snapshots exist for the same instance.
