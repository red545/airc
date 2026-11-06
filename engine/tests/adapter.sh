#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run from repo root on the build Mac, with a signed host from engine/host/build.sh.
set -euo pipefail
host=${1:?Usage: engine/tests/adapter.sh SIGNED_HOST_APP NEW_SCRATCH_DIR}
scratch=${2:?A fresh scratch directory is required}
[[ ! -e "$scratch" ]] || { echo 'Scratch directory already exists' >&2; exit 1; }
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd)
cp -cR "$host" "$scratch/AircHost.app"
app="$scratch/AircHost.app"
swiftc -warnings-as-errors -I engine/core/public \
  apps/browser/Sources/Airc/Engine/BrowserEngine.swift \
  apps/browser/Sources/Airc/Engine/ChromiumEngine.swift engine/tests/adapter.swift \
  "$app/Contents/Frameworks/Airc Framework.framework/Airc Framework" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/AircHost"
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$(dirname "$host")/entitlements/app.plist" "$app"
codesign --verify --deep --strict "$app"
open -g -n -W --stdout "$scratch/run.log" --stderr "$scratch/run.log" "$app" --args \
  --engine=chromium --user-data-dir="$scratch/profile" --adapter-report="$scratch/result.txt" \
  --use-mock-keychain --disable-backgrounding-occluded-windows
cat "$scratch/result.txt"
grep -q '^PASS ' "$scratch/result.txt"
