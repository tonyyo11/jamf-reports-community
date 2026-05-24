# JamfReports Release Pipeline

Scripts for producing signed, notarized, and packaged macOS app releases.

## Prerequisites

Before running a release, ensure your machine has:

1. **Developer ID certificate** in Keychain
   - Use `security find-identity -p codesigning` to list available identities
   - The certificate common name must match the `DEVELOPER_ID_APP` env var

2. **Apple notarization credentials**
   - Store credentials once: `xcrun notarytool store-credentials`
   - Creates a keychain profile (used as `NOTARY_KEYCHAIN_PROFILE`)
   - Requires an Apple ID with Developer Program membership

## Quick Start

```bash
cd app

RELEASE_VERSION=2.1.0 \
DEVELOPER_ID_APP="Developer ID Application: Tony Young (XXXXXXXXXX)" \
NOTARY_KEYCHAIN_PROFILE="apple-id-profile" \
./scripts/release.sh
```

Exit code 0 = success. Exit code 1 = failure (see stderr for details).

## Outputs

After a successful release:

```
app/build/
├── JamfReports.app           # Signed, notarized app bundle
└── JamfReports-2.1.0.dmg     # Distribution DMG
```

Upload the `.dmg` to GitHub Releases. The app has no built-in auto-updater —
the "Check for Updates…" menu item opens the GitHub Releases page so users can
download the latest build.

## Script Details

### `release.sh`

Top-level orchestrator. Runs steps in order: build → sign → notarize → package.

**Environment variables (all required):**
- `RELEASE_VERSION` — Version string (e.g., `2.1.0`)
- `DEVELOPER_ID_APP` — Developer ID identity name (e.g., `Developer ID Application: Tony Young (XXXXXXXXXX)`)
- `NOTARY_KEYCHAIN_PROFILE` — Keychain profile name for notarization credentials

**Exit codes:**
- 0 = Success
- 1 = Build, signing, notarization, or packaging failed

**Idempotent:** Each step is safe to re-run. Earlier steps are re-executed if needed.

### `sign-release.sh`

Signs the app bundle with a Developer ID certificate. Uses Hardened Runtime and embedded entitlements.

**Arguments:** `$1` = Developer ID identity (same as `DEVELOPER_ID_APP`)

**Process:**
1. Verify identity exists in Keychain
2. Sign all frameworks (deepest-first)
3. Sign all dylibs in Frameworks/
4. Sign main executable with entitlements
5. Verify final signature

**Exit codes:**
- 0 = Signature verified
- 1 = Identity not found, signing failed, or verification failed

**Idempotent:** Re-running overwrites previous signatures and re-verifies.

### `notarize-release.sh`

Submits the app to Apple's notarization service and staples the ticket.

**Arguments:** `$1` = Keychain profile name (from `xcrun notarytool store-credentials`)

**Process:**
1. Verify signature before submission
2. Create temporary ZIP
3. Submit to `xcrun notarytool` (with `--wait`)
4. Parse result for success/rejection
5. Staple ticket to app
6. Verify final signature

**Exit codes:**
- 0 = Notarization successful and ticket stapled
- 1 = Pre-flight signature check failed, submission failed, or rejection

**Idempotent:** Creates temporary files in a cleanup trap; safe to re-run.

### `package-dmg.sh`

Packages the notarized app into a distributable DMG.

**Arguments:** `$1` = Version string

**Process:**
1. Remove old DMG if present (idempotent)
2. Create staging directory
3. Copy app to staging
4. Create Applications symlink
5. Build UDZO-compressed DMG with `hdiutil`

**Exit codes:**
- 0 = DMG created successfully
- 1 = App not found or DMG creation failed

**Idempotent:** Removes old DMG first, so re-running is safe.

## Troubleshooting

### Identity not found in Keychain

```
✗ Identity not found in keychain: Developer ID Application: Tony Young (XXXXXXXXXX)
```

**Fix:**
1. List available identities: `security find-identity -p codesigning`
2. Update `DEVELOPER_ID_APP` to match exactly
3. Ensure Developer ID certificate is not expired: `security find-identity -p codesigning | grep Developer`

### Notarization rejected

Common reasons:
- **Code signature invalid** — Run sign-release.sh separately and verify first
- **Entitlements invalid** — Check `app/JamfReports.entitlements` syntax
- **Malicious code detected** — Submit a request to Apple to review (Apple Support)
- **Rate limited** — Wait a few minutes and retry

**Debug:**
```bash
# View full notarization status
xcrun notarytool info <submission-id> --keychain-profile <profile>

# View rejection reason
xcrun notarytool log <submission-id> --keychain-profile <profile> jamfreports.json
```

### DMG creation failed

Ensure app bundle exists and is readable:
```bash
ls -la app/build/JamfReports.app
```

## Development Notes

All scripts are:
- POSIX-compliant zsh (`#!/bin/zsh`, `set -euo pipefail`)
- Self-contained (no external shell libraries)
- Idempotent where possible (safe to re-run)
- Fail-fast with clear error messages

Never run signing or notarization directly — use the orchestrator script `release.sh`.
