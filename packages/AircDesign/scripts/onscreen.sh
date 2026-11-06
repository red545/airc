#!/bin/zsh
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Shows the on-screen checks (translucency over a busy wallpaper, the floating onboarding window and its
# expansion, the material's response, sidebar ink) in a background app that never takes focus, captures only its own
# windows, and quits. Usage: scripts/onscreen.sh [out-dir] [floating|ink]   (default build/onscreen-<time>)
# Needs an unlocked screen: on a locked or sleeping display captures come back empty.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(ioreg -n Root -d1)" == *'"CGSSessionScreenIsLocked"=Yes'* ]]; then
  echo "The screen is locked; on-screen checks need it unlocked. Nothing was run." >&2
  exit 3
fi
swift build --product aircdesign-gallery >/dev/null
APP=build/AircDesignOnscreen.app
OUT="${1:-$PWD/build/onscreen-$(date +%H%M%S)}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$OUT"
cp .build/debug/aircdesign-gallery "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>aircdesign-gallery</string>
<key>CFBundleIdentifier</key><string>dev.airc.design.onscreen</string>
<key>CFBundleName</key><string>AircDesign Onscreen</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
open -g -W -n "$APP" --args --onscreen "$OUT" ${2:-}
cat "$OUT/onscreen.log"
