# Stale basis and contact gap — design

Status: approved by the owner on 2026-10-05 for 2.9.0 ("Both in 2.9.0").

Two changes built on the three dates Jamf Pro keeps for a Mac:

| Jamf Pro | `computers` snapshot | What moves it |
|---|---|---|
| Last Check-in | `general.lastCheckIn` | the Jamf binary checking in |
| Last Inventory Update | `general.reportDate` | the Jamf binary submitting inventory (recon) |
| Last Contact (Jamf Pro 11.30) | `general.lastContact` | any contact: the Jamf binary, MDM or declarative device management |

1. **Stale is defined by the organization**: which of the three dates count, not only how many days.
2. **Contact gap**: a Mac whose Last Contact is current while its check-in or inventory lags far
   behind needs a person to look at it. Last Contact moving while Last Check-in does not is the
   signature of a Mac MDM reaches but whose Jamf binary is broken, removed or blocked (the
   owner's KB-043 pattern, inverted: MDM works, the binary is silent).

## What is true today (prod `computers` snapshot, 2026-10-05, 664 Macs, aggregates only)

- All 664 carry `lastCheckIn` and `reportDate`; 560 carry `lastContact`. The 104 without it all
  have a check-in older than 30 days: they have not contacted Jamf Pro since it began recording
  Last Contact.
- Older than 30 days: check-in 128 (127 in whole days, jamf-cli's `days_since_contact`),
  inventory 135, either one 135.
- Contact within 7 days but check-in more than 14 days behind it: 1 Mac. Contact within 7 days,
  check-in current, inventory more than 14 days behind: 6 Macs.
- Stale today (PR #247): last check-in more than `thresholds.stale_device_days` days ago, through
  `DeviceComplianceRow.isStale(atDays:)` (device-compliance `days_since_contact`) and
  `DeviceInventoryRecord.isStale(atDays:)`.

## Config

```yaml
thresholds:
  stale_device_days: 30
  stale_basis: [check_in, inventory]   # optional; default [check_in]
  contact_gap_days: 14                 # optional; default 14
```

- `stale_basis` lists the dates that count: `check_in`, `inventory`, `contact`. A Mac is stale
  when ANY listed date is more than `stale_device_days` whole days old (the owner: "not
  inventorying/checking in beyond 30 days"). A single string reads as a one-item list.
- Absent, it is `[check_in]`, today's rule, so no other organization's count moves.
- A word the app does not know is skipped and named by Config Doctor. An empty list, or one with
  no known word, uses the default and is named.
- A missing date: a missing check-in or inventory date on a record that should have one counts
  as never (stale). A missing `contact` date is unknown and that entry is ignored for the Mac
  (Jamf Pro before 11.30, or no contact since). A Mac whose listed dates are all unknown falls
  back to jamf-cli's `stale` flag, as today.
- Ages are whole days elapsed (floor), so a day count matches jamf-cli's `days_since_contact`.
- `contact_gap_days`: a whole number from 1 to 365; anything else uses 14 and is named.

## The stale rule

One rule, one place (`StaleRule`, or methods on the existing types): given the three dates and
`now`, the **stale age** is the largest age among the listed dates that are known, and a Mac is
stale when the stale age is more than `stale_device_days`. Everything that counts or buckets by
staleness uses the stale age:

- the daily summary's `staleCount`, the Overview, Devices (filter, tile, detail panel), Offline
  Outreach (its Recent / Offline / Inactive / Dormant tiers bucket by stale age), Fleet Overview;
- the workbook (Active Devices, Compliance Posture, Device Compliance, Check-in Health, the Patch
  Summary Dashboard's active window, Executive Summary tiers), the CSV sheets, the HTML report;
- the score's `checked_in` factor (its label names the basis: "Checked in within 30 days",
  "Checked in and inventoried within 30 days", ...).

The device-compliance rows carry only the check-in day count, so with `inventory` or `contact`
listed the rule reads the dates from the `computers` snapshot, joined by the stable identifiers
the device merge uses (Jamf ID, then serial). With only `check_in` listed and no `computers`
snapshot, it reads the device-compliance rows as today. A CSV-only workspace has the inventory
date only when the export has a "Last Inventory Update" column (map `columns.last_inventory`, a
new optional column key); without it, `inventory` does not apply to CSV rows and Config Doctor
says so. The Health Audit's stale finding stays jamf-cli's own.

## Contact gap

For a Mac with a Last Contact date that is itself current (Last Contact no more than
`stale_device_days` old; a Mac silent on every channel is stale, not a gap):

- **Jamf binary silent**: Last Check-in is more than `contact_gap_days` days before Last Contact.
- **Inventory not updating**: Last Check-in is within `contact_gap_days` of Last Contact, and Last
  Inventory is more than `contact_gap_days` before it.

A Mac without Last Contact is left out (not flagged). Surfaces:

- **Health Audit**: one finding per kind, app-computed like Command health ("Jamf binary not
  checking in while MDM reaches the Mac", WARNING; "Inventory not updating while the Mac checks
  in", INFO), each with its device count and the device list, and a recommendation (check the
  Jamf binary and its launch daemons, `sudo jamf policy`, network path to Jamf Pro; for inventory,
  `sudo jamf recon` and the inventory policy's scope).
- **Devices**: a "Contact gap" filter, and the detail panel shows Last Contact, Last Check-in and
  Last Inventory with the gap named.
- **Workbook**: the Check-in Health sheet gains Last Contact, Last Check-in and Last Inventory
  columns and a Contact gap column.
- **HTML report**: a Needs attention line when either list is non-empty.

## Not in this change

- The daily summary records no contact-gap count (no new Trends series or alert key).
- Mobile devices: the rule and the gap are computed for Macs only.

## Decisions (settled 2026-10-05)

1. `stale_basis` default `[check_in]`; the owner's workspace sets `[check_in, inventory]`.
2. Stale when ANY listed date is older; a missing Last Contact is unknown, not stale.
3. Contact gap: lag measured from Last Contact, default 14 days, only for Macs current by Last
   Contact.

## As built

What differs from, or settles, the text above (2026-10-05, same branch):

- **Where the rule lives.** `StaleRule` (`Models/StaleRule.swift`) takes `StaleInputs`: the
  source's own check-in day count, three dates, whether the source dates every Mac
  (`carriesDates`) and the source's stale flag. `ContactGap` (`Models/ContactGap.swift`) is the
  gap. `ComputerDates`/`ComputerDateIndex` (`Services/ComputerDates.swift`) read the three dates
  from a `computers` snapshot and join a compliance row by Jamf ID, then serial; a serial never
  joins two records whose Jamf IDs differ, and an identifier two Macs share finds neither.
- **"Never" is per source.** A missing check-in or inventory date counts as never only when the
  source dates every Mac: a `computers` record, or a CSV row whose check-in cell is blank (as the
  CSV sheets always read it) or whose inventory cell is blank in a mapped column. A
  device-compliance row, or a CSV without `columns.last_inventory`, does not carry the inventory
  date, so it is left out of the rule rather than read as never. One change under the default
  `[check_in]`: a `computers` record with no check-in date and no day count is now stale (before,
  Devices left it unflagged and the HTML list aged it by its inventory date).
- **No `computers` snapshot.** With `inventory` or `contact` listed, the summary counts the
  check-in alone and logs a notice.
- **Contact gap.** A missing check-in or inventory date on a Mac with a current Last Contact is
  older than any gap. The "current" bound is `stale_device_days`. The Audit section is left out
  when no Mac carries a Last Contact (Jamf Pro before 11.30). Severities: WARNING for the silent
  binary, INFO for stale inventory, OK when none.
- **Check-in Health.** The sheet had no per-Mac rows, so the three dates and the gap column are a
  detail table under the summary (Macs that are overdue or show a gap, gaps first), written when
  a `computers` snapshot exists. Its overdue count uses `checkin_overdue_days` over the same
  basis.
- **Other surfaces.** Fleet Drift's New and Recovered Stale follow the rule over the CSV's dates.
  The Stale Devices and Offline Outreach age columns show the stale age when the basis is not the
  default, and "never" for a Mac that never had a counted date. The Devices table column that held
  the check-in is titled "Last Check-in", so it is not read as Jamf's Last Contact; the detail
  panel shows the check-in, inventory and Last Contact dates.
- **Config screen.** Thresholds writes `stale_basis` and `contact_gap_days` only when the choice
  differs from what the file already says, so a hand-typed single word or an explicit default is
  left as typed and the default is the absent key.
- **Not done.** The daily summary records no stale basis, so a Trends series that spans a basis
  change mixes definitions (the same caveat patch compliance had); a basis edit reaches the
  summary with the next collect. Scaffold does not auto-map "Last Inventory Update".

