# JamfReports Documentation

Operator-facing documentation for the JamfReports macOS app and its companion Python
CLI. Start with Getting Started, then jump to whichever section matches the task at
hand.

## Onboarding

- [GETTING_STARTED.md](onboarding/GETTING_STARTED.md) — install, first profile, first
  report, mental model.
- [FIRST_RUN_CHECKLIST.md](onboarding/FIRST_RUN_CHECKLIST.md) — printable one-page
  checklist for a fresh install.
- [WITHOUT_CSV.md](onboarding/WITHOUT_CSV.md) — running on a fresh tenant with no
  Jamf Pro CSV export, plus the Customization Wizard walkthrough.

## Templates and customization

- [REPORT_TEMPLATES.md](templates/REPORT_TEMPLATES.md) — the five shipping templates
  (Executive, Operational, Compliance, Asset, Security Posture), their audiences,
  cadences, and included sheets.
- [CUSTOMIZATION_GUIDE.md](templates/CUSTOMIZATION_GUIDE.md) — wizard walkthrough,
  post-wizard `config.yaml` edits, EA recipes (FileVault, mSCP, CrowdStrike, dates).

## Operations

- [RELEASE_NOTES_SUMMARY.md](operations/RELEASE_NOTES_SUMMARY.md) — current build
  capabilities, security hardening, known changes from earlier phases.
- [BACKGROUND_REFRESH.md](operations/BACKGROUND_REFRESH.md) — HOT/WARM/COLD
  LaunchAgent tiers, log locations, rotation, and `launchctl` inspection.
- [TROUBLESHOOTING.md](operations/TROUBLESHOOTING.md) — common failure modes
  (PATH, expired tokens, slug regex, full disk, `[skip]` lines) and recovery steps.

## Architecture

- [JAMF_CLI_FIRST.md](architecture/JAMF_CLI_FIRST.md) — why `jamf-cli` is the engine,
  how the app composes its calls, where data lives on disk, and the cache contract.

## Wiki (legacy)

The `docs/wiki/` directory contains the legacy GitHub Wiki content covering the
Python CLI workflow, Jamf Pro CSV setup, and Jamf School. The documents in this
INDEX supersede the wiki for the GUI app; the wiki remains current for the
standalone Python script.
