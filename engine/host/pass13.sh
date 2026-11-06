#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run from the synced work copy on the build Mac. Does not build Chromium.
set -euo pipefail
out=${1:-build/pass13}
[[ ! -e "$out" ]] || { echo 'Use a fresh output directory' >&2; exit 1; }
mkdir -p "$out"
export CHROMIUM_OUT="${CHROMIUM_OUT:-$HOME/arcfork/chromium/src/out/AircRelease}"
engine/host/build.sh "$out/host" > "$out/host-build.log" 2>&1
node engine/host/acceptance.mjs "$out/host/AircHost.app" "$out/fake-ui" pass13 > "$out/fake-ui.log" 2>&1
AIRC_CAPTURE_INDICATOR=1 node engine/host/acceptance.mjs "$out/host/AircHost.app" "$out/indicator" pass13 > "$out/indicator.log" 2>&1
node engine/host/acceptance.mjs "$out/host/AircHost.app" "$out/memory" memory > "$out/memory.log" 2>&1
node engine/host/acceptance.mjs "$out/host/AircHost.app" "$out/isolation" > "$out/isolation.log" 2>&1
echo 'PASS pass13 fake UI, capture indicator, restart downloads, memory and profile isolation'
