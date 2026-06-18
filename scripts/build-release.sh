#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --exact-match 2>/dev/null || true)"
fi
if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/build-release.sh <version>" >&2
  echo "example: ./scripts/build-release.sh v1.0.0" >&2
  exit 1
fi

case "$VERSION" in
  v*)
    VERSION_STRIPPED="${VERSION#v}"
    ;;
  *)
    VERSION_STRIPPED="$VERSION"
    VERSION="v$VERSION"
    ;;
esac

DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/jamf-reports-community-$VERSION_STRIPPED"
ARCHIVE_BASENAME="jamf-reports-community-$VERSION.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_BASENAME"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp config.example.yaml "$STAGE_DIR/"
cp CHANGELOG.md "$STAGE_DIR/"
cp README.md "$STAGE_DIR/"

rm -f "$ARCHIVE_PATH"
(
  cd "$DIST_DIR"
  zip -rq "$ARCHIVE_BASENAME" "jamf-reports-community-$VERSION_STRIPPED"
)

echo "Created release bundle: $ARCHIVE_PATH"

# Generate SHA256SUMS alongside the archive so downstream verifiers can
# confirm integrity without relying solely on GitHub's download endpoint.
SUMS_PATH="$DIST_DIR/SHA256SUMS"
(
  cd "$DIST_DIR"
  shasum -a 256 "$ARCHIVE_BASENAME" > SHA256SUMS
)
echo "Created checksum file:   $SUMS_PATH"
