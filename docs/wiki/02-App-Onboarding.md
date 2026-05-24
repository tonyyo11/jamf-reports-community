# App Onboarding

The macOS app has a guided first-run flow that takes you from a blank Mac to a first
report. This page walks through it and the workspace it creates.

## Reaching onboarding

On first launch the app opens a **Welcome chooser** with two cards:

- **Connect Jamf Pro** — starts the onboarding flow.
- **Try the demo first** — loads the fictional "Meridian Health" tenant so you can explore
  every screen before connecting anything. Demo mode is not a real workspace; switch back
  to a real connection anytime from **Settings → jamf-cli → Demo mode**.

After the initial choice the chooser does not reappear. To set up additional tenants
later, open the **workspace switcher** at the bottom of the sidebar and choose **Add
workspace…**, or click **Settings → jamf-cli → Connections → Add connection**. Both
routes start the same onboarding flow.

## The seven-step flow

1. **Welcome** — a short intro to what onboarding will do.
2. **Install CLI** — the app checks that `jamf-cli` is installed and on `PATH`, and shows
   the `brew install Jamf-Concepts/tap/jamf-cli` command if it is not. See
   [Installation](01-Installation) for details.
3. **Workspace** — choose a profile name. The name becomes a folder under
   `~/Jamf-Reports/<profile>/` and must match `^[a-z0-9][a-z0-9._-]*$` — lowercase, no
   spaces. Pick something short like `prod`. This step also asks whether the Jamf Pro
   instance is on-prem or cloud, to seed the collection-cadence preset.
4. **Authenticate** — enter the Jamf Pro URL, API client ID, and client secret. The
   secret is passed to `jamf-cli` over a controlling TTY and cleared immediately; the app
   never persists it. `jamf-cli` stores the resulting token in the macOS keychain.
5. **Validate** — the app runs `jamf-cli config validate` against the new profile and
   reports success or a redacted error.
6. **CSV mapping** — optionally pick a Jamf Pro CSV export. The app scaffolds a
   `config.yaml` with best-guess column mappings from the export's headers. You can also
   **Skip for now** — the app writes a minimal config and works from `jamf-cli` data
   alone (see [Running without a CSV](#running-without-a-csv)).
7. **First report** — the app generates a first report so the dashboards have data to
   render. If the output looks off you can **Skip & finish setup** — the workspace is
   fully configured at this point and you can run reports later from the Reports tab.

![Onboarding — Connect to Jamf Pro](images/onboarding-authenticate.png)

## Where data lives

Each profile is a self-contained workspace under `~/Jamf-Reports/<profile>/`:

```text
~/Jamf-Reports/<profile>/
├── config.yaml          # column mappings, thresholds, scoring weights
├── jamf-cli-data/        # cached JSON snapshots from jamf-cli
├── snapshots/
│   └── computers/
│       ├── csv/          # archived CSV snapshots (optional)
│       └── summaries/    # summary.json per run — feeds the Trends screen
├── Generated Reports/    # produced .xlsx / .html / .pdf artifacts
├── automation/
│   └── logs/             # per-run logs from scheduled runs
└── archive/              # rotated older runs
```

Everything for one tenant is under one folder. To move a profile to another Mac, copy the
folder and re-authenticate with `jamf-cli pro setup` for that profile.

## First-run checklist

A quick tick-list for a fresh install:

- [ ] macOS 14 or later
- [ ] `jamf-cli` installed (`brew install Jamf-Concepts/tap/jamf-cli`)
- [ ] Jamf Pro URL, API client ID, and secret on hand
- [ ] `JamfReports.app` in `/Applications`, first launch past Gatekeeper
- [ ] Profile created through **Add workspace…** → onboarding
- [ ] Authentication succeeded (Validate step passed)
- [ ] First report generated and opened cleanly
- [ ] `~/Jamf-Reports/<profile>/jamf-cli-data/` contains JSON files

## Running without a CSV

A Jamf Pro CSV export is **optional**. With `jamf-cli` data alone the app renders Fleet
Overview, Security Posture, Compliance Posture, Patch Compliance, OS Updates, Policies &
Profiles, Extension Attributes, Mobile Fleet, and more — enough for every report
template.

A CSV export adds the sheets that depend on per-device export columns: Stale Devices,
per-device Security Controls, the Security Agents matrix, per-device compliance
failure lists, and custom Extension Attribute sheets. If your tenant has not configured
those EAs in Jamf Pro, a CSV cannot add them either. Drop a CSV in any time from the
**Data Sources** screen and regenerate.

## Next

- [Dashboards](03-App-Dashboards) — a tour of every screen.
- [Configuration & Templates](04-Configuration-and-Templates) — tune `config.yaml`.
