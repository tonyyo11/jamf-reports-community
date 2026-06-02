#!/bin/zsh
# Build a distributable JamfReports.dmg from an already-built .app bundle.
#
# Usage:
#   ./build-dmg.sh [debug|release]         (default: debug)
#
# Environment:
#   SIGNING_IDENTITY   codesign identity hash or name (default: auto-pick
#                      Developer ID Application for team TEAM_ID)
#   TEAM_ID            Apple Developer team ID to match in keychain
#                      (default: HH6NWGU4G8 — Anthony Young)
#   SKIP_NOTARIZE      set to any value to skip notarization (default for debug)
#   NOTARY_PROFILE     xcrun notarytool keychain profile name (default: JamfReports-Notary)
#
# The .app must already exist at build/JamfReports.app.
# Run build-app.sh first if it doesn't.

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_PATH="build/JamfReports.app"
DMG_STAGING="build/dmg-staging"
DMG_TMP="build/JamfReports-tmp.dmg"
DMG_OUT="build/JamfReports.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ $APP_PATH not found. Run ./build-app.sh ${CONFIG} first." >&2
  exit 1
fi

# For release builds, the .app must already be signed (build-app.sh's job).
# Catch unsigned bundles here rather than failing later at notarization with a
# confusing error from Apple's service.
if [[ "$CONFIG" == "release" ]]; then
  if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    echo "✗ $APP_PATH is not properly signed — run ./build-app.sh release first" >&2
    exit 1
  fi
fi

# Read marketing version and build number from the built .app's Info.plist.
# CFBundleShortVersionString = user-facing version (must be N.N or N.N.N).
# CFBundleVersion           = build number; bumped per beta while marketing
#                              version stays stable. When they match, this is a
#                              release build; when they differ, this is a beta.
PLIST="$APP_PATH/Contents/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST") || {
  echo "✗ could not read CFBundleShortVersionString from $PLIST" >&2
  exit 1
}
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") || {
  echo "✗ could not read CFBundleVersion from $PLIST" >&2
  exit 1
}

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✗ unexpected CFBundleShortVersionString: '$APP_VERSION' (want N.N or N.N.N)" >&2
  exit 1
fi
if [[ ! "$APP_BUILD" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "✗ unexpected CFBundleVersion: '$APP_BUILD'" >&2
  exit 1
fi

if [[ "$APP_BUILD" != "$APP_VERSION" ]]; then
  DMG_OUT="build/JamfReports-${APP_VERSION}-beta${APP_BUILD}.dmg"
  DMG_VOLUME="Jamf Reports ${APP_VERSION} beta ${APP_BUILD}"
else
  DMG_OUT="build/JamfReports-${APP_VERSION}.dmg"
  DMG_VOLUME="Jamf Reports ${APP_VERSION}"
fi
MOUNT_DIR="/Volumes/${DMG_VOLUME}"

# Detach any lingering mount from a prior aborted run. If a stale mount exists
# but we can't release it, fail loud — proceeding would either fail at attach
# with a confusing message or attach to a different device than intended.
if hdiutil info 2>/dev/null | grep -qF "$MOUNT_DIR"; then
  echo "→ detaching stale mount at $MOUNT_DIR"
  DEV=$(hdiutil info 2>/dev/null | grep -F "$MOUNT_DIR" | awk '{print $1}' | head -1)
  if ! hdiutil detach "$DEV" -force; then
    echo "✗ could not detach stale mount at $MOUNT_DIR (device $DEV)" >&2
    echo "  manually release it with: hdiutil detach $DEV -force" >&2
    exit 1
  fi
fi

echo "→ staging DMG content"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/JamfReports.app"
ln -s /Applications "$DMG_STAGING/Applications"

# Estimate size of the staged content and add 20% headroom (in MB).
STAGED_KB=$(du -sk "$DMG_STAGING" | awk '{print $1}')
DMG_MB=$(( (STAGED_KB / 1024) * 12 / 10 + 32 ))

echo "→ creating writable image (${DMG_MB}m)"
rm -f "$DMG_TMP" "$DMG_OUT"
hdiutil create \
  -megabytes "${DMG_MB}" \
  -volname "$DMG_VOLUME" \
  -fs HFS+ \
  "$DMG_TMP"

hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen \
  -mountpoint "$MOUNT_DIR" >/dev/null
echo "→ mounted at $MOUNT_DIR"

cp -R "$DMG_STAGING/JamfReports.app" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

# Set background color window and icon positions via AppleScript.
# These are best-effort; skip if osascript fails (headless CI).
osascript - "$MOUNT_DIR" "$DMG_VOLUME" <<'AS' 2>/dev/null || true
on run argv
  set mountPath to item 1 of argv
  set volName to item 2 of argv
  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {400, 200, 920, 520}
      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 128
      set position of item "JamfReports.app" of container window to {130, 150}
      set position of item "Applications" of container window to {390, 150}
      close
      open
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
AS

hdiutil detach "$MOUNT_DIR" -quiet

echo "→ converting to compressed read-only DMG"
hdiutil convert "$DMG_TMP" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT"
rm -f "$DMG_TMP"
rm -rf "$DMG_STAGING"

# Resolve signing identity.
# Match by team ID (e.g. HH6NWGU4G8) inside the Developer ID Application cert
# name. This is stable across cert renewals — when the cert is renewed, the new
# cert keeps the same team ID, so the script keeps finding it without edits.
TEAM_ID="${TEAM_ID:-HH6NWGU4G8}"
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v team="(${TEAM_ID})" '
        /Developer ID Application/ && index($0, team) { print $2; exit }
      ')
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$CONFIG" == "release" ]]; then
      echo "✗ no Developer ID Application identity for team $TEAM_ID found." >&2
      echo "  Release builds must be signed. Set SIGNING_IDENTITY or TEAM_ID to" >&2
      echo "  override, or install the cert. Aborting." >&2
      exit 1
    fi
    echo "⚠ no Developer ID Application identity for team $TEAM_ID found;" >&2
    echo "  debug DMG will be unsigned (ad-hoc). Set SIGNING_IDENTITY to override." >&2
    SIGNING_IDENTITY="-"
  fi
fi

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  echo "→ signing DMG: $SIGNING_IDENTITY"
  codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_OUT"
  # Verify the signature took. codesign exits 0 on success, but verifying
  # closes the silent-failure gap (mirrors build-pkg.sh post-sign check).
  if ! codesign --verify --strict "$DMG_OUT" 2>/dev/null; then
    echo "✗ DMG signature verification failed for $DMG_OUT" >&2
    exit 1
  fi
else
  echo "⚠ DMG is unsigned (ad-hoc identity)" >&2
fi

# Notarize when: release mode, real identity, SKIP_NOTARIZE not set.
# Auth: NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER (API key) or keychain profile.
NOTARY_PROFILE="${NOTARY_PROFILE:-JamfReports-Notary}"
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  NOTARY_AUTH_DESC="API key ${NOTARY_KEY_ID}"
else
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  NOTARY_AUTH_DESC="profile: $NOTARY_PROFILE"
fi
if [[ "$CONFIG" == "release" \
      && "$SIGNING_IDENTITY" != "-" \
      && -z "${SKIP_NOTARIZE:-}" ]]; then
  echo "→ submitting DMG to Apple notary service ($NOTARY_AUTH_DESC)"
  if ! xcrun notarytool submit "$DMG_OUT" \
       "${NOTARY_AUTH_ARGS[@]}" \
       --wait; then
    echo "✗ notarization failed" >&2
    exit 1
  fi
  echo "→ stapling notarization ticket"
  xcrun stapler staple "$DMG_OUT"
  echo "✓ notarized + stapled"
fi

echo "✓ $DMG_OUT"
echo "  size: $(du -sh "$DMG_OUT" | awk '{print $1}')"
