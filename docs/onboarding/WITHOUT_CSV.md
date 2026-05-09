# Running Without a CSV Export

The native app no longer requires a Jamf Pro CSV export to produce a report. All GUI flows
run on `jamf-cli` data alone. CSV is now optional and exists for parity with the legacy
Python path and to enable a handful of CSV-only sheets.

## What this is NOT

This is not a separate mode or a fallback. The default path is jamf-cli-only. CSV is
additive.

## What jamf-cli alone can produce

With only cached jamf-cli JSON in `~/Jamf-Reports/<profile>/jamf-cli-data/`, the engine
renders:

- Fleet Overview, Mobile Fleet Summary
- Inventory Summary, Mobile Inventory
- Security Posture, Device Compliance
- EA Coverage, EA Definitions
- Software Installs, Policy Health
- Profile Status, Mobile Config Profiles
- App Status
- Patch Compliance, Patch Failures
- Update Status, Update Failures

These power all five Reports templates (Executive, Operational, Compliance, Asset, Security
Posture) end to end.

## What CSV adds

Drop a Jamf Pro Advanced Search CSV export into the Data Sources tab to unlock:

- Stale Devices (driven by `last_checkin` column)
- Security Controls breakdown (FileVault, SIP, Gatekeeper, firewall per device)
- Security Agents matrix (CrowdStrike, sensors, etc.)
- Compliance failures-list per device (mSCP audit plist values)
- Custom EA sheets (one per `custom_eas` entry in `config.yaml`)

If your tenant has not configured these EAs in Jamf Pro, the CSV cannot add them either.

## Customization Wizard walkthrough

The Customization Wizard exists for tenants that have no CSV export to seed column
mappings. It builds a working `config.yaml` from your live jamf-cli data.

1. Open the Customize tab.
2. Click **Customization Wizard**.
3. **Step 1 — Discover EAs.** The wizard runs `jamf-cli pro report ea-coverage` against
   your active profile and lists every Extension Attribute the server returns. Tick the
   ones you want included as Custom EA sheets. Each has a guessed type (boolean,
   percentage, version, text, date) you can override.
4. **Step 2 — Set thresholds.** Stale device days (default 30), patch compliance bands,
   warning vs critical percentages. The wizard previews the impact against your live
   counts so you can see how many devices fall into each band before committing.
5. **Step 3 — Pick sheets.** Toggle each sheet on or off. Disabled sheets do not appear
   in any template that includes them.
6. **Step 4 — Pick a template default.** This becomes the default selection in the
   Generated tab.
7. **Save.** The wizard writes `config.yaml` atomically into the active profile folder
   and triggers a refresh.

## Editing the config after the wizard

The wizard never overwrites a manually-edited config without prompting. To tweak by hand:

```bash
open -a "TextEdit" ~/Jamf-Reports/<profile>/config.yaml
```

The schema is documented in the root `config.example.yaml`. After editing, switch back to
the app — the Customize tab auto-refreshes on focus and re-reads the file.

## Verifying without a report run

Use the Health Audit tab to validate the configuration before generating anything large:

- Each EA you enabled is listed with its column name and detected type.
- Any column that does not exist in the cached data is flagged red with the exact
  scaffold suggestion to fix it.

When the Health Audit is green, run a report from the Generated tab.
