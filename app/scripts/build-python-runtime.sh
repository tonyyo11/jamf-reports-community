#!/bin/zsh
# Build and copy a private Python runtime into JamfReports.app.
#
# Usage:
#   scripts/build-python-runtime.sh <arm64|x86_64> <Contents/Resources>
#
# Inputs:
#   app/python-runtime.lock       Selects python-build-standalone release/assets.
#   app/requirements-runtime.txt  Pinned Python dependencies to install.
#
# Environment overrides:
#   JRC_PYTHON_LOCK_FILE          Alternate lock file.
#   JRC_RUNTIME_REQUIREMENTS      Alternate requirements file.
#   JRC_PYTHON_CACHE_DIR          Download/build cache directory.
#   JRC_PYTHON_RESOLVE_ONLY=1     Resolve the runtime URL, then exit.
#   JRC_PYTHON_DOWNLOAD_ONLY=1    Download/extract/install, but do not copy.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="${SCRIPT_DIR:h}"
ARCH="${1:?usage: build-python-runtime.sh <arch> <resources-dir>}"
RESOURCES_DIR="${2:?usage: build-python-runtime.sh <arch> <resources-dir>}"

LOCK_FILE="${JRC_PYTHON_LOCK_FILE:-$APP_DIR/python-runtime.lock}"
REQ_FILE="${JRC_RUNTIME_REQUIREMENTS:-$APP_DIR/requirements-runtime.txt}"
CACHE_DIR="${JRC_PYTHON_CACHE_DIR:-$APP_DIR/.build/python-runtime-cache}"

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "✗ Python runtime lock file not found: $LOCK_FILE" >&2
  exit 1
fi
if [[ ! -f "$REQ_FILE" ]]; then
  echo "✗ Python runtime requirements not found: $REQ_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$LOCK_FILE"

PBS_REPO="${PBS_REPO:-astral-sh/python-build-standalone}"
PBS_RELEASE="${PBS_RELEASE:?PBS_RELEASE is required in $LOCK_FILE}"
PBS_PYTHON_SERIES="${PBS_PYTHON_SERIES:?PBS_PYTHON_SERIES is required in $LOCK_FILE}"
PBS_ARCHIVE_VARIANT="${PBS_ARCHIVE_VARIANT:-install_only_stripped}"

case "$ARCH" in
  arm64|aarch64)
    PBS_TARGET="aarch64-apple-darwin"
    ASSET_URL="${PBS_ARM64_URL:-}"
    ASSET_SHA256="${PBS_ARM64_SHA256:-}"
    ASSET_SHA256_VAR="PBS_ARM64_SHA256"
    ;;
  x86_64)
    PBS_TARGET="x86_64-apple-darwin"
    ASSET_URL="${PBS_X86_64_URL:-}"
    ASSET_SHA256="${PBS_X86_64_SHA256:-}"
    ASSET_SHA256_VAR="PBS_X86_64_SHA256"
    ;;
  *)
    echo "✗ unsupported Python runtime architecture: $ARCH" >&2
    exit 1
    ;;
esac

mkdir -p "$CACHE_DIR"

resolve_asset_url() {
  local metadata="$1"
  local pattern="cpython-${PBS_PYTHON_SERIES//./\\.}[^/]*-${PBS_TARGET}-${PBS_ARCHIVE_VARIANT}\\.tar\\.gz"
  grep -E "\"browser_download_url\": \".*${pattern}\"" "$metadata" 2>/dev/null \
    | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/' \
    | head -n 1 \
    || true
}

resolve_assets_url() {
  local metadata="$1"
  grep -E '"assets_url": "' "$metadata" 2>/dev/null \
    | sed -E 's/.*"assets_url": "([^"]+)".*/\1/' \
    | head -n 1 \
    || true
}

if [[ -z "$ASSET_URL" ]]; then
  METADATA_JSON="$CACHE_DIR/${PBS_REPO//\//-}-${PBS_RELEASE}.json"
  echo "→ resolving python-build-standalone asset ($PBS_RELEASE, $PBS_TARGET)"
  curl --fail --location --silent --show-error \
    "https://api.github.com/repos/${PBS_REPO}/releases/tags/${PBS_RELEASE}" \
    --output "$METADATA_JSON"
  ASSET_URL="$(resolve_asset_url "$METADATA_JSON")"
  if [[ -z "$ASSET_URL" ]]; then
    ASSETS_URL="$(resolve_assets_url "$METADATA_JSON")"
    if [[ -n "$ASSETS_URL" ]]; then
      for page in {1..10}; do
        PAGE_JSON="$CACHE_DIR/${PBS_REPO//\//-}-${PBS_RELEASE}-assets-${page}.json"
        curl --fail --location --silent --show-error \
          "${ASSETS_URL}?per_page=100&page=${page}" \
          --output "$PAGE_JSON"
        ASSET_URL="$(resolve_asset_url "$PAGE_JSON")"
        [[ -n "$ASSET_URL" ]] && break
      done
    fi
  fi
fi

if [[ -z "$ASSET_URL" ]]; then
  echo "✗ could not resolve python-build-standalone asset for $PBS_PYTHON_SERIES $PBS_TARGET" >&2
  echo "  Set PBS_ARM64_URL/PBS_X86_64_URL in $LOCK_FILE, or update PBS_RELEASE." >&2
  exit 1
fi

if [[ "${JRC_PYTHON_RESOLVE_ONLY:-0}" == "1" ]]; then
  echo "$ASSET_URL"
  exit 0
fi

if [[ -z "$ASSET_SHA256" ]]; then
  echo "✗ pinned SHA256 required for $ARCH Python runtime asset" >&2
  echo "  Set $ASSET_SHA256_VAR in $LOCK_FILE before downloading, extracting, or copying." >&2
  echo "  Use JRC_PYTHON_RESOLVE_ONLY=1 to resolve the asset URL without a checksum." >&2
  exit 1
fi

ARCHIVE_NAME="${ASSET_URL:t}"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE_NAME"
RUNTIME_KEY="${PBS_RELEASE}-${PBS_PYTHON_SERIES}-${PBS_TARGET}-${PBS_ARCHIVE_VARIANT}"
STAGE_DIR="$CACHE_DIR/stage/$RUNTIME_KEY"
PYTHON_ROOT="$STAGE_DIR/python"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "→ downloading $ARCHIVE_NAME"
  curl --fail --location --retry 3 --show-error "$ASSET_URL" --output "$ARCHIVE_PATH"
else
  echo "→ using cached $ARCHIVE_NAME"
fi

echo "→ verifying SHA256"
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$ASSET_SHA256" ]]; then
  echo "✗ SHA256 mismatch for $ARCHIVE_NAME" >&2
  echo "  expected: $ASSET_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA" >&2
  exit 1
fi

if [[ ! -x "$PYTHON_ROOT/bin/python3" ]]; then
  echo "→ extracting Python runtime"
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  tar -xzf "$ARCHIVE_PATH" -C "$STAGE_DIR"
fi

PYTHON_BIN="$PYTHON_ROOT/bin/python3"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "✗ extracted runtime does not contain bin/python3" >&2
  exit 1
fi

echo "→ installing runtime dependencies"
"$PYTHON_BIN" -m ensurepip --upgrade >/dev/null
"$PYTHON_BIN" -m pip install \
  --disable-pip-version-check \
  --no-cache-dir \
  --only-binary=:all: \
  --requirement "$REQ_FILE"

echo "→ smoke-testing bundled Python imports"
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" - <<'PY'
import matplotlib
import pandas
import yaml
import xlsxwriter
print("python-runtime-ok")
PY

echo "→ trimming Python bytecode caches"
find "$PYTHON_ROOT" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$PYTHON_ROOT" -name "*.pyc" -type f -delete

if [[ "${JRC_PYTHON_DOWNLOAD_ONLY:-0}" == "1" ]]; then
  echo "✓ prepared Python runtime at $PYTHON_ROOT"
  exit 0
fi

echo "→ copying Python runtime into app resources"
rm -rf "$RESOURCES_DIR/python"
ditto --norsrc "$PYTHON_ROOT" "$RESOURCES_DIR/python"

cat > "$RESOURCES_DIR/python-runtime.json" <<EOF
{
  "python_build_standalone_release": "$PBS_RELEASE",
  "python_series": "$PBS_PYTHON_SERIES",
  "target": "$PBS_TARGET",
  "archive_variant": "$PBS_ARCHIVE_VARIANT",
  "archive_url": "$ASSET_URL",
  "sha256": "$ASSET_SHA256"
}
EOF

echo "✓ bundled Python runtime: $RESOURCES_DIR/python/bin/python3"
