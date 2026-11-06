#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${CHROMIUM_SRC:-$HOME/arcfork/chromium/src}
fetch_log=${AIRC_FETCH_LOG:-$HOME/arcfork/fetch-chromium.log}
export PATH="${DEPOT_TOOLS:-$HOME/arcfork/depot_tools}:$PATH"
export DEPOT_TOOLS_UPDATE=0
mode=--start
variant=release
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start|--run) mode=$1 ;;
    --variant) variant=${2:?missing variant}; shift ;;
    *) echo 'Usage: engine/build.sh [--start|--run] [--variant release|dev]' >&2; exit 2 ;;
  esac
  shift
done
case "$variant" in
  release) out=out/AircRelease; dchecks=false ;;
  dev) out=out/Airc; dchecks=true ;;
  *) echo "Unknown variant: $variant" >&2; exit 2 ;;
esac
log=${AIRC_BUILD_LOG:-$HOME/arcfork/airc-engine-$variant.log}
[[ $(uname -s) == Darwin ]] || { echo 'Run on the build Mac.' >&2; exit 1; }
if [[ $mode == --start ]]; then
  [[ -f $fetch_log && $(tail -n 1 "$fetch_log") == 'EXIT 0' ]] || {
    echo "Checkout is not ready. Inspect $fetch_log; do not retry a failed fetch." >&2; exit 1;
  }
  if screen -ls 2>/dev/null | grep -q '[.]airc-engine[[:space:]]'; then
    echo "airc-engine already exists; log: $log"; exit 0
  fi
  mkdir -p "$(dirname "$log")"
  # caffeinate holds the system awake for the whole shell, GN and Ninja run.
  screen -dmS airc-engine caffeinate -i -s /bin/bash "$here/build.sh" --run --variant "$variant"
  echo "Started airc-engine; log: $log"
  exit 0
fi
[[ -f $fetch_log && $(tail -n 1 "$fetch_log") == 'EXIT 0' ]] || {
  echo "Checkout is not ready; refusing to modify it." >&2; exit 1;
}
lock="$src/.airc-engine-$variant-lock"
mkdir "$lock" 2>/dev/null || { echo "Engine lock exists: $lock (inspect its pid before removing)" >&2; exit 1; }
echo $$ > "$lock/pid"
exec >> "$log" 2>&1
trap 'rc=$?; rm -f "$lock/pid"; rmdir "$lock"; echo "EXIT $rc"' EXIT
echo "START $(date -u +%FT%TZ)"
"$here/apply.sh" --src "$src"
"$here/apply.sh" --check --src "$src"
mkdir -p "$src/$out"
# Deliberately overwrite args only when changed, preserving Ninja's incremental build.
args="$src/$out/args.gn.airc-tmp"
cat > "$args" <<GN
# Release code, one distributable framework (not many component dylibs).
is_debug = false
# User builds match Chrome stable; dev keeps assertions for qualification.
dcheck_always_on = $dchecks
is_component_build = false
# Small object files on the build Mac's limited SSD.
symbol_level = 0
blink_symbol_level = 0
# The newer Xcode SDK can warn on otherwise valid Chromium 156 code.
treat_warnings_as_errors = false
# No official signing, PGO profiles, Google branding or official-build LTO.
is_official_build = false
# Non-official builds otherwise ship an empty chrome://credits resource.
generate_about_credits = true
chrome_pgo_phase = 0
use_thin_lto = false
# Native Apple silicon, the target hardware for this spike.
target_cpu = "arm64"
# Local build; no remote execution service is configured.
use_remoteexec = false
# Compile Airc's framework/helper names and bundle ID, keeping Chromium's assets.
branding_file_path = "//airc/core/BRANDING"
# Runtime CDM delivery only; proprietary binaries and VMP signing are not bundled.
# See DRM.md for the separate Google licensing / certification release gates.
enable_widevine = true
enable_library_cdms = true
bundle_widevine_cdm = false
# Match the reference's ordinary H.264/AAC web playback; no DRM implied.
proprietary_codecs = true
ffmpeg_branding = "Chrome"
GN
if ! cmp -s "$args" "$src/$out/args.gn"; then mv "$args" "$src/$out/args.gn"; else rm "$args"; fi
cd "$src"
gn gen "$out"
# Eight jobs leave capacity for the owner's work; rerunning resumes Ninja. -k 0 keeps going past
# failures so one overnight run reports every compile error, not just the first.
autoninja -k 0 -j "${AIRC_BUILD_JOBS:-8}" -C "$out" chrome_framework
echo "Framework ready: $out/Airc Framework.framework"
