#!/bin/zsh
# Compile the Icon Composer document AppIcon.icon into the files the app bundle ships.
# Output: ../Resources/Assets.car (layered Liquid Glass icon, plus flat images macOS 15
# reads through CFBundleIconName) and ../Resources/AppIcon.icns (last-resort fallback).
# Needs an actool that reads .icon documents (Xcode 26 or later). The outputs are
# committed, so build-app.sh never runs this on an older Xcode.

set -euo pipefail

cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun actool AppIcon.icon \
  --compile "$work" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$work/partial.plist" \
  --errors --warnings --output-format human-readable-text

for f in Assets.car AppIcon.icns; do
  [[ -f "$work/$f" ]] || { echo "✗ actool wrote no $f for AppIcon.icon" >&2; exit 1; }
done

mkdir -p ../Resources
cp "$work/Assets.car" "$work/AppIcon.icns" ../Resources/

echo "✓ wrote $(cd ../Resources && pwd)/Assets.car and AppIcon.icns"
