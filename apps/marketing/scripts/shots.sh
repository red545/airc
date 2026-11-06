#!/usr/bin/env bash
# Renders the homepage's product shots on the build Mac (WebKit, real SF fonts) and converts them to WebP.
#
#   apps/marketing/scripts/shots.sh
#
# 1. shots.py writes apps/marketing/.shots/*.html from the design mockups, with neutral demo data.
# 2. The build Mac renders each one at 1440 × 900 (2880 × 1800 px) with AircDesign's gallery (--html mode).
# 3. optimize-shots.mjs writes the WebP files into src/assets/shots/ (Astro then makes the responsive sizes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="$ROOT/apps/marketing"

python3 "$APP/scripts/shots.py"
names=$(cd "$APP/.shots" && ls *.html | sed 's/\.html$//' | tr '\n' ' ')

"$ROOT/scripts/mac.sh" -w homepage run "
  set -e
  swift build --package-path packages/AircDesign --product aircdesign-gallery >/dev/null
  G=\$PWD/packages/AircDesign/.build/debug/aircdesign-gallery
  mkdir -p apps/marketing/.shots/png
  for n in $names; do \$G --html \$PWD/apps/marketing/.shots/\$n.html \$PWD/apps/marketing/.shots/png/\$n.png 1440 900; done
  ls apps/marketing/.shots/png"
"$ROOT/scripts/mac.sh" -w homepage get apps/marketing/.shots/png/ "$APP/.shots/png/"
node "$APP/scripts/optimize-shots.mjs"
