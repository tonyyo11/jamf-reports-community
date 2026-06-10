#!/bin/zsh
# Sign a macOS app bundle with a Developer ID certificate.
# Walks the app deepest-first (frameworks → binary) to ensure proper order.
# Exits 1 on signing failure or verification failure.
#
# Usage: ./sign-release.sh "Developer ID Application: Tony Young (XXXXXXXXXX)"

set -euo pipefail

readonly DEVELOPER_ID_APP="${1:?Developer ID Application identity required (e.g. 'Developer ID Application: Tony Young (XXXXXXXXXX)')}"
readonly APP_PATH="$(cd -- "$(dirname -- "$0")/../build/JamfReports.app" && pwd -P)"

if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ App bundle not found: $APP_PATH" >&2
  exit 1
fi

echo "Signing app bundle at: $APP_PATH"
echo "Using identity: $DEVELOPER_ID_APP"
echo

# Verify identity exists in keychain
if ! security find-identity -p codesigning | grep -q "$DEVELOPER_ID_APP"; then
  echo "✗ Identity not found in keychain: $DEVELOPER_ID_APP" >&2
  echo "   Available identities:" >&2
  security find-identity -p codesigning >&2
  exit 1
fi

# Sign frameworks (deepest-first)
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  echo "→ Signing frameworks..."
  find "$APP_PATH/Contents/Frameworks" -name "*.framework" -type d | while read -r framework; do
    echo "  Signing: $(basename "$framework")"
    codesign \
      --verbose=4 \
      --force \
      --options runtime \
      --entitlements "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/JamfReports.entitlements" \
      --sign "$DEVELOPER_ID_APP" \
      "$framework"
  done
fi

# Sign dylibs in Frameworks (if any)
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  echo "→ Signing dylibs in Frameworks..."
  find "$APP_PATH/Contents/Frameworks" -name "*.dylib" -type f | while read -r dylib; do
    echo "  Signing: $(basename "$dylib")"
    codesign \
      --verbose=4 \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID_APP" \
      "$dylib"
  done
fi

# Sign main binary
echo "→ Signing main executable..."
codesign \
  --verbose=4 \
  --force \
  --options runtime \
  --entitlements "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/JamfReports.entitlements" \
  --sign "$DEVELOPER_ID_APP" \
  "$APP_PATH/Contents/MacOS/JamfReports"

# Verify signature
echo
echo "→ Verifying signature..."
if ! codesign --verify --strict --deep "$APP_PATH"; then
  echo "✗ Signature verification failed" >&2
  exit 1
fi

echo "✓ Signature valid"
