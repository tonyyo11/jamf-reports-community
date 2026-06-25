# Installation

This page covers installing the macOS app and `jamf-cli`.

## Requirements

| Component | Requirement |
|---|---|
| macOS | 14 (Sonoma) or later — to run the app |
| jamf-cli | v1.16.1 or later — optional; powers live collection |
| Xcode | 16 or later — only needed to build the app from source |

`jamf-cli` is optional. The app works from a Jamf Pro CSV export
and cached snapshots with no jamf-cli installed — jamf-cli adds live collection and the
API-driven dashboards.

## Install the macOS app

The macOS app is the recommended way to use this project.

**Download a build.** Get the latest `JamfReports.app` from the
[Releases page](https://github.com/tonyyo11/jamf-reports-community/releases). Release
builds are ad-hoc signed for local use.

**Or build from source.** The app is a SwiftPM project (no `.xcodeproj`):

```bash
cd app
./build-app.sh release      # → app/build/JamfReports.app
```

Full build instructions — including Developer ID signing
for wider distribution — are in
[`app/README.md`](https://github.com/tonyyo11/jamf-reports-community/blob/main/app/README.md).

## Install jamf-cli

`jamf-cli` is Jamf's official command-line interface for Jamf Pro. Install it with
Homebrew:

```bash
brew install Jamf-Concepts/tap/jamf-cli
```

Pre-built binaries are also available from the
[jamf-cli releases](https://github.com/Jamf-Concepts/jamf-cli/releases).

Authenticate against your Jamf Pro instance:

```bash
jamf-cli pro setup --url https://your-instance.jamfcloud.com
```

Follow the prompts. `jamf-cli pro setup` can create an API client for you — choose the
**read-only** scope when offered, since this project only reads data. Credentials are
stored in the macOS keychain, not in shell history.

If you use the Jamf Platform API, jamf-cli also offers `jamf-cli platform setup`, which
creates a Platform Gateway profile that enables both the Pro and Platform API command
sets. When you run multiple Jamf Pro instances, give each its own profile and select it
with `jamf-cli -p <profile>`.

## Jamf Pro API permissions

If you create the API role yourself rather than letting `jamf-cli pro setup` do it, the
client needs only read access. A dedicated role with these privileges is enough:

| Resource | Privilege |
|---|---|
| Computers | Read |
| Mobile Devices | Read |
| Mobile Device Configuration Profiles | Read |
| Computer Extension Attributes | Read |
| Policies | Read |
| Patch Management | Read |
| Mobile Device Applications | Read |
| Managed Software Updates | Read |
| Computer Groups | Read |

This is the minimum read-only set the project's reports need. jamf-cli itself does not
publish a canonical required-privileges list — Jamf's
[Privileges and Deprecations](https://developer.jamf.com/jamf-pro/docs/privileges-and-deprecations)
reference is the authoritative privilege catalog. Do not use a full-administrator API
client for scheduled reporting.

**Exception: the `patch-managed` command.** The `patch-managed` CLI command issues PATCH
writes to bulk-update managed/unmanaged status on computers. It requires additional
privilege: **Computers → Update**. This is the only write-path command in the project; it
is optional and disabled by default. If you use `patch-managed`, create a separate API
role granted to read the initial inventory plus write to Computers, and use that credential
only for that command.

## Verify

Confirm a profile resolves and authenticates:

```bash
jamf-cli config validate -p <profile>
```

A clean exit means the app and CLI can collect live data. If `jamf-cli` is missing or
unauthenticated, both still run from CSV exports and cached snapshots — the live
dashboards are simply skipped.

## Next

- Continue to [App Onboarding](02-App-Onboarding).
