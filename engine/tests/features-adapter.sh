#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
host=${1:?signed host app}
scratch=${2:?fresh scratch directory}
[[ ! -e "$scratch" ]] || exit 2
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd)
cp -cR "$host" "$scratch/AircHost.app"
app="$scratch/AircHost.app"
swiftc -warnings-as-errors -I engine/core/public engine/tests/pass11-adapter/*.swift \
  engine/tests/features-adapter.swift "$app/Contents/Frameworks/Airc Framework.framework/Airc Framework" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/AircHost"
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$(dirname "$host")/entitlements/app.plist" "$app"
open -g -n -W --stdout "$scratch/run.log" --stderr "$scratch/run.log" "$app" --args \
  --engine=chromium --user-data-dir="$scratch/profile" --adapter-report="$scratch/result.txt" \
  --use-mock-keychain --disable-backgrounding-occluded-windows
cat "$scratch/result.txt"
grep -q '^PASS ' "$scratch/result.txt"
