#!/bin/zsh
# Renders the macOS app icon on the Mac: WebKit (the AircDesign gallery's --html mode) draws the SVGs at
# 1024 px, sips scales them, iconutil packs AppIcon.icns. Sizes 16 and 32 px come from the small-size variant.
#   assets/brand/appicon.sh        (from the repo root or this folder)
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
python3 appicon.py
(cd "$REPO/packages/AircDesign" && swift build --product aircdesign-gallery >/dev/null)
G="$REPO/packages/AircDesign/.build/debug/aircdesign-gallery"
"$G" --html "$PWD/build/appicon-large.html" "$PWD/build/master-large.png" 512 512 --transparent
"$G" --html "$PWD/build/appicon-small.html" "$PWD/build/master-small.png" 512 512 --transparent
sips -g pixelWidth -g pixelHeight build/master-large.png build/master-small.png | grep pixel

SET=build/AppIcon.iconset
rm -rf "$SET" AppIcon.appiconset
mkdir -p "$SET" AppIcon.appiconset
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    suffix=""
    if (( scale == 2 )); then suffix="@2x"; fi
    name="icon_${pt}x${pt}${suffix}.png"
    src=build/master-large.png
    if (( px <= 32 )); then src=build/master-small.png; fi
    sips -z $px $px "$src" --out "$SET/$name" >/dev/null
  done
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$SET"/*.png AppIcon.appiconset/
cat > AppIcon.appiconset/Contents.json <<JSON
{
  "images" : [
$(for pt in 16 32 128 256 512; do for scale in 1 2; do
    suffix=""
    if (( scale == 2 )); then suffix="@2x"; fi
    printf '    { "idiom" : "mac", "size" : "%sx%s", "scale" : "%sx", "filename" : "icon_%sx%s%s.png" },\n' $pt $pt $scale $pt $pt "$suffix"
  done; done | sed '$ s/,$//')
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
python3 appicon.py sheet
"$G" --html "$PWD/build/contact-sheet.html" "$PWD/build/contact-sheet.png" 1120 520
ls -la AppIcon.icns AppIcon.appiconset | head -20
