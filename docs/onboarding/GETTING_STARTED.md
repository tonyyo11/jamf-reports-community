# Getting Started with JamfReports

This guide walks a new operator from a blank Mac to a generated report. It assumes you have
admin credentials for at least one Jamf Pro instance.

## What this is

JamfReports is a native macOS app that orchestrates `jamf-cli` to pull data from a Jamf Pro
instance, caches that data on disk, and renders Excel, HTML, and PDF reports from it.

## What this is NOT

The app does not replace `jamf-cli`. It composes it. Every Jamf Pro API call goes through
the `jamf-cli` binary on your Mac. If `jamf-cli` cannot reach your tenant, the app cannot
either. Authentication, token refresh, and tenant configuration all live inside `jamf-cli`.

## Prerequisites

- macOS 14 (Sonoma) or later. The app is built against the macOS 14 SDK with Swift 6.
- `jamf-cli` installed and on your PATH:

  ```bash
  brew install jamf-cli
  jamf-cli --version
  ```

- Network reach to your Jamf Pro instance and a service account with sufficient privileges
  to read computers, mobile devices, policies, profiles, patch policies, and update plans.
- About 200 MB of free disk per profile for cached JSON snapshots and generated reports.

If `which jamf-cli` returns nothing after the brew install, restart your terminal so the
new `PATH` entry is picked up, then relaunch the app.

## First launch

1. Open `JamfReports.app`. The Onboarding sheet appears automatically when no profiles
   exist on disk.
2. Pick a profile slug. The slug becomes a folder under `~/Jamf-Reports/<profile>/` and
   must match `^[a-z0-9][a-z0-9._-]*$`. Use a short, descriptive name such as `prod` or
   `cbp-prod`. Do not include spaces, capitals, or slashes.
3. Enter the Jamf Pro server URL (for example `https://yourorg.jamfcloud.com`).
4. Enter the API client ID. The secret is requested on the next step and is passed to
   `jamf-cli` via stdin. The app does not persist the secret; `jamf-cli` writes the
   resulting OAuth token to its own keychain entry.
5. Click Authenticate. The Onboarding flow runs `jamf-cli auth login` against the new
   profile and reports success or a redacted error.
6. The first collect run kicks off automatically. It populates
   `~/Jamf-Reports/<profile>/jamf-cli-data/` with cached JSON snapshots so the GUI has
   something to render before the next scheduled refresh.

## Where data lives

```
~/Jamf-Reports/<profile>/
├── config.yaml                     # mappings + thresholds (created from a template)
├── jamf-cli-data/                  # cached JSON from jamf-cli (overview, computers, ...)
├── snapshots/
│   └── computers/
│       ├── csv/                    # archived CSV snapshots (optional)
│       └── summaries/              # summary.json per run (feeds Trends tab)
├── Generated Reports/              # produced .xlsx, .html, .pdf artifacts
├── automation/
│   └── logs/                       # per-run stdout/stderr from background tiers
└── archive/                        # rotated older runs once keep_latest_runs is exceeded
```

Everything for a tenant is under one folder. To migrate a profile to another Mac, copy the
folder and re-run `jamf-cli auth login --profile <slug>`.

## First report

1. Switch to the **Generated** tab. It is the single primary action surface for
   generating artifacts.
2. Pick a template from the picker. The default is **Executive**; see
   [REPORT_TEMPLATES.md](../templates/REPORT_TEMPLATES.md) for what each one includes and
   who it is for.
3. Choose an output format (XLSX, HTML, or PDF) and click **Generate**.
4. The Run History tab streams stdout/stderr live while the engine works. When the
   run finishes, the artifact is revealed in `Generated Reports/`.

The first generation runs entirely on cached jamf-cli JSON. No CSV export is required.
If you have a Jamf Pro CSV export and want CSV-only sheets (Stale Devices, Security
Controls, Custom EAs), drop it into the Data Sources tab and re-generate.

## Mental model

```
+-----------+      +-----------------+      +-----------+      +-------------+
|   You     | ---> | JamfReports.app | ---> | jamf-cli  | ---> | Jamf Pro    |
+-----------+      +-----------------+      +-----------+      +-------------+
                          |                       |
                          v                       v
                  ~/Jamf-Reports/<p>/      OAuth token in
                   cached JSON, reports     jamf-cli keychain
```

The app is the orchestrator and renderer. `jamf-cli` is the engine that talks to your
Jamf Pro server. Cached JSON on disk is the contract between the two so the GUI is
responsive and the background refresh tiers do not block interactive work.

## Next steps

- [FIRST_RUN_CHECKLIST.md](FIRST_RUN_CHECKLIST.md) — printable checklist for a fresh
  install.
- [WITHOUT_CSV.md](WITHOUT_CSV.md) — run the app on a brand new tenant without a CSV
  export.
- [BACKGROUND_REFRESH.md](../operations/BACKGROUND_REFRESH.md) — enable the
  HOT/WARM/COLD collection tiers so the app keeps data fresh in the background.
- [TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md) — when something fails.
