# README rewrite and feature bento (Jamf Marketplace listing)

Status: approved 2026-11-11 and drafted on this branch. As built: four demo-mode screens rendered
with the localization layout harness (English only, 1240 pt wide); the Protect tile is text with a
drawn severity list, so no NFR image is used. Branch `docs/readme-marketplace`
off `dev/2-12-0`.

## Goal

The README becomes the landing page for a Mac admin who has never heard of the app. It says what
the app is, who it is for, shows one image, and gets the reader installed and to a first report.
Everything else lives in the wiki and is linked. The README also answers the facts a Jamf
Marketplace reviewer looks for: read-only, how the app reaches Jamf, supported products,
permissions, managed preferences, support.

Today's README is 213 lines, 25 feature bullets and 10 badges. Target: about 120 lines, one image,
eight feature lines.

## Decisions for Tony

1. **Jamf Security Cloud.** The brief lists it as supported. The app on `dev/2-12-0` does not
   collect it: onboarding says "Jamf Security Cloud is not supported yet", and the `profiles:`
   slot for it is recorded only, for a later release. Recommendation: leave it out of the
   supported list and add one line, "Jamf Security Cloud: planned." Writing it as supported would
   not survive a reviewer who tries it.
2. **Title.** `# Jamf Reports` instead of `# jamf-reports-community`, with the repo name in the
   first sentence. Recommendation: yes. The app, the bundle and the Marketplace listing all use
   "Jamf Reports".
3. **Badges.** Keep four: latest release, macOS 15+ on Apple silicon, built with jamf-cli,
   license. Drop downloads, tests, last commit, stars, Swift 6 and Discussions (Discussions moves
   to the Support section).
4. **Screenshots.** The nine images in `docs/wiki/images/` date from 2.0 (May 2026) and show old
   screen names (Devices, Mobile Fleet), so none is reused. New shots, two ways to get them:
   - (recommended) Tony takes them in the running app in demo mode, window at about 1440 x 900,
     dark appearance, on the list below; the NFR Protect shot after the walkthrough fixes land.
   - I render demo-mode tabs headlessly with the localization layout harness
     (`JRC_L10N_LAYOUT=1 JRC_PREVIEW_OUT=<folder> swift test --filter LocalizationLayoutTests`).
     Fast, but it draws at the minimum supported width and an offscreen render can miss
     materials and charts, so this is a fallback to check in step 3, not the plan.
5. **Jamf Pro minimum version.** The partner checklist asks for minimum versions. The repo states
   none for Jamf Pro; the floor is whatever jamf-cli 1.29.0 supports. Recommendation: the
   requirements table says "Jamf Pro: any version jamf-cli 1.29.0 supports (Jamf Cloud or
   on-premises)" unless the endpoint and privilege session finds a real floor from NFR traffic.

6. **Repository description and topics.** Today: "Config-driven Jamf Pro fleet reporting —
   multi-sheet Excel workbooks from and jamf-cli data" (a word is missing, and it names Jamf Pro
   only). No topics are set. Candidates, each well under GitHub's 350-character limit:
   - A (**chosen 2026-11-11, applied to GitHub with the twelve topics below**): "Fleet reporting for Jamf on your Mac: Excel, HTML and PDF reports,
     dashboards and history for Jamf Pro, Jamf School and Jamf Protect. Read-only, through
     Jamf's jamf-cli."
   - B: "A native macOS app that turns Jamf Pro, Jamf School and Jamf Protect data into Excel
     workbooks, HTML reports and trend dashboards. Read-only, built on jamf-cli."
   - C: "Jamf Reports: read-only fleet reports and dashboards for Jamf Pro, Jamf School and Jamf
     Protect, from a Mac app built on jamf-cli."

   Topics: `jamf`, `jamf-pro`, `jamf-school`, `jamf-protect`, `jamf-cli`, `macos`, `macadmins`,
   `swiftui`, `fleet-management`, `reporting`, `excel`, `mdm`.

   Whichever line Tony picks becomes the README's opening line too, so the two match. Applied
   with `gh repo edit` only after he picks.

## Proposed README structure

```
# Jamf Reports
  4 badges
  One-line pitch
  Bento image (docs/images/readme/bento.png)

## What it is            — 3 sentences: what, who, how
## What you get          — 8 one-line features, each linking to its wiki page
## How it works with Jamf — read-only, jamf-cli, products, data, outbound connections
## Requirements          — table
## Install               — app, then jamf-cli
## Your first report     — 5 steps
## Deploy with Jamf Pro  — pkg by policy, configuration profile, jamf-cli
## Documentation         — wiki links, grouped
## Support               — issues, discussions, diagnostic bundle, security reports
## License and trademarks — MIT, NOTICE.md, credits
```

### What it is (draft)

> Fleet reporting for Jamf on your Mac: Excel, HTML and PDF reports, dashboards and history for
> Jamf Pro, Jamf School and Jamf Protect. Read-only, through Jamf's jamf-cli.
>
> Jamf Reports is a Mac app that turns your Jamf data into fleet reports: Excel workbooks, HTML
> and PDF reports, and dashboards with history. It is for Mac and iPad admins who run Jamf Pro or
> Jamf School and want recurring reports without building their own pipeline. It reads Jamf
> through Jamf's own command-line tool, jamf-cli, and keeps everything on your Mac.
>
> Featured in the jamf-cli Community Showcase.

### What you get (draft, eight lines)

- **Dashboards** for fleet health, security, compliance, patching, OS updates, policies and
  profiles, mobile devices and Jamf Protect. → 03-App-Dashboards
- **Reports** as Excel workbooks, self-contained HTML, PDF and CSV, from templates or your own
  choice of sheets. → 04-Configuration-and-Templates
- **History** from a daily snapshot, with trend charts and quarter or month reports that show
  the start, end and change. → 06-Historical-Trends, 06c-Period-Reports
- **A Security Score you define**: pick the controls and agents that count and how much each one
  weighs. → 04-Configuration-and-Templates
- **Unattended runs** from one background item: daily collects, weekly device scans, reports on
  your schedule, and a Teams or Slack card when something needs you. → 05-Scheduling-and-Automation,
  05b-Automation-Trust
- **Several environments** side by side, each in its own workspace, and a shared team folder
  several Macs can write to. → 10-Security-and-Operational-Considerations
- **A command-line tool** in the same app for scripting collects, reports and backups.
  → 07-Command-Line
- **Seven languages** in the app (English, French, Spanish, German, Brazilian Portuguese, Italian,
  Japanese). Reports stay in English. → 03-App-Dashboards

### How it works with Jamf (draft)

> - **Read-only.** Jamf Reports never creates, changes or deletes anything in Jamf. Use a
>   read-only API role.
> - **Through jamf-cli.** Every Jamf request goes through
>   [jamf-cli](https://github.com/Jamf-Concepts/jamf-cli), Jamf's own command-line tool. jamf-cli
>   stores the credentials in the macOS keychain; the app never saves a secret.
> - **Products:** Jamf Pro (Jamf Cloud or on-premises), the Jamf Platform API, Jamf School and
>   Jamf Protect. Jamf Security Cloud: planned. *(pending decision 1)*
> - **Your data stays on your Mac**, in a workspace folder you choose.
> - **Other connections**, each optional: the SOFA feed for current macOS and iOS versions
>   (can be skipped in `config.yaml`), a daily check for a new release on GitHub (can be turned
>   off by profile), and a Teams or Slack webhook only if you set one up. AI insights, off by
>   default, run on the Mac with Apple's on-device model.
> - Permissions per report: [Permissions & Access](wiki 13). Settings an organization can manage:
>   [Managed Preferences](wiki 14) and the examples in [`application_management/`](application_management).

### Requirements (draft)

| | |
|---|---|
| Mac | macOS Sequoia 15 or later, Apple silicon |
| jamf-cli | 1.29.0 or later |
| Jamf | Jamf Pro (Jamf Cloud or on-premises) or Jamf School; Jamf Protect optional |
| Access | A read-only API role or Jamf Account integration ([Permissions & Access](wiki 13)) |

No "tracked version" line: the README, wiki and `.jamf-cli-tracked-version` disagree today
(1.33, 1.34, 1.36), and a reader only needs the floor.

### Install (draft)

> **1. Install the app.** Download `JamfReports-<version>.pkg` or `.dmg` from the
> [latest release](releases/latest). Both are signed with a Developer ID and notarized by Apple.
> The `.pkg` installs to `/Applications` and suits deployment through Jamf Pro; the `.dmg` is for
> dragging the app in by hand. Intel Macs can [build from source](app/README.md).
>
> **2. Install jamf-cli.** Jamf Reports needs jamf-cli 1.29.0 or later:
>
> ```bash
> brew install Jamf-Concepts/tap/jamf-cli
> ```
>
> or use the installer from the [jamf-cli releases](https://github.com/Jamf-Concepts/jamf-cli/releases).
> The app's first run checks for it.

### Your first report (draft)

> 1. Open Jamf Reports. Choose **Connect Jamf Pro**, **Connect Jamf School**, or **Try the demo
>    first**.
> 2. Name the workspace, for example `prod`.
> 3. Sign in: a Jamf Account integration at the environment level for Jamf Cloud, or a Jamf Pro
>    API client for on-premises. jamf-cli saves the credentials in the keychain.
> 4. The app checks the connection, collects a first snapshot and builds a first report.
> 5. Open it from **Reports**, or set up a schedule under **Automation**.
>
> The full walkthrough: [Getting Started](wiki 00).

### Deploy with Jamf Pro (draft)

> - Upload the `.pkg` and install it with a policy.
> - Install jamf-cli the same way, from its own `.pkg`.
> - Set app preferences with a configuration profile for `com.tonyyo.jamfreports`, for example
>   the workspace folder, the update check or the AI policy. An example `.mobileconfig` and
>   `.plist` files are in [`application_management/`](application_management); every key is on
>   [Managed Preferences](wiki 14).
> - Each user still signs in to Jamf once, in the app; credentials live in that user's keychain.

### Support (draft)

> - Bugs and questions: [GitHub issues](issues/new/choose). The bug form asks for the app and
>   jamf-cli versions.
> - Ideas and how-to: [Discussions](discussions).
> - Attach a diagnostic bundle (Settings › Generate diagnostic bundle now); it removes credentials
>   and device details. See [Diagnostics & Troubleshooting](wiki 09).
> - Security reports: [`SECURITY.md`](SECURITY.md).

### License and trademarks (draft)

> MIT, see `LICENSE`. Jamf, Jamf Pro, Jamf School and Jamf Protect are trademarks of Jamf; this
> project is not affiliated with or endorsed by Jamf. See `NOTICE.md`. The HTML report design is
> adapted from work by DevliegereM (plain link to the profile, no mention).

The trademark sentence will be copied from `NOTICE.md` word for word in step 3, not paraphrased.

## What moves out of the README

| README block today | Where it goes | State |
|---|---|---|
| Dashboards (four groups) | 03-App-Dashboards | already there |
| Highlights: Security Score, security policy | 04-Configuration-and-Templates | already there |
| Highlights: hand-edited config.yaml | 04-Configuration-and-Templates | already there; check the wording matches |
| Highlights: Trends, period reports, patch velocity | 06, 06c, 06b | already there |
| Highlights: shared workspaces | 10-Security-and-Operational-Considerations | already there |
| Highlights: health strip, alerts, dead-man switch | 05b-Automation-Trust | already there |
| Highlights: automation policy, report groups, notifications | 05-Scheduling-and-Automation | already there |
| Highlights: readable backup diffs | 03-App-Dashboards (Backups) | check in step 3, add if missing |
| Highlights: languages | 03-App-Dashboards | already there |
| Highlights: AI insights | 03b-AI-Insights | already there |
| Highlights: multi-baseline mSCP | 04, 06 | already there |
| First run and multiple tenants | 00-Getting-Started, 02-App-Onboarding | already there |
| Build from source | app/README.md, 01-Installation | already there |
| Command line, `html.with_workbook`, CSV folder | 07-Command-Line | already there |
| OS currency (SOFA), patch release dates | 04, 06b, 10 | already there |
| Diagnostic bundle redaction limits | 09-Diagnostics-and-Troubleshooting | **add on this branch**, corrected (below) |
| Docs list: `docs/testing.md`, `docs/architecture/` | Documentation section, one line for contributors | stays, shortened |

Nothing is dropped that is not already on a wiki page or added to one in this branch. All 22 wiki
pages are live, so every link resolves today; the wiki copy of any page this branch edits needs
Tony's push.

## Stale facts found (fixed on this branch)

- README: "the profile slug and schedule labels are not redacted" in diagnostic bundles. Since
  2.11 the bundle replaces the workspace name in file text, log file names and the zip name.
  The limit that still holds is IPv4-only address redaction. 09 gets the corrected note.
- README: "older releases from v1.18.0 still run, with a warning". Since 2.11 1.29.0 is the only
  floor.
- README and 00/01: "jamf-cli is optional". It is the one dependency; without it the app shows
  only demo mode or cached data. Reword to "required".
- 01-Installation: "Release builds are ad-hoc signed for local use". They are Developer ID signed
  and notarized.
- 00-Getting-Started step 4: the first-launch chooser has four cards (Connect with Jamf Account,
  Connect a Jamf Pro server, Connect Jamf School, Try the demo first), not three. (The sidebar tab
  really is "Generated", so step 7 stays.)
- Tracked jamf-cli version: 1.33 (README), 1.34 (00, 01), 1.36 (`.jamf-cli-tracked-version`).
  The README drops it; 00 and 01 get the floor only.

These wiki edits go in the same branch; the wiki push is Tony's.

## The bento

One PNG, 1600 x 900 drawn at 2x (3200 x 1800), in the style of the 2.11 release bento: dark tiles,
22 px corners, the app's teal, gold and orange, mixed tile sizes, some text only. Built as an HTML
page from the 2.11 template, rendered with WebKit to PNG.

Evergreen: the centre tile carries the name and a tagline, no version number, so it does not
go stale with each release.

Grid (6 columns x 4 rows):

```
"overview overview brand  brand  readonly products"
"overview overview brand  brand  score    score   "
"trends   trends   reports runs  runs     protect "
"trends   trends   langs   runs  runs     protect "
```

| Tile | Size | Copy | Visual |
|---|---|---|---|
| brand | 2 x 2 | **Jamf Reports** / "Fleet reports for Jamf, built on your Mac." | App icon (current icon; swapped if the new icon lands first) |
| overview | 2 x 2 | **Your fleet on one screen** / "Devices, stability, encryption and OS versions at a glance." | Screenshot: Overview, demo mode, score cards row |
| readonly | 1 x 1 | Text only, big gold type: **Read-only** / "Everything goes through Jamf's jamf-cli." | none |
| products | 1 x 1 | Text only: **Jamf Pro · Jamf School · Jamf Protect · Platform API** | product chips |
| score | 2 wide x 1 | **A score you define** / "Pick the controls and agents that count." | Screenshot: Security Posture, demo mode, score ring and control KPIs |
| trends | 2 x 2 | **History, not just today** / "Daily snapshots, trend charts, quarter reports." | Screenshot: Trends, demo mode, 12-week range |
| reports | 1 x 1 | Text only: **Excel · HTML · PDF · CSV** / "On demand or on a schedule." | format chips |
| runs | 2 x 2 | **Schedules you set** / "Collect, report or back up on your own cadence, with each run's next time and last result." | Screenshot: Scheduled Runs (hand-built schedules, automation policy off), demo mode, `scheduled-runs.png` |
| langs | 1 x 1 | Text only, big teal type: **7 languages** / "Reports stay in English." | none |
| protect | 1 wide x 2 tall | **Jamf Protect** / "Alerts and computers, matched to your Jamf Pro Macs." | Drawn severity list (High, Medium, Low), no screenshot |

Nine tiles. Four screenshots, all demo mode.

- The NFR Protect shot is taken after the walkthrough fixes land, since the current screens
  show wrong counts.
- Before it is used: blur the tenant name wherever it shows (hostnames, the workspace chip),
  remove the Wi-Fi name, and show no browser chrome and no personal names. The fake acme.org
  users and device details can stay.
- If no clean NFR shot is ready, the protect tile becomes text only and the bento ships with
  four screenshots.

Files committed (new folder, so the wiki images stay as they are):

- `docs/images/readme/bento.png` — the image the README shows.
- `docs/images/readme/bento.html` — its source, so the next update edits text, not pixels.
- `docs/images/readme/<screen>.png` — the four crops the HTML references, and `icon.png`.

Alt text: one sentence listing the tiles' headings, so a screen reader gets the same eight claims.

## Steps after approval

1. Apply Tony's answers to the six decisions.
2. Get the screenshots (Tony's demo-mode set, or the harness fallback), crop, check each NFR
   image for the items above.
3. Build `bento.html`, render it to PNG, check it at full size and at 50%.
4. Write the README from the drafts above; copy the `NOTICE.md` sentence word for word.
5. Fix the stale facts in 00, 01 and 09; add the redaction note to 09.
6. Grep the new README and wiki edits for hype words, `@` mentions, local paths and VM names.
7. Commit (one commit for the README and bento, one for the wiki fixes) and push the branch. No
   PR, no wiki push without Tony's go-ahead.
8. Once Tony picks a description, run `gh repo edit --description` and `--add-topic` with it.
