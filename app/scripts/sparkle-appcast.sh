#!/bin/zsh
# Generate a Sparkle appcast XML snippet for a release.
# Reads DMG, calls sign_update to generate signature, and outputs XML.
# Exits 1 on missing dependencies, missing files, or signing failure.
#
# Usage: ./sparkle-appcast.sh "2.1.0"
#
# Set SPARKLE_BIN_DIR to locate sign_update binary:
#   SPARKLE_BIN_DIR=/path/to/Sparkle/bin ./sparkle-appcast.sh 2.1.0

set -euo pipefail

readonly VERSION="${1:?Version required (e.g. 2.1.0)}"
readonly WORK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly DMG_PATH="${WORK_DIR}/build/JamfReports-${VERSION}.dmg"
readonly APPCAST_OUT="${WORK_DIR}/build/appcast-${VERSION}.xml"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "✗ DMG not found: $DMG_PATH" >&2
  exit 1
fi

# Locate sign_update binary
SIGN_UPDATE=""
if [[ -n "${SPARKLE_BIN_DIR:-}" ]]; then
  SIGN_UPDATE="${SPARKLE_BIN_DIR}/sign_update"
elif [[ -f "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
  # Common Xcode location (homebrew install)
  SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "sign_update" -type f 2>/dev/null | head -1)"
fi

if [[ -z "$SIGN_UPDATE" ]] || [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "✗ sign_update binary not found" >&2
  echo "   Set SPARKLE_BIN_DIR=/path/to/Sparkle/bin or install Sparkle via Homebrew" >&2
  echo "   Homebrew: brew install sparkle" >&2
  exit 1
fi

# Get DMG file size and modification date
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DMG_MTIME=$(stat -f%m "$DMG_PATH")
DMG_RELEASE_NOTES="JamfReports ${VERSION} release"

echo "→ Generating Sparkle signature..."
SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" | head -1)

if [[ -z "$SIGNATURE" ]]; then
  echo "✗ Failed to generate signature with sign_update" >&2
  exit 1
fi

# Generate appcast XML snippet
cat > "$APPCAST_OUT" <<APPCAST
  <item>
    <title>Version ${VERSION}</title>
    <description>
      <![CDATA[
        <p>Version ${VERSION} release.</p>
      ]]>
    </description>
    <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S %z')</pubDate>
    <enclosure
      url="https://github.com/tonyyo/jamf-reports-community/releases/download/v${VERSION}/JamfReports-${VERSION}.dmg"
      length="${DMG_SIZE}"
      type="application/octet-stream"
      sparkle:version="${VERSION}"
      sparkle:shortVersionString="${VERSION}"
      sparkle:edSignature="${SIGNATURE}"
    />
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  </item>
APPCAST

echo "✓ Appcast XML generated"
echo "  Output: $APPCAST_OUT"
echo
echo "XML snippet (also written to file):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$APPCAST_OUT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
