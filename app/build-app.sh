#!/bin/zsh
# Build a runnable JamfReports.app bundle from the SwiftPM executable target.
# Usage: ./build-app.sh [debug|release]   (default: release)

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"

# Sparkle EdDSA public key — REQUIRED for release builds. Without it the
# release Info.plist would carry an empty `SUPublicEDKey`, which combined
# with `cs.disable-library-validation` (entitlements) and the active
# Sparkle XPC helpers makes the update channel a high-value target. Debug
# builds may proceed without it (Sparkle refuses to apply updates without
# a key — safe-by-default). See P9-A-01 in the security audit.
if [[ "$CONFIG" == "release" ]]; then
  : "${SU_PUBLIC_ED_KEY:?SU_PUBLIC_ED_KEY env var must be set for release builds. Generate with Sparkle's generate_keys tool; private key stays offline.}"
else
  : "${SU_PUBLIC_ED_KEY:=}"
fi
export SU_PUBLIC_ED_KEY

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

cat > "$APP_OUT/Contents/Info.plist" <<'PLIST'
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
    <string>2.0.0</string>
    <!-- CFBundleVersion is Sparkle's monotonic build number across the entire
         project lifetime. Bump per beta (10 → 11 → 12 …). Never reuse or reset,
         even when the marketing version changes — the next 2.0.1 beta starts at
         build > 10. Re-using a build number makes Sparkle refuse the update. -->
    <key>CFBundleVersion</key>
    <string>10</string>
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

    <!-- Sparkle auto-update — see ADR-W23-sparkle-integration.md.
         For release builds, SU_PUBLIC_ED_KEY env var MUST be set; this script
         hard-fails earlier when it isn't. Debug builds may ship empty —
         Sparkle 2.x refuses to apply updates without a key (safe-by-default).
         Tony generates the EdDSA keypair offline with `generate_keys`; private
         key is stored in 1Password + offline backup, never committed. -->
    <key>SUFeedURL</key>
    <string>https://tonyyo11.github.io/jamf-reports-community/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>__SU_PUBLIC_ED_KEY_PLACEHOLDER__</string>
    <key>SUEnableInstallerLauncherService</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
</dict>
</plist>
PLIST

# Substitute SUPublicEDKey via PlistBuddy after writing the placeholder.
#
# Why not unquote the heredoc? Doing so would interpolate $SU_PUBLIC_ED_KEY raw
# into XML, allowing a hostile/typo'd value containing `</string>` to inject
# arbitrary plist keys (e.g. swap SUFeedURL). PlistBuddy parses the real plist
# tree, so XML metacharacters in the value are stored as data, not structure.
# Defense-in-depth: regex-validate first — Sparkle EdDSA pubkeys are 32 bytes
# base64-encoded (44 chars including padding), strict charset.
if [[ -n "${SU_PUBLIC_ED_KEY}" ]]; then
  if [[ ! "$SU_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "✗ SU_PUBLIC_ED_KEY does not match expected EdDSA base64 format (43 chars + '=')." >&2
    echo "  Got: ${#SU_PUBLIC_ED_KEY} chars." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SU_PUBLIC_ED_KEY" \
    "$APP_OUT/Contents/Info.plist"
fi

# Post-build assertion: refuse to ship a release build whose Info.plist still
# contains the literal placeholder. Debug builds may carry the placeholder
# (Sparkle 2.x refuses to apply updates with a malformed key — safe-by-default).
if [[ "$CONFIG" == "release" ]] \
   && grep -q "__SU_PUBLIC_ED_KEY_PLACEHOLDER__" "$APP_OUT/Contents/Info.plist"; then
  echo "✗ Info.plist still contains SU_PUBLIC_ED_KEY placeholder after substitution." >&2
  exit 1
fi

# Embed Sparkle.framework. SwiftPM stages it under .build/<triple>/<config>/
# but does NOT copy it into the .app — without this step the binary fails to
# launch with: Library not loaded: @rpath/Sparkle.framework/...
SPARKLE_SRC="${BUILT_DIR}/Sparkle.framework"
if [[ -d "$SPARKLE_SRC" ]]; then
  echo "→ embedding Sparkle.framework"
  mkdir -p "$APP_OUT/Contents/Frameworks"
  rm -rf "$APP_OUT/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE_SRC" "$APP_OUT/Contents/Frameworks/Sparkle.framework"

  # Strip build-time artifacts from the embedded framework. Sparkle's binary
  # tarball ships Headers/ and PrivateHeaders/ for SDK consumers; shipping them
  # inside a notarized .app trips Gatekeeper's strict-mode validation on
  # quarantined launches with "unsealed contents present in the root directory
  # of an embedded framework" — even though notarytool itself accepts them.
  EMBEDDED_SPARKLE="$APP_OUT/Contents/Frameworks/Sparkle.framework"
  find "$EMBEDDED_SPARKLE/Versions" -type d \
    \( -name Headers -o -name PrivateHeaders \) \
    -prune -exec rm -rf {} +
  rm -f "$EMBEDDED_SPARKLE/Headers" "$EMBEDDED_SPARKLE/PrivateHeaders"

  # Strip extended attributes (com.apple.quarantine from the curl download,
  # com.apple.provenance, etc.). Leftover xattrs invalidate the seal in
  # strict-mode validation. Apply to the whole .app for safety.
  xattr -cr "$APP_OUT"

  # Add @loader_path/../Frameworks to the main binary's rpath so dyld can
  # resolve @rpath/Sparkle.framework/... at launch. SwiftPM does not add this
  # rpath automatically. Must run BEFORE codesign — install_name_tool
  # invalidates any prior signature.
  if ! otool -l "$APP_OUT/Contents/MacOS/JamfReports" \
       | grep -q "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath "@loader_path/../Frameworks" \
      "$APP_OUT/Contents/MacOS/JamfReports"
  fi
else
  echo "⚠ Sparkle.framework not found at $SPARKLE_SRC; auto-update will fail" >&2
fi

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
  # Sparkle requires inside-out signing of its inner helpers BEFORE the outer
  # framework, BEFORE the main app. Order matters; --deep is not sufficient
  # for nested XPC services + the Updater.app helper.
  SPARKLE_FRAMEWORK="$APP_OUT/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "→ signing Sparkle.framework helpers"
    SPARKLE_INNER="$SPARKLE_FRAMEWORK/Versions/B"
    for helper in \
      "$SPARKLE_INNER/XPCServices/Downloader.xpc" \
      "$SPARKLE_INNER/XPCServices/Installer.xpc" \
      "$SPARKLE_INNER/Updater.app" \
      "$SPARKLE_INNER/Autoupdate"
    do
      if [[ -e "$helper" ]]; then
        if ! codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$TS_FLAG" "$helper" >/dev/null; then
          echo "✗ codesign failed for $helper" >&2
          exit 1
        fi
      fi
    done
    if ! codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$TS_FLAG" "$SPARKLE_FRAMEWORK" >/dev/null; then
      echo "✗ codesign failed for $SPARKLE_FRAMEWORK" >&2
      exit 1
    fi
  fi

  echo "→ signing $APP_OUT"
  # Drop --deep: Sparkle.framework was already signed inside-out above; --deep
  # would re-sign helpers without their entitlements/identifiers.
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
