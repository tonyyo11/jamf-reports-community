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

3. **Sparkle signing tools**
   - Install via Homebrew: `brew install sparkle`
   - Provides `sign_update` binary for appcast generation

## Quick Start

```bash
cd app

RELEASE_VERSION=2.1.0 \
SU_PUBLIC_ED_KEY="$(cat ~/sparkle-ed-public-key.txt)" \
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
├── JamfReports-2.1.0.dmg     # Distribution DMG
└── appcast-2.1.0.xml         # Sparkle appcast snippet
```

Copy the appcast XML snippet into your `appcast.xml` GitHub Pages feed and upload the `.dmg` to GitHub Releases.

## Script Details

### `release.sh`

Top-level orchestrator. Runs steps in order: build → sign → notarize → package → appcast.

**Environment variables (all required):**
- `RELEASE_VERSION` — Version string (e.g., `2.1.0`)
- `SU_PUBLIC_ED_KEY` — Sparkle EdDSA public key (from `generate_keys` tool)
- `DEVELOPER_ID_APP` — Developer ID identity name (e.g., `Developer ID Application: Tony Young (XXXXXXXXXX)`)
- `NOTARY_KEYCHAIN_PROFILE` — Keychain profile name for notarization credentials

**Exit codes:**
- 0 = Success
- 1 = Build, signing, notarization, packaging, or appcast generation failed

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

### `sparkle-appcast.sh`

Generates a Sparkle appcast XML snippet for distribution.

**Arguments:** `$1` = Version string

**Environment variable (optional):**
- `SPARKLE_BIN_DIR` — Path to Sparkle bin directory (e.g., `/opt/homebrew/bin`)
  - If not set, searches common Xcode DerivedData paths
  - If sign_update not found, exits 1

**Process:**
1. Verify DMG exists
2. Locate `sign_update` binary
3. Generate EdDSA signature from DMG
4. Create XML with file size, signature, and metadata
5. Write to `appcast-VERSION.xml` and stdout

**Exit codes:**
- 0 = Appcast XML created
- 1 = DMG not found, sign_update not found, or signing failed

**Output:** XML snippet suitable for copying into a GitHub Pages `appcast.xml` feed.

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

### sign_update not found

```
✗ sign_update binary not found
```

**Fix:** Install Sparkle via Homebrew:
```bash
brew install sparkle
```

Or set `SPARKLE_BIN_DIR` explicitly:
```bash
SPARKLE_BIN_DIR=/opt/homebrew/bin ./sparkle-appcast.sh 2.1.0
```

### DMG creation failed

Ensure app bundle exists and is readable:
```bash
ls -la app/build/JamfReports.app
```

## Appcast Integration

Once appcast XML is generated, add it to your GitHub Pages `appcast.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>JamfReports Updates</title>
    <link>https://github.com/tonyyo/jamf-reports-community</link>
    <description>Updates for JamfReports</description>
    <language>en-us</language>

    <!-- Paste appcast-2.1.0.xml content here -->
    <item>
      <title>Version 2.1.0</title>
      ...
    </item>

  </channel>
</rss>
```

Then update the app's Info.plist `SUPublicEDKey` and update URL, and Sparkle will check for updates automatically.

## Development Notes

All scripts are:
- POSIX-compliant zsh (`#!/bin/zsh`, `set -euo pipefail`)
- Self-contained (no external shell libraries)
- Idempotent where possible (safe to re-run)
- Fail-fast with clear error messages

Never run signing or notarization directly — use the orchestrator script `release.sh`.
