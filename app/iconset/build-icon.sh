#!/bin/zsh
# Render the Spectrum icon at every size macOS expects, package as .icns.
# Output: ../Resources/AppIcon.icns

set -euo pipefail

cd "$(dirname "$0")"

echo "→ render 1024×1024 base"
python3 generate-spectrum.py

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# macOS expects these specific filenames inside an .iconset directory.
# Pairs of {logical-size, @2x flag}.
sizes=(
  "16    icon_16x16.png"
  "32    icon_16x16@2x.png"
  "32    icon_32x32.png"
  "64    icon_32x32@2x.png"
  "128   icon_128x128.png"
  "256   icon_128x128@2x.png"
  "256   icon_256x256.png"
  "512   icon_256x256@2x.png"
  "512   icon_512x512.png"
  "1024  icon_512x512@2x.png"
)
for entry in "${sizes[@]}"; do
  size="${entry%% *}"
  name="${entry##* }"
  sips -z "$size" "$size" AppIcon-1024.png --out "$ICONSET/$name" >/dev/null
done

mkdir -p ../Resources
iconutil -c icns "$ICONSET" -o ../Resources/AppIcon.icns

echo "✓ wrote $(pwd)/../Resources/AppIcon.icns ($(stat -f %z ../Resources/AppIcon.icns) bytes)"
