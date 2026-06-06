#!/bin/zsh
# Build a distributable JamfReports.pkg (distribution-style) from an
# already-built .app bundle. Produces a signed, notarized, stapled .pkg
# suitable for upload to a Jamf Pro package repo, distribution via Self
# Service, or hosting on GitHub Releases.
#
# The .app is installed to /Applications/JamfReports.app on the target.
#
# Usage:
#   ./build-pkg.sh [debug|release]         (default: debug)
#
# Environment:
#   INSTALLER_IDENTITY   productsign identity (default: auto-pick Developer ID
#                        Installer for team TEAM_ID)
#   TEAM_ID              Apple Developer team ID to match in keychain
#                        (default: HH6NWGU4G8 — Anthony Young)
#   SKIP_NOTARIZE        set to any value to skip notarization (default for debug)
#   NOTARY_PROFILE       xcrun notarytool keychain profile name
#                        (default: JamfReports-Notary)
#
# The .app must already exist at build/JamfReports.app and must already be
# signed with a Developer ID Application certificate. Run build-app.sh first.

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_PATH="build/JamfReports.app"
PKG_STAGING="build/pkg-staging"
COMPONENT_PKG="build/JamfReports-component.pkg"
DISTRIBUTION_XML="build/Distribution.xml"
PKG_UNSIGNED="build/JamfReports-unsigned.pkg"

# Bundle identifier — must match the .app's CFBundleIdentifier so MDM
# inventory aligns. ".pkg" suffix distinguishes the installer package
# identifier from the app identifier in receipts.
PKG_BUNDLE_ID="com.tonyyo.jamfreports.pkg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ $APP_PATH not found. Run ./build-app.sh ${CONFIG} first." >&2
  exit 1
fi

# For release builds, the .app must already be signed.
if [[ "$CONFIG" == "release" ]]; then
  if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    echo "✗ $APP_PATH is not properly signed — run ./build-app.sh release first" >&2
    exit 1
  fi
fi

# Read marketing version, build number, and release channel from the .app's
# Info.plist. JRReleaseChannel ("release"/"beta") decides naming; a missing
# key (older .app) defaults to beta.
PLIST="$APP_PATH/Contents/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST") || {
  echo "✗ could not read CFBundleShortVersionString from $PLIST" >&2
  exit 1
}
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") || {
  echo "✗ could not read CFBundleVersion from $PLIST" >&2
  exit 1
}
APP_CHANNEL=$(/usr/libexec/PlistBuddy -c "Print :JRReleaseChannel" "$PLIST" 2>/dev/null || echo "beta")

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✗ unexpected CFBundleShortVersionString: '$APP_VERSION' (want N.N or N.N.N)" >&2
  exit 1
fi
if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "✗ unexpected CFBundleVersion: '$APP_BUILD' (must be a monotonic integer)" >&2
  exit 1
fi

if [[ "$APP_CHANNEL" != "release" ]]; then
  PKG_OUT="build/JamfReports-${APP_VERSION}-beta${APP_BUILD}.pkg"
  # productbuild's `--version` flag is a string — pkg receipts store it as-is.
  PKG_VERSION="${APP_VERSION}-beta${APP_BUILD}"
else
  PKG_OUT="build/JamfReports-${APP_VERSION}.pkg"
  PKG_VERSION="${APP_VERSION}"
fi

echo "→ staging .app for pkgbuild"
rm -rf "$PKG_STAGING"
mkdir -p "$PKG_STAGING"
cp -R "$APP_PATH" "$PKG_STAGING/JamfReports.app"

# Strip extended attributes that productbuild may otherwise complain about
# (com.apple.quarantine from the original .app download, com.apple.provenance).
xattr -cr "$PKG_STAGING"

echo "→ building component pkg"
rm -f "$COMPONENT_PKG"
pkgbuild \
  --root "$PKG_STAGING" \
  --identifier "$PKG_BUNDLE_ID" \
  --version "$PKG_VERSION" \
  --install-location "/Applications" \
  --ownership recommended \
  "$COMPONENT_PKG"

echo "→ writing Distribution.xml"
# `hostArchitectures="arm64,x86_64"` lets the installer run on both Intel and
# Apple Silicon Macs. `allowed-os-versions` enforces macOS 14+ at install time,
# matching the .app's LSMinimumSystemVersion. `customize="never"` hides the
# component picker since there's only one component.
cat > "$DISTRIBUTION_XML" <<DIST
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<installer-gui-script minSpecVersion="2">
    <title>Jamf Reports</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <allowed-os-versions>
        <os-version min="14.0"/>
    </allowed-os-versions>
    <volume-check>
        <allowed-os-versions>
            <os-version min="14.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="${PKG_BUNDLE_ID}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${PKG_BUNDLE_ID}" visible="false">
        <pkg-ref id="${PKG_BUNDLE_ID}"/>
    </choice>
    <pkg-ref id="${PKG_BUNDLE_ID}" version="${PKG_VERSION}" onConclusion="none">JamfReports-component.pkg</pkg-ref>
</installer-gui-script>
DIST

echo "→ building distribution pkg"
rm -f "$PKG_UNSIGNED"
productbuild \
  --distribution "$DISTRIBUTION_XML" \
  --package-path "build" \
  "$PKG_UNSIGNED"

# Resolve Developer ID Installer identity.
# Match by team ID inside the cert name — stable across cert renewals.
TEAM_ID="${TEAM_ID:-HH6NWGU4G8}"
if [[ -z "${INSTALLER_IDENTITY:-}" ]]; then
  INSTALLER_IDENTITY=$(security find-identity -v 2>/dev/null \
    | awk -v team="(${TEAM_ID})" '
        /Developer ID Installer/ && index($0, team) { print $2; exit }
      ')
  if [[ -z "$INSTALLER_IDENTITY" ]]; then
    echo "✗ no Developer ID Installer identity for team $TEAM_ID found." >&2
    echo "  Request one at developer.apple.com → Certificates → Developer ID Installer," >&2
    echo "  install it into your keychain, then re-run." >&2
    echo "  Override with INSTALLER_IDENTITY=<hash-or-name> or TEAM_ID=<team>." >&2
    exit 1
  fi
fi

echo "→ signing pkg: $INSTALLER_IDENTITY"
rm -f "$PKG_OUT"
productsign --sign "$INSTALLER_IDENTITY" --timestamp "$PKG_UNSIGNED" "$PKG_OUT"

# Verify the signature took. productsign exits 0 on success, but verifying
# closes the silent-failure gap.
if ! pkgutil --check-signature "$PKG_OUT" >/dev/null 2>&1; then
  echo "✗ pkg signature verification failed for $PKG_OUT" >&2
  exit 1
fi

rm -f "$PKG_UNSIGNED" "$COMPONENT_PKG" "$DISTRIBUTION_XML"
rm -rf "$PKG_STAGING"

# Notarize when: release mode, real identity, SKIP_NOTARIZE not set.
# Auth: NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER (API key) or keychain profile.
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
if [[ "$CONFIG" == "release" && -z "${SKIP_NOTARIZE:-}" ]]; then
  echo "→ submitting pkg to Apple notary service ($NOTARY_AUTH_DESC)"
  if ! xcrun notarytool submit "$PKG_OUT" \
       "${NOTARY_AUTH_ARGS[@]}" \
       --wait; then
    echo "✗ notarization failed" >&2
    exit 1
  fi
  echo "→ stapling notarization ticket"
  xcrun stapler staple "$PKG_OUT"
  echo "✓ notarized + stapled"
fi

echo "✓ $PKG_OUT"
echo "  size: $(du -sh "$PKG_OUT" | awk '{print $1}')"
