#!/bin/zsh
# Build a runnable JamfReports.app bundle from the SwiftPM executable target.
# Usage: ./build-app.sh [debug|release]   (default: release)

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"

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

# Bundle the Python CLI script as a fallback when a `jrc` shim is not installed
# on PATH. The GUI still shells out to the CLI source of truth; it does not
# reimplement report generation in Swift.
if [[ -f "../jamf-reports-community.py" ]]; then
  cp "../jamf-reports-community.py" "$APP_OUT/Contents/Resources/jamf-reports-community.py"
fi
if [[ -f "../requirements.txt" ]]; then
  cp "../requirements.txt" "$APP_OUT/Contents/Resources/requirements.txt"
fi
if [[ -f "requirements-runtime.txt" ]]; then
  cp "requirements-runtime.txt" "$APP_OUT/Contents/Resources/requirements-runtime.txt"
fi
if [[ -f "../config.example.yaml" ]]; then
  cp "../config.example.yaml" "$APP_OUT/Contents/Resources/config.example.yaml"
fi

if [[ -z "${JRC_BUNDLE_PYTHON:-}" ]]; then
  if [[ "$CONFIG" == "release" ]]; then
    JRC_BUNDLE_PYTHON=1
  else
    JRC_BUNDLE_PYTHON=auto
  fi
fi

if [[ "$JRC_BUNDLE_PYTHON" != "0" ]]; then
  echo "→ bundling private Python runtime"
  if ! ./scripts/build-python-runtime.sh "$ARCH" "$APP_OUT/Contents/Resources"; then
    if [[ "$JRC_BUNDLE_PYTHON" == "1" ]]; then
      echo "✗ Python runtime bundling failed" >&2
      exit 1
    fi
    echo "⚠ Python runtime bundling skipped; app will use external Python if available" >&2
  fi
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
    <key>CFBundleVersion</key>
    <string>2.0.0</string>
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

# Ad-hoc sign with Hardened Runtime + explicit entitlements. Distribution still
# requires Developer ID + notarization; this is the local-dev posture.
ENTITLEMENTS="JamfReports.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
  if [[ -d "$APP_OUT/Contents/Resources/python" ]]; then
    echo "→ signing bundled Python components"
    while IFS= read -r -d '' file; do
      case "$file" in
        *.so|*.dylib|*/python|*/python3|*/python3.*)
          if ! codesign --force --sign - --options runtime "$file" >/dev/null; then
            echo "✗ codesign failed for $file" >&2
            exit 1
          fi
          ;;
      esac
    done < <(find "$APP_OUT/Contents/Resources/python" -type f -print0)
  fi
  echo "→ signing $APP_OUT"
  if ! codesign --force --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --deep "$APP_OUT" >/dev/null; then
    echo "✗ codesign failed for $APP_OUT" >&2
    exit 1
  fi
else
  echo "✗ $ENTITLEMENTS missing — refusing to sign without entitlements" >&2
  exit 1
fi

echo "✓ built $APP_OUT"
echo "  open it with:  open $APP_OUT"
