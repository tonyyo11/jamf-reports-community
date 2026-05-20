# Release Notes Summary

Build snapshot for JamfReports worktree (big-flies-care-zd3bz, May 2026).
Operator-facing summary of current capabilities and known changes.

## What's in the box

**jamf-cli-first orchestration.** The native app wraps `jamf-cli` to pull data from
Jamf Pro, caches JSON on disk, and renders Excel, HTML, and PDF reports without
requiring Python on your Mac. Every API call is observable in the Run History tab
and logs.

**Five shipping templates.** Executive (monthly leadership), Operational (daily NOC),
Compliance (auditor), Asset (lifecycle), and Security Posture (weekly review).
Pick one in the Generated tab; the engine selects the relevant sheets automatically.

**Scheduled background collection.** Three opt-in LaunchAgent tiers (HOT every 15 min,
WARM every 4 hours, COLD every 24 hours) keep cached data fresh. Configure per
profile from the Schedules tab.

**Customization Wizard.** Build a working `config.yaml` from your live jamf-cli data
without a CSV export. Discover Extension Attributes, set thresholds, pick sheets,
preview impact on live counts.

**Trends charts.** The Trends tab plots 26-week historical snapshots of OS adoption,
compliance posture, and device state over time. Archive dated CSV snapshots to
`snapshots/computers/csv/` to enable multi-week trend lines.

**Exceptions ledger.** Document policy waivers and exemptions as a structured list
in `config.yaml`. The HTML report includes an Exceptions sheet with approval dates
and justifications.

## Known changes from Phase 3 baseline

**Tab terminology.** The data-access tab is called "Data Sources" (not "Workspace").
Configuration is split across "Config", "Customize", and "Data Sources" tabs; the
docs previously described a single "Workspace" tab with subtabs.

**Health Check → Health Audit.** The compliance validation screen is labeled "Health
Audit" in the UI (was "Health Check" in earlier planning).

**No UI tab reorg.** An earlier design proposed a tab reorg (Tab IA) with Information,
Activity, and Administration tiers. This was reverted. Current tab order: Overview →
Fleet Overview → Devices → Device Lookup → Trends → Health Audit → Generated →
Schedules → Run History → Config → Customize → Data Sources → Backups → Settings.

## Security hardening

**pip lock files.** The bundled Python runtime installs dependencies with `--require-
hashes` to enforce integrity of all transitive deps.

**Sanitized HTML output.** Chart titles, device names, EA values, and user input are
HTML-escaped before embedding in HTML reports. JavaScript is disabled in PDF
rendering.

**Path canonicalization.** All file operations are bounded to `~/Jamf-Reports` and
standard user folders. Symlink traversal is blocked by canonicalizing with
trailing-`/` prefix check.

## Where to look for what

| Item | Location |
|------|----------|
| Configuration | `~/Jamf-Reports/<profile>/config.yaml` |
| Cached JSON | `~/Jamf-Reports/<profile>/jamf-cli-data/` |
| Generated reports | `~/Jamf-Reports/<profile>/Generated Reports/` |
| CSV snapshots | `~/Jamf-Reports/<profile>/snapshots/computers/csv/` |
| Trend data | `~/Jamf-Reports/<profile>/snapshots/computers/summaries/` |
| Automation logs | `~/Library/Logs/JamfReports/<label>/` |
| LaunchAgent plists | `~/Library/LaunchAgents/com.jamfreports.*.plist` |

## Next steps

See the onboarding docs to set up your first profile, enable background tiers, or
troubleshoot a failure.
