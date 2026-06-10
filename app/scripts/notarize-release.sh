#!/bin/zsh
# Notarize a macOS app bundle via xcrun notarytool and staple the ticket.
# Exits 1 on notarization rejection, stapling failure, or signature verification failure.
#
# Usage: ./notarize-release.sh "keychain-profile-name"

set -euo pipefail

readonly NOTARY_PROFILE="${1:?Keychain profile name required (run: xcrun notarytool store-credentials)}"

# Resolve APP_PATH before declaring readonly so a failed cd is loud.
APP_PATH_RAW="$(cd -- "$(dirname -- "$0")/../build/JamfReports.app" && pwd -P)"
readonly APP_PATH="$APP_PATH_RAW"

if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ App bundle not found: $APP_PATH" >&2
  exit 1
fi

# Create temp dir and install cleanup trap immediately so the temp dir is
# removed on any exit, including early failures above.
TEMP_DIR="$(mktemp -d)"
readonly TEMP_DIR
readonly ZIP_PATH="${TEMP_DIR}/JamfReports.zip"
NOTARY_OUTPUT="$(mktemp)"
trap 'rm -rf -- "$TEMP_DIR" "$NOTARY_OUTPUT"' EXIT

# Verify signature before notarization
echo "→ Verifying signature before notarization..."
if ! codesign --verify --strict --deep "$APP_PATH"; then
  echo "✗ Signature verification failed — cannot notarize unsigned app" >&2
  exit 1
fi
echo "✓ Signature verified"
echo

# Create ZIP for notarization
echo "→ Creating temporary ZIP for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "✓ ZIP created: $ZIP_PATH"
echo

# Submit for notarization
echo "→ Submitting to Apple notarization..."
echo "  (Using profile: $NOTARY_PROFILE)"

if ! xcrun notarytool submit \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  "$ZIP_PATH" \
  > "$NOTARY_OUTPUT" 2>&1; then
  echo "✗ Notarization submission failed" >&2
  cat "$NOTARY_OUTPUT" >&2
  exit 1
fi

# Parse notarization result. notarytool (unlike the legacy altool) prints
# "status: Accepted" on success and "status: Invalid" on rejection — the submit
# exit code above is authoritative, this is the belt-and-suspenders status check.
if ! grep -q "status: Accepted" "$NOTARY_OUTPUT"; then
  echo "✗ Notarization rejected or timed out" >&2
  cat "$NOTARY_OUTPUT" >&2
  exit 1
fi

echo "✓ Notarization successful"
cat "$NOTARY_OUTPUT"
echo

# Staple the ticket
echo "→ Stapling notarization ticket to app..."
if ! xcrun stapler staple "$APP_PATH"; then
  echo "✗ Stapling failed" >&2
  exit 1
fi
echo "✓ Ticket stapled"
echo

# Verify signature after stapling
echo "→ Verifying signature after stapling..."
if ! codesign --verify --strict --deep "$APP_PATH"; then
  echo "✗ Signature verification failed after stapling" >&2
  exit 1
fi
echo "✓ Signature verified"
