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
