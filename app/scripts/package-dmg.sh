#!/bin/zsh
# Package a notarized macOS app bundle into a distributable DMG.
# Creates a staging directory with .app + Applications symlink, then builds DMG.
# Idempotent: removes existing DMG first.
# Exits 1 on failure.
#
# Usage: ./package-dmg.sh "2.1.0"
#
# Required environment variables (when SKIP_NOTARIZE is not set):
#   DEVELOPER_ID_APP  — Developer ID Application signing identity (for DMG codesign)
#
# Notary auth — API-key mode (preferred for CI):
#   NOTARY_KEY_PATH   — path to .p8 App Store Connect API key
#   NOTARY_KEY_ID     — key ID (e.g. R9TU3HP749)
#   NOTARY_ISSUER     — issuer UUID from App Store Connect
# Notary auth — keychain profile mode (interactive use):
#   NOTARY_PROFILE    — keychain profile name (xcrun notarytool store-credentials)
#                       Defaults to "JamfReports-Notary" if none of the above are set.
#
# Optional:
#   SKIP_NOTARIZE=1   — skip codesign/notarize/staple (produces an unsigned DMG)

set -euo pipefail

readonly VERSION="${1:?Version required (e.g. 2.1.0)}"
APP_PATH_RAW="$(cd -- "$(dirname -- "$0")/../build/JamfReports.app" && pwd -P)"
readonly APP_PATH="$APP_PATH_RAW"
WORK_DIR_RAW="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly WORK_DIR="$WORK_DIR_RAW"
readonly STAGING_DIR="${WORK_DIR}/build/.dmg-staging"

if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ App bundle not found: $APP_PATH" >&2
  exit 1
fi

# Read release channel and build number from the .app's Info.plist.
# JRReleaseChannel ("release"/"beta") decides artifact naming; a missing key
# (older .app) defaults to beta so a release is never mislabeled by accident.
PLIST="$APP_PATH/Contents/Info.plist"
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") || {
  echo "✗ could not read CFBundleVersion from $PLIST" >&2
  exit 1
}
APP_CHANNEL=$(/usr/libexec/PlistBuddy -c "Print :JRReleaseChannel" "$PLIST" 2>/dev/null || echo "beta")

if [[ "$APP_CHANNEL" != "release" ]]; then
  DMG_PATH="${WORK_DIR}/build/JamfReports-${VERSION}-beta${APP_BUILD}.dmg"
else
  DMG_PATH="${WORK_DIR}/build/JamfReports-${VERSION}.dmg"
fi

# Clean up old staging and DMG
if [[ -d "$STAGING_DIR" ]]; then
  rm -rf -- "$STAGING_DIR"
fi
if [[ -f "$DMG_PATH" ]]; then
  rm -f -- "$DMG_PATH"
fi

echo "→ Creating DMG staging directory..."
mkdir -p -- "$STAGING_DIR"

# Copy app to staging
echo "→ Copying app to staging..."
cp -a "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink
echo "→ Creating Applications symlink..."
ln -s /Applications "$STAGING_DIR/Applications"

# Build DMG using hdiutil
echo "→ Building DMG..."
if ! hdiutil create \
  -volname "JamfReports" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"; then
  echo "✗ DMG creation failed" >&2
  rm -rf -- "$STAGING_DIR"
  exit 1
fi

# Verify DMG was created
if [[ ! -f "$DMG_PATH" ]]; then
  echo "✗ DMG file not created" >&2
  exit 1
fi

# Clean up staging
rm -rf -- "$STAGING_DIR"

echo "✓ DMG created: $DMG_PATH"

# ── Notarization ─────────────────────────────────────────────────────────────
# Skip when SKIP_NOTARIZE=1 is set (fast local iteration / unsigned DMG).
# When notarizing, the DMG is codesign'd, submitted to Apple notarytool,
# stapled, and validated — matching build-pkg.sh notarization behavior.
if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "⚠ SKIP_NOTARIZE set — skipping codesign/notarize/staple" >&2
  echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
  exit 0
fi

# Require signing identity
: "${DEVELOPER_ID_APP:?DEVELOPER_ID_APP env var not set (e.g. Developer ID Application: Tony Young (XXXXXXXXXX))}"

# Resolve notary auth args.  API-key mode takes priority over keychain profile.
NOTARY_PROFILE="${NOTARY_PROFILE:-JamfReports-Notary}"
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID must be set when NOTARY_KEY_PATH is set}"
  : "${NOTARY_ISSUER:?NOTARY_ISSUER must be set when NOTARY_KEY_PATH is set}"
  NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  NOTARY_AUTH_DESC="API key ${NOTARY_KEY_ID}"
else
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  NOTARY_AUTH_DESC="profile: $NOTARY_PROFILE"
fi

# Sign the DMG.
# DMGs are not app bundles — no --options runtime, no entitlements.
echo "→ Signing DMG with: $DEVELOPER_ID_APP"
if ! codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG_PATH"; then
  echo "✗ codesign failed for $DMG_PATH" >&2
  exit 1
fi
echo "✓ DMG signed"

# Notarize the DMG.
echo "→ Submitting DMG to Apple notary service ($NOTARY_AUTH_DESC)"
if ! xcrun notarytool submit "$DMG_PATH" \
     "${NOTARY_AUTH_ARGS[@]}" \
     --wait --timeout 20m; then
  echo "✗ DMG notarization failed — run 'xcrun notarytool log <id>' with the same auth" >&2
  exit 1
fi
echo "✓ DMG notarization accepted"

# Staple the ticket to the DMG.
echo "→ Stapling notarization ticket to DMG..."
if ! xcrun stapler staple "$DMG_PATH"; then
  echo "✗ stapler failed for $DMG_PATH" >&2
  exit 1
fi
echo "✓ DMG ticket stapled"

# Validate the staple.
if ! xcrun stapler validate "$DMG_PATH"; then
  echo "✗ stapler validate failed — staple may not have taken" >&2
  exit 1
fi
echo "✓ DMG staple validated"

echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
