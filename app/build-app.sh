#!/bin/zsh
# Build a runnable JamfReports.app bundle from the SwiftPM executable target.
# Usage: ./build-app.sh [debug|release]   (default: release)

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"

# Marketing version (CFBundleShortVersionString) — bumped per milestone.
# This is the single source of truth for the user-facing semver; keep it in
# sync with AppVersionState.fallbackVersion (a test enforces this).
MARKETING_VERSION="${MARKETING_VERSION:-2.3.0}"

# Build number (CFBundleVersion). Always a monotonically increasing integer
# (git commit count), independent of the marketing version — this matches
# Apple's CURRENT_PROJECT_VERSION model and keeps every build comparable.
# Do NOT set this to the marketing version for releases (that made a beta's
# integer build look "newer" than its own release to version-comparing tools).
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"

# Release channel. Set RELEASE=1 for a public release build; otherwise the
# build is a beta and downstream build-pkg.sh appends -betaN.
# This is stamped into Info.plist (JRReleaseChannel) so the packaging scripts
# read the channel from the .app rather than guessing from the build number.
RELEASE="${RELEASE:-0}"
if [[ "$RELEASE" == "1" ]]; then
  RELEASE_CHANNEL="release"
else
  RELEASE_CHANNEL="beta"
fi

echo "→ version ${MARKETING_VERSION} build ${BUILD_NUMBER} (${RELEASE_CHANNEL})"
echo "→ swift build (${CONFIG})"
if [[ "$CONFIG" == "release" ]]; then
  swift build -c release
else
  swift build
fi

ARCH=$(uname -m)
TRIPLE="${ARCH}-apple-macosx"
BUILT_DIR=".build/${TRIPLE}/${CONFIG}"
BIN="${BUILT_DIR}/JamfReports"
BUNDLE="${BUILT_DIR}/JamfReports_JamfReports.bundle"

if [[ ! -x "$BIN" ]]; then
  echo "✗ binary not found at $BIN" >&2
  exit 1
fi

APP_OUT="build/JamfReports.app"
echo "→ packaging $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS"
mkdir -p "$APP_OUT/Contents/Resources"

cp "$BIN" "$APP_OUT/Contents/MacOS/JamfReports"
chmod +x "$APP_OUT/Contents/MacOS/JamfReports"

# Copy bundled font assets directly into Contents/Resources/ so Bundle.main
# can find them on any Mac. SwiftPM's auto-generated `Bundle.module` accessor
# is incompatible with macOS .app code-signing rules (it expects the resource
# bundle at the .app root, outside Contents/, which violates the "unsealed
# contents" check), so FontRegistry uses a Bundle.main lookup instead — see
# Theme.swift `FontRegistry.locateFont(named:)`. The SwiftPM bundle is
# deliberately NOT copied into the packaged .app.
if [[ -d "$BUNDLE" ]]; then
  find "$BUNDLE" -mindepth 1 -maxdepth 1 -type f \
    \( -name "*.ttf" -o -name "*.otf" -o -name "*.png" -o -name "*.json" \) \
    -print0 | while IFS= read -r -d '' asset; do
    cp "$asset" "$APP_OUT/Contents/Resources/"
  done
fi

# Regenerate the AppIcon.icns if missing (first-run convenience).
if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "→ AppIcon.icns missing — running iconset/build-icon.sh"
  ./iconset/build-icon.sh
fi
cp "Resources/AppIcon.icns" "$APP_OUT/Contents/Resources/AppIcon.icns"

if [[ -f "../config.example.yaml" ]]; then
  cp "../config.example.yaml" "$APP_OUT/Contents/Resources/config.example.yaml"
fi

cat > "$APP_OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>JamfReports</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.tonyyo.jamfreports</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Jamf Reports</string>
    <key>CFBundleDisplayName</key>
    <string>Jamf Reports</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <!-- CFBundleVersion is always a monotonic integer (git commit count),
         independent of the marketing version. Release-vs-beta is signalled by
         JRReleaseChannel below, which build-pkg.sh reads. -->
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <!-- Private key: "release" or "beta". The packaging scripts read this to
         decide artifact naming instead of inferring it from the build number. -->
    <key>JRReleaseChannel</key>
    <string>${RELEASE_CHANNEL}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Tony Young. Released under the project license.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
        <key>NSAllowsLocalNetworking</key>
        <false/>
    </dict>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST

# Strip extended attributes (com.apple.quarantine, com.apple.provenance, etc.)
# from the whole .app. Leftover xattrs invalidate the code-signing seal under
# Gatekeeper strict-mode validation on quarantined launches.
xattr -cr "$APP_OUT"

# Resolve signing identity.
#   - Release: prefer SIGNING_IDENTITY env var; otherwise auto-pick the first
#     "Developer ID Application" identity in the login keychain. Falls back to
#     ad-hoc with a warning so dev builds still work without a cert.
#   - Debug: ad-hoc unless SIGNING_IDENTITY is explicitly set.
# When the identity is "-" (ad-hoc), Apple's secure timestamp (TSA) is not
# available and `--timestamp=none` is used everywhere. When a real Developer ID
# identity is in use, `--timestamp` is required for notarization.
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  if [[ "$CONFIG" == "release" ]]; then
    if [[ -n "${TEAM_ID:-}" ]]; then
      # TEAM_ID is set — select the identity whose subject contains the Team ID
      # (format: "Developer ID Application: Name (TEAMID)"). Fail loudly if none
      # match so a wrong TEAM_ID doesn't silently fall through to a different cert.
      SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2}' \
        | grep "(${TEAM_ID})" | head -1)
      if [[ -z "$SIGNING_IDENTITY" ]]; then
        echo "✗ no Developer ID Application identity found for TEAM_ID=${TEAM_ID}" >&2
        echo "  Available identities:" >&2
        security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" >&2
        exit 1
      fi
    else
      # No TEAM_ID — auto-pick the first available Developer ID Application cert.
      # This is ambiguous when multiple certs are installed; set TEAM_ID to be explicit.
      SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
      if [[ -z "$SIGNING_IDENTITY" ]]; then
        echo "⚠ no Developer ID Application identity found; falling back to ad-hoc" >&2
        echo "  (release build will not be notarizable)" >&2
        SIGNING_IDENTITY="-"
      else
        echo "⚠ TEAM_ID not set — auto-selected first Developer ID Application identity" >&2
        echo "  Set TEAM_ID=<your-team-id> to select explicitly and silence this warning" >&2
      fi
    fi
  else
    SIGNING_IDENTITY="-"
  fi
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  TS_FLAG="--timestamp=none"
else
  TS_FLAG="--timestamp"
fi
echo "→ signing identity: ${SIGNING_IDENTITY}"

ENTITLEMENTS="JamfReports.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
  echo "→ signing $APP_OUT"
  if ! codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    "$TS_FLAG" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_OUT" >/dev/null; then
    echo "✗ codesign failed for $APP_OUT" >&2
    exit 1
  fi
else
  echo "✗ $ENTITLEMENTS missing — refusing to sign without entitlements" >&2
  exit 1
fi

# Notarize + staple when:
#   - building release, AND
#   - a real Developer ID identity was used (ad-hoc cannot be notarized), AND
#   - SKIP_NOTARIZE is not set (escape hatch for fast local iteration).
# Auth: set NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER for keychain-free App Store
# Connect API-key auth (CI / non-interactive); otherwise uses the keychain profile
# stored via `xcrun notarytool store-credentials`.
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
if [[ "$CONFIG" == "release" \
      && "$SIGNING_IDENTITY" != "-" \
      && -z "${SKIP_NOTARIZE:-}" ]]; then
  ZIP_OUT="build/JamfReports-notarize.zip"
  echo "→ packing for notarization: $ZIP_OUT"
  rm -f "$ZIP_OUT"
  /usr/bin/ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

  echo "→ submitting to Apple notary service ($NOTARY_AUTH_DESC)"
  if ! xcrun notarytool submit "$ZIP_OUT" \
       "${NOTARY_AUTH_ARGS[@]}" \
       --wait; then
    echo "✗ notarization failed — run 'xcrun notarytool log <id>' with the same auth for details" >&2
    exit 1
  fi

  echo "→ stapling notarization ticket"
  if ! xcrun stapler staple "$APP_OUT"; then
    echo "✗ stapler failed for $APP_OUT" >&2
    exit 1
  fi

  rm -f "$ZIP_OUT"
  echo "✓ notarized + stapled"
fi

echo "✓ built $APP_OUT"
echo "  open it with:  open $APP_OUT"
