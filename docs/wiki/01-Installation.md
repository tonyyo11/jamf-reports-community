# Installation

This page covers installing the macOS app and `jamf-cli`.

## Requirements

| Component | Requirement |
|---|---|
| macOS | macOS Sequoia 15 or later — to run the app |
| jamf-cli | v1.18.0 or later — optional; powers live collection (v1.19.0+ recommended for partial-failure handling; the project tracks v1.30.0) |
| Xcode | 16 or later — only needed to build the app from source |
| Architecture | Apple silicon (arm64) — the prebuilt `.pkg`/`.dmg` are arm64-only; Intel Macs build from source |

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

On jamf-cli 1.29.0 and later, `pro setup` first asks whether to use an API client you
already hold (the default) or to create one from a Jamf Pro account. Prefer an existing
client: Jamf plans to remove local, SAML and LDAP administrator sign-in on cloud-hosted
instances (estimated for the second half of 2027), and the create path depends on it.

If you use the Jamf Platform API, jamf-cli also offers `jamf-cli platform setup`, which
creates a Platform Gateway profile that enables both the Pro and Platform API command
sets. When you run multiple Jamf Pro instances, give each its own profile and select it
with `jamf-cli -p <profile>`.

## Jamf Pro API permissions

If you create the API role yourself rather than letting `jamf-cli pro setup` do it, the
client needs read access only. [Permissions & Access](https://github.com/tonyyo11/jamf-reports-community/wiki/13-Permissions-and-Access#permissions-by-report-area)
lists the privileges each report area needs, both for a direct Jamf Pro connection and for a
Jamf Platform API integration. Grant the areas you report on. Jamf's
[Privileges and Deprecations](https://developer.jamf.com/jamf-pro/docs/privileges-and-deprecations)
reference is the authoritative privilege catalog. Do not use a full-administrator API client
for scheduled reporting.

Nothing in JamfReports writes to Jamf, so no role needs a create, update or delete privilege.
When a privilege is missing, that source fails and the rest of the collect still lands. Run
History and the health strip name the missing privilege from jamf-cli's error. The hourly
automatic retry skips that source, since retrying cannot help; scheduled runs and **Collect now**
still try it, so it fills in once the role has the privilege.

## Verify

Confirm a profile resolves and authenticates:

```bash
jamf-cli config validate -p <profile>
```

A clean exit means the app and CLI can collect live data. If `jamf-cli` is missing or
unauthenticated, both still run from CSV exports and cached snapshots — the live
dashboards are simply skipped.

## Next

- Continue to [App Onboarding](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding).
