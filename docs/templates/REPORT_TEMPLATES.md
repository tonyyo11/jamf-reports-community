# Report Templates

JamfReports ships five templates. Pick one in the Generated tab; the engine composes
the relevant sheets and renders to XLSX, HTML, or PDF.

## What this is NOT

Templates are not separate report engines. They are curated sheet selections plus a
default chart layout. Every sheet they include is also available individually if you
build a custom workbook in the Data Sources tab.

## Choosing a template

| Template          | Audience              | Cadence  | Sample stakeholder            |
|-------------------|-----------------------|----------|-------------------------------|
| Executive         | Leadership            | Monthly  | Director of IT                |
| Operational       | NOC / fleet ops       | Daily    | Fleet ops on-call             |
| Compliance        | Auditors, ISSO        | Monthly  | Authorising official, ISSO    |
| Asset             | Asset / lifecycle mgr | Quarterly| Procurement, hardware refresh |
| Security Posture  | Security review       | Weekly   | SOC lead, security engineer   |

## Executive

Leadership summary. The current default. Optimized for a one-screen story: total
managed devices, encryption rate, patch posture, an OS adoption chart, and the top
three intervention queues by count.

Included sheets:

- Fleet Overview
- Mobile Fleet Summary
- Security Posture (top-line counts only)
- Patch Compliance (band summary)
- Update Status (band summary)

Recommended cadence: monthly, sent as PDF.

## Operational

NOC daily view. Maximises actionable failures and intervention queues. Designed to be
worked from top to bottom by an operator on shift.

Included sheets:

- Fleet Overview
- Patch Failures (per-device)
- Update Failures (per-device)
- Policy Health (config findings, warnings, info)
- Profile Status (failed installs)
- Stale Devices (when CSV is provided)

Recommended cadence: daily, sent as XLSX so columns can be sorted and filtered.

## Compliance

Auditor view. Ties Jamf Pro state to mSCP baselines and compliance bands. This is the
template to attach to an authorisation package.

Included sheets:

- Fleet Overview
- Compliance (mSCP audit results, one row per device per failed check)
- Patch Compliance (band buckets with color coding)
- Custom EA sheets configured as `boolean` against compliance EAs (FileVault, etc.)
- EA Coverage (proves which devices have submitted compliance data)
- EA Definitions (proof of which checks the tenant is running)

Recommended cadence: monthly or per audit cycle, archived as PDF for the record and
XLSX for the auditor's working copy.

## Asset

Inventory and lifecycle. Built for procurement and hardware refresh planning.

Included sheets:

- Inventory Summary (model, processor, RAM, storage breakdowns)
- Mobile Inventory
- Device Inventory (when CSV is provided — adds warranty, serial, purchase date,
  AppleCare end date columns)
- Stale Devices (when CSV is provided)
- Software Installs (top 50 by install count)

Recommended cadence: quarterly, sent as XLSX.

## Security Posture

Security review. Ties Jamf-managed controls to security agents and EA-derived signals.

Included sheets:

- Security Posture (FileVault, SIP, Gatekeeper, firewall counts)
- Security Controls (per-device, when CSV is provided)
- Security Agents (per-device matrix, when CSV is provided)
- Custom EA sheets configured as `boolean` against security EAs (XProtect, MRT, etc.)
- Patch Compliance (security-relevant titles surfaced first)

Recommended cadence: weekly, sent as HTML for inline charts and Chart.js drilldown.

## Picking a format

| Format | When to use                                                                  |
|--------|------------------------------------------------------------------------------|
| XLSX   | Default for any audience that filters, sorts, or pivots the data             |
| HTML   | Stakeholders who prefer a rendered web page with interactive charts          |
| PDF    | Archival, evidence packages, anyone who will print                           |

All three formats are produced by the native Swift engine. None of them require Python.

## Customizing a template

Templates are intentionally curated to keep the picker simple. To produce a one-off
mix, use the Data Sources tab to pick sheets manually and Generate from there. To
change a template's defaults permanently, edit the relevant template file under
`app/Sources/JamfReports/Engine/Templates/` and rebuild — this is a code change,
not a config change.
