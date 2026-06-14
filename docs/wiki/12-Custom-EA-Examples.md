# Bringing In Custom Extension Attributes — Worked Examples

> **DRAFT outline — to be fleshed out with screenshots.** This page scaffolds
> the end-to-end examples of adopting Extension Attribute (EA) columns from a
> CSV export into `config.yaml`. Replace each _(screenshot: …)_ placeholder with
> a real capture, and expand the prose where noted. Everything here is
> per-profile — every example operates on the **active profile's** `config.yaml`.

## Before you start

EA values are **not** in a default Jamf Pro inventory export. When exporting,
add your EA columns under **Export-only fields** so they appear in the CSV.
Drop the export into the profile's `csv-inbox/` (or the workspace root).

_(screenshot: Jamf Pro export builder with Extension Attribute columns added under Export-only fields)_

## Path A — The CSV → EA walkthrough (recommended)

**Data Sources → "EA tracking guide"** scans the newest inbox CSV, detects
EA-like columns, and lets you adopt each one. As of v2.3, each candidate has an
**"Adopt as"** choice — **Custom EA** or **Security Agent** — so the same flow
covers both reporting shapes.

_(screenshot: CSV → EA walkthrough with detected candidates and the Adopt-as picker)_

### Example 1 — Boolean EA (compliance state)

- Column: `FileVault 2 - Status`, sample value `Encrypted`
- Adopt as: **Custom EA**, type **boolean**, true value `Encrypted`
- Result in `config.yaml`:
  ```yaml
  custom_eas:
    - name: FileVault Status
      column: "FileVault 2 - Status"
      type: boolean
      true_value: Encrypted
  ```
- _(screenshot: the boolean EA row after adoption, in Config → Custom EAs)_
- Validate: regenerate a report and confirm the "FileVault Status" sheet shows pass/fail counts.

### Example 2 — Security Agent (agent install/connection state)

- Column: `CrowdStrike Falcon - Status`, sample value `Installed`
- Adopt as: **Security Agent**, connected value `Installed`
- Result in `config.yaml`:
  ```yaml
  security_agents:
    - name: CrowdStrike Falcon
      column: "CrowdStrike Falcon - Status"
      connected_value: Installed
  ```
- _(screenshot: the Adopt-as picker set to Security Agent with the connected-value field)_
- Validate: the Security Posture screen / EDR card reflects the install rate.

### Example 3 — Version EA

- Column: `SysTrack Agent Version`, sample value `5.7.6`
- Adopt as: **Custom EA**, type **version**, current versions list (tune later)
- _(screenshot: version EA row; note where Current versions is edited)_

### Example 4 — Date EA (certificate / expiry)

- Column: `KerberosSSO - password_expires_date`
- Adopt as: **Custom EA**, type **date**, warning days `30`
- _(screenshot: date EA row with warning-days field)_

### Example 5 — Percentage EA

- Column: `Disk Usage Percent`
- Adopt as: **Custom EA**, type **percentage**, warning ≥ `80`, critical ≥ `90`
- Note: leave thresholds set — an empty threshold is omitted from the file (the
  engine uses its default) rather than written as an invalid value.
- _(screenshot: percentage EA row with thresholds)_

After adopting, hit **Save** in the Config tab and **Run check** to validate the
mappings against the CSV.

_(screenshot: Config → Custom EAs after Save, with Run check passing)_

## Path B — Hand-editing in Config → Custom EAs

For columns the walkthrough didn't detect, add rows manually with **+ Add EA
sheet** / **+ Add agent**. Cover the same five types as above.

_(screenshot: Custom EAs tab with the Add buttons)_

## Re-importing as the CSV changes over time

Re-running **Re-scaffold from CSV** (Config → Columns) **merges** into the
current profile: it fills new/empty column mappings, repairs mappings whose CSV
column was renamed, and keeps your security agents, custom EAs and thresholds.
The result toast reports exactly what changed.

_(screenshot: the merge result toast after a re-scaffold)_

## Custom EA type reference

| Type | Use for | Key fields |
|------|---------|-----------|
| boolean | pass/fail state | `true_value` |
| percentage | distribution + thresholds | `warning_threshold`, `critical_threshold` |
| version | version distribution | `current_versions` |
| date | days-until-expiry | `warning_days` |
| text | value frequency | — |
