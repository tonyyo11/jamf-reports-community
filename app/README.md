# Jamf Reports: macOS App

A native SwiftUI macOS app for fleet reporting against Jamf Pro and Jamf School. It
collects data through `jamf-cli`, generates Excel and HTML reports, runs scheduled
collection from one bundled background item, and tracks fleet health on a Historical
Trends screen. It is the recommended interface for the
[`jamf-reports-community`](https://github.com/tonyyo11/jamf-reports-community) project.

This is a SwiftPM project, not a hand-rolled `.xcodeproj`. Open `Package.swift` in
Xcode for previews and runtime, or build from the command line with `swift build`.

For architecture, services, config keys and conventions, read
[`CLAUDE.md`](../CLAUDE.md) at the repo root. Operator documentation is in the
[project wiki](https://github.com/tonyyo11/jamf-reports-community/wiki).

## Requirements

- **Runs on:** macOS Sequoia 15 or later, Apple silicon. Intel Macs build from source.
- **Builds with:** Swift 6 (Xcode 16.4 is the CI floor). Swift 6.4 (Xcode 27) adds the
  AI Insights code for macOS 27.
- Reports are produced by the native Swift `ReportEngine`. There is no Python in the
  report path and none is bundled.

## Quick start

```bash
cd app
swift build                        # validates the package compiles
swift run JamfReports              # launches the app (debug build)
```

To open in Xcode for previews and the full runtime:

```bash
open Package.swift
```

SwiftPM emits a bare executable, so for the Dock icon and normal window behaviour
build an app bundle:

```bash
cd app
./build-app.sh release             # -> app/build/JamfReports.app
open build/JamfReports.app
```

An unbundled `swift run` build cannot register the background item, because
`SMAppService` needs the bundled app.

## Tests

```bash
cd app
swift build --build-tests
swift test
```

Tests live in `Tests/JamfReportsTests/`. They never launch a real `jamf-cli`.

## Demo data

Demo mode shows a fictional organization, Meridian Health, from `DemoData` in
`Sources/JamfReports/Models/`. It reads no workspace and runs no `jamf-cli`.

## Distribution

- `./build-app.sh release` signs with a Developer ID Application identity from the
  keychain (`TEAM_ID` picks one, `SIGNING_IDENTITY` names it), then notarizes and
  staples with `xcrun notarytool` and `xcrun stapler`. Notarization authenticates with
  the `JamfReports-Notary` keychain profile (`xcrun notarytool store-credentials`), or
  with an App Store Connect API key through `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and
  `NOTARY_ISSUER`.
- With no Developer ID identity it falls back to ad-hoc signing (`codesign -s -`) and
  skips notarization. That build suits the Mac that built it; Gatekeeper blocks it on
  others.
- With an identity but no notary credentials, notarization fails and so does the build.
  Set `SKIP_NOTARIZE=1` to sign without notarizing, for example while iterating locally.
- `RELEASE=1` marks a public release build; without it the build is a beta.
- `scripts/release.sh` runs the whole sequence for a DMG (build, sign, notarize,
  package), and `build-pkg.sh` builds the installer package. See
  [`scripts/README.md`](scripts/README.md).

## Security model

The app is a non-privileged GUI shell over `jamf-cli`:

- **Path allow-list:** `NSWorkspace` file actions (Open, Reveal) are bounded to the
  workspaces root, a short list of app folders, and the report folder a profile's
  `output.output_dir` resolves to. A path outside that scope is refused.
- **Profile names:** any name `jamf-cli` accepts works, except one that is empty, has a
  control character, starts or ends with a space, or is very long. Folders, file names
  and schedule labels use an encoded form (`ProfileName`), so no name can reach outside
  the workspace root or break a label.
- **No persisted credentials in the app:** during onboarding the app passes the API
  client secret to `jamf-cli` over a PTY's stdin, redacts failure output and clears the
  field afterward. Persistent secrets stay in the system keychain through `jamf-cli`.
- **jamf-cli is verified before use:** the binary must satisfy a code-signing
  requirement for Jamf's Developer ID team before the app launches it or hands it a
  secret.
- **One background item, no `sudo`:** scheduled runs come from a single `SMAppService`
  agent inside the signed bundle. The app never requests `sudo`, installs a LaunchDaemon
  or writes to `~/Library/LaunchAgents`.
- **Atomic writes:** configuration, schedule-store and snapshot writes go through a
  temporary file and rename, so a crash or power loss does not leave a torn file.
- **Hardened Runtime:** release builds use it, with the entitlements in
  `JamfReports.entitlements`.

The threats and mitigations are in
[`docs/architecture/jamf-reports-community-threat-model.md`](../docs/architecture/jamf-reports-community-threat-model.md).

## License

MIT, same as the parent project. See the repo root.
