# Jamf Reports

[![Latest release](https://img.shields.io/github/v/release/tonyyo11/jamf-reports-community?style=for-the-badge&labelColor=1f2328&logo=github&label=release)](https://github.com/tonyyo11/jamf-reports-community/releases/latest)
[![macOS 15+ on Apple silicon](https://img.shields.io/badge/macOS_15%2B-Apple_silicon-0071e3?style=for-the-badge&labelColor=1f2328&logo=apple)](#requirements)
[![Built with jamf-cli](https://img.shields.io/badge/built_with-jamf--cli-2d5ea2?style=for-the-badge&labelColor=1f2328)](https://github.com/Jamf-Concepts/jamf-cli)
[![License: MIT](https://img.shields.io/github/license/tonyyo11/jamf-reports-community?style=for-the-badge&labelColor=1f2328&color=3fb950)](LICENSE)

Fleet reporting for Jamf on your Mac: Excel, HTML and PDF reports, dashboards and history for
Jamf Pro, Jamf School and Jamf Protect. Read-only, through Jamf's jamf-cli.

![Jamf Reports: your fleet on one screen, a Security Score you define, history from daily snapshots, Excel, HTML, PDF and CSV reports, scheduled runs, read-only access through jamf-cli for Jamf Pro, Jamf School, Jamf Protect and the Platform API, and seven languages.](docs/images/readme/bento.png)

## What it is

Jamf Reports is a Mac app that turns your Jamf data into fleet reports and dashboards. It is for
Mac and iPad admins who run Jamf Pro or Jamf School and want recurring reports without building
their own pipeline. It reads Jamf through jamf-cli, Jamf's own command-line tool, and keeps
everything on your Mac.

The repository is `jamf-reports-community`. The app is featured in the
[jamf-cli Community Showcase](https://github.com/Jamf-Concepts/jamf-cli/wiki/Community-Showcase).

## What you get

- **Dashboards** for fleet health, security, compliance, patching, OS updates, policies and
  profiles, mobile devices and Jamf Protect. See
  [Dashboards](https://github.com/tonyyo11/jamf-reports-community/wiki/03-App-Dashboards).
- **Reports** as Excel workbooks, self-contained HTML, PDF and CSV, from a template or your own
  choice of sheets, with percentages to one decimal (`56.7%`) or as whole numbers (`57%`). See
  [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates).
- **History** from a daily snapshot: trend charts, and quarter or month reports with the start,
  end and change for each figure. See
  [Historical Trends](https://github.com/tonyyo11/jamf-reports-community/wiki/06-Historical-Trends)
  and [Period Reports](https://github.com/tonyyo11/jamf-reports-community/wiki/06c-Period-Reports).
- **A Security Score you define**: choose the controls and agents that count and how much each
  one weighs. See
  [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates).
- **Unattended runs** from one background item: daily collects, weekly device scans, reports on
  your schedule, and a Teams or Slack card when something needs you. See
  [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation)
  and [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust).
- **Several environments** side by side, each in its own workspace, and a shared team folder
  that several Macs can write to. See
  [Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations).
- **A command-line tool** in the same app, for scripting collects, reports and backups. See
  [Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line).
- **Seven languages** in the app: English, French, Spanish, German, Brazilian Portuguese,
  Italian and Japanese. Reports stay in English. See
  [Dashboards](https://github.com/tonyyo11/jamf-reports-community/wiki/03-App-Dashboards#language).

## How it works with Jamf

- **Read-only.** Jamf Reports never creates, changes or deletes anything in Jamf. Give it a
  read-only API role.
- **Through jamf-cli.** Every Jamf request goes through
  [jamf-cli](https://github.com/Jamf-Concepts/jamf-cli). jamf-cli stores the credentials in the
  macOS keychain; the app never saves a secret.
- **Products:** Jamf Pro (Jamf Cloud or on-premises), the Jamf Platform API, Jamf School and Jamf
  Protect. Jamf Security Cloud is planned.
- **Your data stays on your Mac**, in a workspace folder you choose, unless you choose a shared
  team folder.
- **Other connections** besides Jamf, each optional:
  - the [SOFA](https://sofa.macadmins.io) feed for the current macOS and iOS releases (can be
    turned off in `config.yaml`);
  - GitHub: one check a day for a new release of the app (can be turned off by configuration
    profile), and the jamf-cli update check and download when you use them;
  - a Teams or Slack webhook, only if you set one up;
  - a timestamp authority for signed report manifests, only if you set one up.

  AI insights are off by default and use Apple's on-device model, on the Mac. The full list is on
  [Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations).
- **Permissions** for each report area are on
  [Permissions & Access](https://github.com/tonyyo11/jamf-reports-community/wiki/13-Permissions-and-Access).
  Settings an organization can manage are on
  [Managed Preferences](https://github.com/tonyyo11/jamf-reports-community/wiki/14-Managed-Preferences),
  with example files in [`application_management/`](application_management).

## Requirements

| | |
|---|---|
| Mac | macOS Sequoia 15 or later, Apple silicon |
| jamf-cli | 1.29.0 or later |
| Jamf | Jamf Pro (Jamf Cloud or on-premises) or Jamf School. Jamf Protect is optional. |
| Access | A read-only API role or Jamf Account integration, see [Permissions & Access](https://github.com/tonyyo11/jamf-reports-community/wiki/13-Permissions-and-Access) |

## Install

**1. Install the app.** Download `JamfReports-<version>.pkg` or `JamfReports-<version>.dmg` from
the [latest release](https://github.com/tonyyo11/jamf-reports-community/releases/latest). Both
are signed with a Developer ID and notarized by Apple. The `.pkg` installs to `/Applications`
and suits deployment through Jamf Pro; the `.dmg` is for dragging the app in by hand. On an
Intel Mac, [build from source](app/README.md).

**2. Install jamf-cli.** Jamf Reports needs jamf-cli 1.29.0 or later:

```bash
brew install Jamf-Concepts/tap/jamf-cli
```

or use the installer from the [jamf-cli releases](https://github.com/Jamf-Concepts/jamf-cli/releases).
The app's first run checks for it.

## Your first report

1. Open Jamf Reports and choose how to connect: **Connect with Jamf Account** (recommended for
   Jamf Cloud), **Connect a Jamf Pro server**, **Connect Jamf School**, or **Try the demo
   first**.
2. Name the workspace, for example `prod`.
3. Sign in: a Jamf Account integration at the environment level, or a Jamf Pro API client for an
   on-premises server. jamf-cli saves the credentials in the keychain.
4. The app checks the connection, collects a first snapshot and builds a first report.
5. Open the report from **Generated**, or set up a schedule under **Automation**.

The full walkthrough is in
[Getting Started](https://github.com/tonyyo11/jamf-reports-community/wiki/00-Getting-Started).

## Deploy with Jamf Pro

- Upload the `.pkg` and install it with a policy.
- Install jamf-cli the same way, from its own `.pkg`.
- Set the app's preferences with a configuration profile for `com.tonyyo.jamfreports`: the
  workspace folder, the update check or the AI policy, for example. An example `.mobileconfig`
  and `.plist` files are in [`application_management/`](application_management), and every key
  is on [Managed Preferences](https://github.com/tonyyo11/jamf-reports-community/wiki/14-Managed-Preferences).
- Each user signs in to Jamf once, in the app. The credentials live in that user's keychain.

## Documentation

The [wiki](https://github.com/tonyyo11/jamf-reports-community/wiki) covers setup, every screen,
configuration, scheduling and troubleshooting. Good places to start:

- [Getting Started](https://github.com/tonyyo11/jamf-reports-community/wiki/00-Getting-Started)
  and [Installation](https://github.com/tonyyo11/jamf-reports-community/wiki/01-Installation)
- [Dashboards](https://github.com/tonyyo11/jamf-reports-community/wiki/03-App-Dashboards)
- [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates)
- [Jamf School](https://github.com/tonyyo11/jamf-reports-community/wiki/08-Jamf-School)
- [Diagnostics & Troubleshooting](https://github.com/tonyyo11/jamf-reports-community/wiki/09-Diagnostics-and-Troubleshooting)

Release history is in [`CHANGELOG.md`](CHANGELOG.md). For contributors: the build steps are in
[`app/README.md`](app/README.md), the tests in [`docs/testing.md`](docs/testing.md), and design
decisions and the threat model in [`docs/architecture/`](docs/architecture).

## Support

- Bugs and questions: [open an issue](https://github.com/tonyyo11/jamf-reports-community/issues/new/choose).
  The bug form asks for the app and jamf-cli versions.
- Ideas and how-to: [Discussions](https://github.com/tonyyo11/jamf-reports-community/discussions).
- To help with a bug, attach a diagnostic bundle (Settings › Generate diagnostic bundle now). It
  removes credentials and device details; see
  [Diagnostics & Troubleshooting](https://github.com/tonyyo11/jamf-reports-community/wiki/09-Diagnostics-and-Troubleshooting)
  for what it holds.
- Security problems: report them privately, as [`SECURITY.md`](SECURITY.md) describes.

## License and trademarks

MIT, see [`LICENSE`](LICENSE). The HTML report design is adapted from work by
[DevliegereM](https://github.com/DevliegereM).

"Jamf", "Jamf Pro", "Jamf School", "Jamf Protect", and the Jamf logo are trademarks or registered
trademarks of Jamf Software, LLC in the United States and other countries. This project is **not
affiliated with, endorsed by, or sponsored by Jamf Software, LLC**. See [`NOTICE.md`](NOTICE.md).
