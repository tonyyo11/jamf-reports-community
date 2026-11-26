# Patch Velocity

Patch compliance answers "how many devices are on the latest version right now."
Patch velocity answers a different question: **how fast does the fleet get there
after a title ships an update?**

## Where it shows up

- **Patch Compliance screen** — the title table gains a "Days Behind" column (days
  since the title's latest release), alongside the existing "Released" column. A
  **Patch Velocity** card below the table charts the five slowest-adopting titles'
  adoption curves and lists, per title, the days to reach 50% and 90% adoption.
- **Generated reports** — every workbook gains a "Patch Velocity" sheet: one row per
  title with Released, Days Behind, Current Adoption %, Days to 50%, Days to 90%, and
  a data-point count, plus an embedded chart of the same slowest-adopting titles (when
  charts are enabled).

## How it's computed

Velocity is derived entirely from data the app already collects — no new jamf-cli
calls:

- **Adoption curve** — built from every dated `patch-status` snapshot already saved
  to disk (one file per collect run). One point per calendar day; when a day has more
  than one snapshot, the newest one wins. Adoption % for a day is
  `on_latest / total * 100`, capped at 100% (jamf-cli can double-count a device across
  patch policies).
- **Release date** — read from the `patch-release-dates` snapshot (per-title
  `latest_version` + `release_date`, fetched via jamf-cli patch definitions). Matched
  to a title by ID first, falling back to a case-insensitive name match.
- **Days Behind** — days from the release date to today. Clears to nothing once the
  newest sample shows 100% adoption — there's nothing left to chase.
- **Days to 50% / 90%** — days from the release date to the first *recorded* sample
  that reached the threshold. This is reported **only when the crossing was actually
  observed** in the saved history — the app never estimates or interpolates a
  crossing. A title that was already above 50% (or 90%) the first time its history was
  recorded shows no "days to" figure for that threshold, because the true crossing
  happened before recording began and any number the app produced would be invented.
- **Sparser collection cadence widens the window.** If patch-status is collected
  weekly rather than daily, "days to 50%" reflects the first weekly sample at or above
  the threshold — an upper bound on the true crossing date, not an exact one.

## Version history

Patch Velocity looks at each title's current version. **Version History** looks at every
version:

- **Patch Compliance screen.** The Version History card has a title picker. For the title you
  pick, it lists every version Jamf defines, newest first (the first 20, then "Show all"), with
  its release date and how far it got while it was the latest. Above the list is the fleet
  figure for the last 90 days.
- **Generated reports.** The workbook's "Patch Version History" tab has one row per version
  window: Title, Version, Released, Window start, Window end, Days to 50%, Days to 90% and
  Outcome, then the fleet figure. The HTML report's Patching group lists the slowest windows
  to reach 90%.

How it's computed:

- **A version window** is the run of days Jamf reported that version as the title's latest:
  from the first such day to the first day it named another. A version that becomes the
  latest again gets a second window. A day Jamf names no version, or the title has no
  devices, adds nothing to a window.
- **Outcome**, from the adoption in the window: reached 90%, already at 90% when first seen,
  superseded before 90%, or not yet at 90%.
- **Days to 50% and 90%** count from the version's release date to the first day it reached
  the threshold, under the same rules as Patch Velocity: only observed crossings, never an
  estimate.
- **The fleet figure** is the median and 90th percentile of days to 90% over the last 90
  days, counted in windows. It needs at least 5 windows that reached 90% and have a release
  date. Versions that were superseded first, are not there yet, were already at 90%, or
  reached 90% with no release date are counted beside it, never in it.
- **Release dates** come from the patch definitions the app already reads for Patch Velocity,
  which list every version of a title. The app keeps them in a `patch-version-dates` file
  beside `patch-release-dates`, written only when the definitions change. A title whose
  definitions call did not answer keeps its earlier dates, and the card shows which day they
  are from. Older dated `patch-release-dates` files (more than 180 days) are not
  searched; the newest one is always read, and the version-dates file covers older versions.

Patch Velocity's figures come from the same windows: its release date, days behind and days
to 50% and 90% are those of the window of each title's current version.

## What it needs

- **Dated patch-status history.** The velocity card and sheet need more than one day
  of collected `patch-status` snapshots to plot a curve; a single day's data isn't
  enough to show a trend. Curves fill in as history accumulates. Retention keeps raw
  snapshots indefinitely by default (see [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates)
  → Snapshot Retention), so this history is not pruned unless retention is explicitly
  turned on.
- **The `patch-release-dates` snapshot.** Without it, the card and sheet still show
  the adoption curve but say plainly that release dates are unavailable — Days Behind
  and the 50%/90% milestones read as unknown rather than a fabricated "—" with no
  explanation.
- **At least one enrolled device.** A title with zero devices on every collected day
  is excluded — there's no adoption percentage to compute.

## Related pages

- [Historical Trends](https://github.com/tonyyo11/jamf-reports-community/wiki/06-Historical-Trends) covers fleet-wide metrics over time
  (compliance, FileVault, device counts). Patch adoption velocity is a title-level
  view scoped to the Patch screen, not a Trends metric.
- [App Dashboards](https://github.com/tonyyo11/jamf-reports-community/wiki/03-App-Dashboards) — see the Patch Compliance bullet under
  Operations for the rest of that screen.
