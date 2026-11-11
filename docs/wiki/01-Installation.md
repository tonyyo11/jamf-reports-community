# Installation

This page covers installing the macOS app and `jamf-cli`.

## Requirements

| Component | Requirement |
|---|---|
| macOS | macOS Sequoia 15 or later — to run the app |
| jamf-cli | v1.29.0 or later — required for collection (collect, backup and scheduled runs stop on an older one) |
| Xcode | 16 or later — only needed to build the app from source |
| Architecture | Apple silicon (arm64) — the prebuilt `.pkg`/`.dmg` are arm64-only; Intel Macs build from source |

`jamf-cli` is required: every collect, backup and scheduled collect goes through it. Without
it the app can only show demo mode, or build reports from snapshots already in a workspace.

## Install the macOS app

The macOS app is the recommended way to use this project.

**Download a build.** Get the latest `JamfReports-<version>.pkg` or `.dmg` from the
[Releases page](https://github.com/tonyyo11/jamf-reports-community/releases). Release
builds are signed with a Developer ID and notarized by Apple: the `.pkg` installs to
`/Applications` and suits deployment through Jamf Pro, and the `.dmg` is for dragging the app in
by hand.

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

Authenticate against your Jamf Pro instance. For Jamf Cloud, jamf-cli recommends the
Jamf Platform API, and `jamf-cli platform setup` is its setup command:

```bash
jamf-cli platform setup --profile-name <your profile>
```

Create the integration in Jamf Account first, at the **environment** level (tenant level is
the legacy choice; an organization-level integration reaches only Jamf Account and cannot
report). The setup creates a Platform Gateway profile that enables both the Pro and Platform
API command sets. Setup stores the credentials in the macOS keychain through `jamf-cli`, not in shell history.

For an on-premises or GovCloud server, or when you have no Jamf Account integration, use a
direct Jamf Pro profile:

```bash
jamf-cli pro setup --url https://your-instance.jamfcloud.com --profile-name <your profile>
```

On jamf-cli 1.29.0 and later, `pro setup` first asks whether to use an API client you
already hold (the default) or to create one from a Jamf Pro account. Prefer an existing
client with a read-only API role you made: the create path depends on local, SAML and LDAP
administrator sign-in, which Jamf plans to remove on cloud-hosted instances (estimated for
the second half of 2027), and only the create path offers a scope choice.

When you run multiple Jamf Pro instances, give each its own profile and select it with
`jamf-cli -p <profile>`. jamf-cli suggests keeping a direct (oauth2) profile beside a gateway
profile, for the commands the gateway refuses. Jamf Reports collects each fleet once: when
both reach the same Jamf Pro, setup proposes one workspace for the pair, named after the
direct profile, with the Platform API profile as its Platform API profile.

## Jamf Pro API permissions

If you create the API role yourself rather than letting `jamf-cli pro setup` create it, the
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
unauthenticated, nothing new is collected: the app and CLI can only build reports from
snapshots already in the workspace.

## Next

- Continue to [App Onboarding](https://github.com/tonyyo11/jamf-reports-community/wiki/02-App-Onboarding).
