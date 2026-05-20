#!/bin/zsh
# Orchestrate a complete signed, notarized, packaged macOS app release.
# Produces: a signed, notarized .app and a distribution .dmg.
#
# Usage:
#   RELEASE_VERSION=2.0.0 \
#   DEVELOPER_ID_APP="Developer ID Application: Tony Young (XXXXXXXXXX)" \
#   NOTARY_KEYCHAIN_PROFILE="apple-id-profile" \
#   ./scripts/release.sh
#
# All environment variables are required. Exits 1 on missing vars or step failure.

set -euo pipefail

cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Require all release variables upfront
: "${RELEASE_VERSION:?RELEASE_VERSION env var not set (e.g. 2.0.0)}"
: "${DEVELOPER_ID_APP:?DEVELOPER_ID_APP env var not set (e.g. Developer ID Application: Tony Young (XXXXXXXXXX))}"
: "${NOTARY_KEYCHAIN_PROFILE:?NOTARY_KEYCHAIN_PROFILE env var not set (notarytool keychain profile name)}"

export DEVELOPER_ID_APP NOTARY_KEYCHAIN_PROFILE RELEASE_VERSION

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "JamfReports Release Pipeline"
echo "Version: ${RELEASE_VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Step 1: Build release bundle
echo "→ Building release bundle..."
if ! ./build-app.sh release; then
  echo "✗ build-app.sh release failed" >&2
  exit 1
fi
echo "✓ Release bundle built"
echo

# Step 2: Sign with Developer ID
echo "→ Signing app bundle..."
if ! ./scripts/sign-release.sh "${DEVELOPER_ID_APP}"; then
  echo "✗ sign-release.sh failed" >&2
  exit 1
fi
echo "✓ App signed"
echo

# Step 3: Notarize and staple
echo "→ Notarizing and stapling..."
if ! ./scripts/notarize-release.sh "${NOTARY_KEYCHAIN_PROFILE}"; then
  echo "✗ notarize-release.sh failed" >&2
  exit 1
fi
echo "✓ App notarized and stapled"
echo

# Step 4: Package DMG
echo "→ Packaging DMG..."
if ! ./scripts/package-dmg.sh "${RELEASE_VERSION}"; then
  echo "✗ package-dmg.sh failed" >&2
  exit 1
fi
echo "✓ DMG packaged"
echo

# Summary
APP_PATH="$(pwd)/build/JamfReports.app"
DMG_PATH="$(pwd)/build/JamfReports-${RELEASE_VERSION}.dmg"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Release Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "Signed & notarized app:"
echo "  ${APP_PATH}"
echo
echo "Distribution DMG:"
echo "  ${DMG_PATH}"
echo
echo "Next: upload the .dmg to a GitHub Release."
echo
