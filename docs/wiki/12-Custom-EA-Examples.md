# Bringing In Custom Extension Attributes — Worked Examples

> Everything on this page is per workspace: each example edits the **active workspace's**
> `config.yaml`.

## Before you start

Custom EA sheets and the EA Warnings sheet are built from the extension attribute values
jamf-cli collects (`ea-results`), so run a collect first. No CSV export is needed (the CSV
workbook tabs were retired in 2.11). An EA's `column:` in `config.yaml` is the EA's name
as Jamf Pro shows it.

## Path A — Adopt EAs (recommended)

**Extension Attributes → "Adopt EAs…"** (or **Data Sources → "Adopt EAs"**) lists the
Extension Attributes jamf-cli already collected, with a guessed type for each, and adds the
ones you select to `config.yaml` when you choose **Add … to config**. Existing settings are
kept, and an EA already tracked is left out of the list. Each candidate has an
**"Adopt as"** choice — **Custom EA** or **Security Agent** — so the same flow
covers both reporting shapes.

### Example 1 — Boolean EA (compliance state)

- EA: `FileVault 2 - Status`, sample value `Encrypted`
- Adopt as: **Custom EA**, type **boolean**, true value `Encrypted`
- Result in `config.yaml`:
  ```yaml
  custom_eas:
    - name: FileVault Status
      column: "FileVault 2 - Status"
      type: boolean
      true_value: Encrypted
  ```
- Validate: regenerate a report and confirm the "FileVault Status" sheet shows pass/fail counts.

### Example 2 — Security Agent (agent install/connection state)

- EA: `CrowdStrike Falcon - Status`, sample value `Installed`
- Adopt as: **Security Agent**, connected value `Installed`
- Result in `config.yaml`:
  ```yaml
  security_agents:
    - name: CrowdStrike Falcon
      column: "CrowdStrike Falcon - Status"
      connected_value: Installed
  ```
- Validate: the Security Posture screen / EDR card reflects the install rate.

### Example 3 — Version EA

- EA: `SysTrack Agent Version`, sample value `5.7.6`
- Adopt as: **Custom EA**, type **version**, current versions list (tune later)

### Example 4 — Date EA (certificate / expiry)

- EA: `KerberosSSO - password_expires_date`
- Adopt as: **Custom EA**, type **date**, warning days `30`

### Example 5 — Percentage EA

- EA: `Disk Usage Percent`
- Adopt as: **Custom EA**, type **percentage**, warning ≥ `80`, critical ≥ `90`
- Note: leave thresholds set — an empty threshold is omitted from the file (the
  engine uses its default) rather than written as an invalid value.

After adopting, the EAs show in **Config → Custom EAs** and in reports after the next
generate. Open **Health Audit → Config** (Config Doctor) to check them against the collected
data.

## Path B — Hand-editing in Config → Custom EAs

For EAs the list didn't offer, add rows manually with **+ Add EA
sheet** / **+ Add agent**. Cover the same five types as above.

## Path C — Import a CSV export once

If you have a Jamf Pro CSV export with EA columns (added under **Export-only fields** in
Jamf Pro's export builder), **Adopt EAs → Import from a CSV export (one time)** reads the
file you pick once and proposes the columns it does not already know as candidates.
`jamf-reports scaffold --csv <path> --out <path>` writes a new `config.yaml` from the
same export on the command line, with only `custom_eas` added to the minimal config. The CSV is not read again: reports use the collected EA values,
so the EA's name must match one Jamf Pro returns.

## When an EA has no data

The workbook's **EA Warnings** sheet says whether a tracked EA is missing from Jamf Pro or
defined there with no values collected, and Config Doctor reports the same. Fix the name in
Config → Custom EAs, or remove the EA.

## Custom EA type reference

| Type | Use for | Key fields |
|------|---------|-----------|
| boolean | pass/fail state | `true_value` |
| percentage | distribution + thresholds | `warning_threshold`, `critical_threshold` |
| version | version distribution | `current_versions` |
| date | days-until-expiry | `warning_days` |
| text | value frequency | — |
