#!/bin/zsh
# Generate a Sparkle appcast XML snippet for a release.
# Reads DMG, calls sign_update to generate signature, and outputs XML.
# Exits 1 on missing dependencies, missing files, or signing failure.
#
# Usage:
#   Release build:  ./sparkle-appcast.sh 2.1.0
#   Beta build:     ./sparkle-appcast.sh 2.0.0 101 beta
#
# Arguments:
#   $1 VERSION       Marketing version (CFBundleShortVersionString). N.N or N.N.N.
#   $2 BUILD         Build number (CFBundleVersion). Defaults to VERSION (release).
#                    For betas, pass the build number you set in Info.plist.
#                    sparkle:version uses BUILD — this is what Sparkle compares.
#   $3 CHANNEL       Optional channel name (e.g. "beta"). Emits a <sparkle:channel>
#                    tag the app filters on via SPUUpdaterDelegate.allowedChannels.
#                    Omit for the default (stable) channel.
#
# Set SPARKLE_BIN_DIR to locate sign_update binary:
#   SPARKLE_BIN_DIR=/path/to/Sparkle/bin ./sparkle-appcast.sh 2.1.0

set -euo pipefail

readonly VERSION="${1:?Version required (e.g. 2.1.0)}"
readonly BUILD="${2:-$VERSION}"
readonly CHANNEL="${3:-}"

# Validate inputs strictly so generated XML stays well-formed. The appcast is
# the trust anchor for auto-updates; a typo in a release variable must not be
# able to produce a malformed feed. The allowed character sets are XML-safe by
# construction, so no escaping is needed downstream.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✗ invalid VERSION: '$VERSION' (want N.N or N.N.N)" >&2
  exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "✗ invalid BUILD: '$BUILD' (want alphanumerics, dot, underscore, dash)" >&2
  exit 1
fi
if [[ -n "$CHANNEL" && ! "$CHANNEL" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "✗ invalid CHANNEL: '$CHANNEL' (want lowercase alphanumeric + dash, e.g. 'beta')" >&2
  exit 1
fi
WORK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly WORK_DIR
if [[ "$BUILD" != "$VERSION" ]]; then
  readonly DMG_PATH="${WORK_DIR}/build/JamfReports-${VERSION}-beta${BUILD}.dmg"
  readonly APPCAST_OUT="${WORK_DIR}/build/appcast-${VERSION}-beta${BUILD}.xml"
else
  readonly DMG_PATH="${WORK_DIR}/build/JamfReports-${VERSION}.dmg"
  readonly APPCAST_OUT="${WORK_DIR}/build/appcast-${VERSION}.xml"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "✗ DMG not found: $DMG_PATH" >&2
  exit 1
fi

# Locate sign_update binary
SIGN_UPDATE=""
if [[ -n "${SPARKLE_BIN_DIR:-}" ]]; then
  SIGN_UPDATE="${SPARKLE_BIN_DIR}/sign_update"
else
  # Homebrew Cask installs sign_update under Caskroom — Apple Silicon at
  # /opt/homebrew, Intel at /usr/local. Take the first match (Homebrew Cask
  # keeps only the active version on disk except briefly during upgrade).
  for prefix in /opt/homebrew /usr/local; do
    if [[ -d "${prefix}/Caskroom/sparkle" ]]; then
      candidate=$(find "${prefix}/Caskroom/sparkle" \
        -name sign_update -type f -perm -u+x 2>/dev/null | head -1)
      if [[ -n "$candidate" ]]; then
        SIGN_UPDATE="$candidate"
        break
      fi
    fi
  done
fi

if [[ -z "$SIGN_UPDATE" ]] || [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "✗ sign_update binary not found" >&2
  echo "   Set SPARKLE_BIN_DIR=/path/to/Sparkle/bin or install Sparkle via Homebrew" >&2
  echo "   Homebrew: brew install sparkle" >&2
  exit 1
fi

# Get DMG file size (bytes); Sparkle requires it on the <enclosure> tag.
DMG_SIZE=$(stat -f%z "$DMG_PATH")

echo "→ Generating Sparkle signature..."
SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" | head -1)

if [[ -z "$SIGNATURE" ]]; then
  echo "✗ Failed to generate signature with sign_update" >&2
  exit 1
fi

# Compose channel tag + DMG URL filename based on whether this is a beta.
if [[ "$BUILD" != "$VERSION" ]]; then
  TITLE="Version ${VERSION} beta ${BUILD}"
  DESCRIPTION="Version ${VERSION} beta ${BUILD}"
  DMG_FILENAME="JamfReports-${VERSION}-beta${BUILD}.dmg"
  RELEASE_TAG="v${VERSION}-beta${BUILD}"
else
  TITLE="Version ${VERSION}"
  DESCRIPTION="Version ${VERSION} release"
  DMG_FILENAME="JamfReports-${VERSION}.dmg"
  RELEASE_TAG="v${VERSION}"
fi

CHANNEL_TAG=""
if [[ -n "$CHANNEL" ]]; then
  CHANNEL_TAG="<sparkle:channel>${CHANNEL}</sparkle:channel>"
fi

# Generate appcast XML snippet.
# sparkle:version    = build number (CFBundleVersion); Sparkle compares this.
# sparkle:shortVersionString = marketing version (CFBundleShortVersionString);
#                              shown to users in the update dialog.
cat > "$APPCAST_OUT" <<APPCAST
  <item>
    <title>${TITLE}</title>
    <description>
      <![CDATA[
        <p>${DESCRIPTION}.</p>
      ]]>
    </description>
    <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S %z')</pubDate>
    ${CHANNEL_TAG}
    <enclosure
      url="https://github.com/tonyyo11/jamf-reports-community/releases/download/${RELEASE_TAG}/${DMG_FILENAME}"
      length="${DMG_SIZE}"
      type="application/octet-stream"
      sparkle:version="${BUILD}"
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
