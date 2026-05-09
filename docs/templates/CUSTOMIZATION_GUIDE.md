# Customization Guide

How to shape JamfReports to your tenant. Start with the Customization Wizard; drop into
`config.yaml` only when the wizard cannot express what you need.

## What this is NOT

This is not a YAML reference. The full schema lives in the root `config.example.yaml`.
This guide explains the wizard, the post-wizard edit loop, and recipes for the most
common Extension Attributes.

## When to use the wizard

Use the wizard when:

- You are setting up a fresh profile and have no `config.yaml` yet.
- You want to add or remove EA sheets without hand-editing YAML.
- You want to preview threshold changes against live counts before committing them.

Skip the wizard and edit `config.yaml` directly when:

- You are migrating a config across profiles.
- You need a config key the wizard does not surface (custom archive paths, snapshot
  locations, chart band overrides).
- You are scripting bulk profile setup.

## Wizard walkthrough

Customize tab -> **Customization Wizard**.

### Step 1 — Discover EAs

The wizard runs `jamf-cli pro report ea-coverage` against the active profile. Each EA
the server returns is shown with:

- The Jamf Pro EA name
- A guessed type (boolean, percentage, version, text, date) inferred from the value
  distribution in the live data
- A coverage percentage (devices that have submitted a value)

Tick the EAs you want as Custom EA sheets. Override the type if the guess is wrong.

### Step 2 — Set thresholds

Stale device days, patch compliance bands, warning vs critical percentages. Each slider
shows the live count of devices that fall into the new bucket as you drag, so you can
see the impact before committing.

### Step 3 — Pick sheets

Toggle each top-level sheet on or off. Disabled sheets are skipped by every template
that includes them. Use this to slim down a workbook for a specific audience.

### Step 4 — Pick a template default

Sets the initial selection in the Generated tab. Does not prevent picking another
template per generation.

### Save

The wizard writes `config.yaml` atomically. The Customize tab refreshes on focus and
re-reads the file.

## Editing config.yaml after the wizard

```bash
open -a "TextEdit" ~/Jamf-Reports/<profile>/config.yaml
```

Common post-wizard edits:

- Re-order `custom_eas` entries to control the workbook tab order.
- Add `archive_dir` under `output` to send rotated runs to a network share.
- Change `output.keep_latest_runs` from the default 10.
- Override chart bands under `charts.compliance_trend.bands`.

The schema is documented in the root `config.example.yaml`. Use that file as the
reference; do not invent new keys — the engine ignores unknown ones.

## EA recipes

### FileVault

```yaml
custom_eas:
  - name: "FileVault Status"
    column: "FileVault 2 - Status"
    type: boolean
    true_value: "Encrypted"
```

`true_value` is matched case-insensitively. Devices with no value are counted as
"Unknown" in the resulting sheet.

### mSCP audit plist

```yaml
custom_eas:
  - name: "mSCP NIST 800-53r5 Failures"
    column: "mSCP - NIST 800-53r5 Failure Count"
    type: percentage
    warning_threshold: 5
    critical_threshold: 15
```

Replace the column name with whatever EA your tenant uses to surface the count from
`/Library/Managed Preferences/org.<org>_*.audit.plist`. Thresholds are failure counts,
not percentages despite the type name.

### CrowdStrike Falcon

```yaml
security_agents:
  - name: "CrowdStrike Falcon"
    column: "CrowdStrike Falcon - Status"
    connected_value: "Installed"
```

`connected_value` is a case-insensitive substring match, so `Installed`, `Installed
and Running`, and `Installed (Connected)` all count as connected.

### Date EA (e.g. cert expiry)

```yaml
custom_eas:
  - name: "User Cert Expiry"
    column: "User Certificate - Expiry Date"
    type: date
    warning_days: 30
```

Devices within `warning_days` of expiry are highlighted yellow; expired devices are
highlighted red.

## Validating after edits

After any manual edit, open the Health Audit tab. Each Custom EA is listed with its
column name and detected type. Any column missing from cached data is flagged red with
the exact scaffold line to fix it. Do not generate a report against a red Health Audit
— rows will silently come back empty.
