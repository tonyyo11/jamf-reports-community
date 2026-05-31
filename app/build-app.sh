#!/bin/zsh
# Build a runnable JamfReports.app bundle from the SwiftPM executable target.
# Usage: ./build-app.sh [debug|release]   (default: release)

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"

# Marketing version (CFBundleShortVersionString) — bumped per milestone.
MARKETING_VERSION="${MARKETING_VERSION:-2.1.1}"

# Build number (CFBundleVersion). When equal to MARKETING_VERSION the
# downstream build-dmg.sh / build-pkg.sh treat the build as a public
# release; when different they name the artifacts -betaN. Default derives
# from git commit count so every dev build is uniquely identifiable.
# For a clean release, invoke as:
#   BUILD_NUMBER="${MARKETING_VERSION}" ./build-app.sh release
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"

echo "→ version ${MARKETING_VERSION} build ${BUILD_NUMBER}"
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

# PR-19: bundle jamf-reports-community.py so the Settings → "Copy Diagnostic
# Command" flow can emit an absolute-path command that works regardless of
# the user's Terminal cwd. The app itself never executes this script — it
# only puts an absolute path into the clipboard and opens Terminal. The user
# pastes and runs. Bundling is a narrow exception to the CLAUDE.md
# "Python is not bundled or required" rule, scoped only to the diagnostic
# support workflow. See ADR-PR-19 (TODO) for the long-term migration plan
# to a native Swift implementation that drops the Python dependency.
if [[ -f "../jamf-reports-community.py" ]]; then
  cp "../jamf-reports-community.py" "$APP_OUT/Contents/Resources/jamf-reports-community.py"
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
    <!-- CFBundleVersion equals CFBundleShortVersionString for a release build.
         build-dmg.sh / build-pkg.sh treat a differing value as a beta and name
         the artifacts -betaN; keep the two in sync for a public release. -->
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
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
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    if [[ -z "$SIGNING_IDENTITY" ]]; then
      echo "⚠ no Developer ID Application identity found; falling back to ad-hoc" >&2
      echo "  (release build will not be notarizable)" >&2
      SIGNING_IDENTITY="-"
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
# Uses the keychain profile stored via `xcrun notarytool store-credentials`.
NOTARY_PROFILE="${NOTARY_PROFILE:-JamfReports-Notary}"
if [[ "$CONFIG" == "release" \
      && "$SIGNING_IDENTITY" != "-" \
      && -z "${SKIP_NOTARIZE:-}" ]]; then
  ZIP_OUT="build/JamfReports-notarize.zip"
  echo "→ packing for notarization: $ZIP_OUT"
  rm -f "$ZIP_OUT"
  /usr/bin/ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

  echo "→ submitting to Apple notary service (profile: $NOTARY_PROFILE)"
  if ! xcrun notarytool submit "$ZIP_OUT" \
       --keychain-profile "$NOTARY_PROFILE" \
       --wait; then
    echo "✗ notarization failed — run 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE' for details" >&2
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
