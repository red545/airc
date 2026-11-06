#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run from repository root on macOS after building the selected framework.
set -euo pipefail
variant=${1:?dev or release}
run=${2:?fresh output directory}
case "$variant" in
  dev) export CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/Airc" ;;
  release) export CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" ;;
  *) exit 2 ;;
esac
[[ ! -e "$run" ]] || { echo 'Output directory must be fresh' >&2; exit 2; }
mkdir -p "$run"
engine/host/build.sh "$run/host" > "$run/build.log" 2>&1
app="$run/host/AircHost.app"
status=0
for scenario in features isolation memory synthetic-extension; do
  args=("$app" "$run/$scenario")
  [[ $scenario == isolation ]] || args+=("$scenario")
  if node engine/host/acceptance.mjs "${args[@]}" > "$run/$scenario.log" 2>&1; then
    echo "PASS $variant $scenario"
  else echo "FAIL $variant $scenario"; status=1; fi
done
for dialog in platform hybrid auth auth-close beforeunload virtual; do
  if AIRC_NATIVE_CASE="$dialog" node engine/host/acceptance.mjs "$app" "$run/dialog-$dialog" dialogs > "$run/dialog-$dialog.log" 2>&1; then
    echo "PASS $variant dialog-$dialog"
  else echo "FAIL $variant dialog-$dialog"; status=1; fi
done
exit "$status"
