#!/bin/zsh
# Renders the alternate app icons on the Mac, like appicon.sh: WebKit (the AircDesign gallery's --html mode) draws
# each variant at 1024 px, sips scales, iconutil packs app-icons/AppIcon-<id>.icns. 16 and 32 px use the small variant.
#   assets/brand/alticons.sh
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
python3 alticons.py
(cd "$REPO/packages/AircDesign" && swift build --product aircdesign-gallery >/dev/null)
G="$REPO/packages/AircDesign/.build/debug/aircdesign-gallery"
mkdir -p app-icons
for name in $(python3 -c 'import json; print(" ".join(json.load(open("build/alt/variants.json"))))'); do
  "$G" --html "$PWD/build/alt/$name-large.html" "$PWD/build/alt/$name-large.png" 512 512 --transparent
  "$G" --html "$PWD/build/alt/$name-small.html" "$PWD/build/alt/$name-small.png" 512 512 --transparent
  SET=build/alt/$name.iconset
  rm -rf "$SET"; mkdir -p "$SET"
  for pt in 16 32 128 256 512; do
    for scale in 1 2; do
      px=$((pt * scale)); suffix=""; (( scale == 2 )) && suffix="@2x"
      src=build/alt/$name-large.png; (( px <= 32 )) && src=build/alt/$name-small.png
      sips -z $px $px "$src" --out "$SET/icon_${pt}x${pt}${suffix}.png" >/dev/null
    done
  done
  iconutil -c icns "$SET" -o "app-icons/AppIcon-$name.icns"
  # A 256 px copy for the contact sheet only (not shipped).
  sips -z 256 256 build/alt/$name-large.png --out "app-icons/AppIcon-$name.png" >/dev/null
done
python3 alticons.py sheet
"$G" --html "$PWD/build/alt/sheet.html" "$PWD/build/alt/sheet.png" 820 340
rm -f app-icons/*.png
ls -la app-icons
