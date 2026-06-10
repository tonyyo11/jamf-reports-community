#!/bin/zsh
# Package a notarized macOS app bundle into a distributable DMG.
# Creates a staging directory with .app + Applications symlink, then builds DMG.
# Idempotent: removes existing DMG first.
# Exits 1 on failure.
#
# Usage: ./package-dmg.sh "2.1.0"

set -euo pipefail

readonly VERSION="${1:?Version required (e.g. 2.1.0)}"
readonly APP_PATH="$(cd -- "$(dirname -- "$0")/../build/JamfReports.app" && pwd -P)"
readonly WORK_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
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
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
