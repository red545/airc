#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run the app's dialog suite in a new scratch home, without activating the app.
# Build first with CHROMIUM_OUT=<variant> scripts/build-app.sh --no-test.
set -euo pipefail
app=${1:?Usage: app-dialogs.sh Airc-Chromium.app fresh-output-directory}
output=${2:?missing fresh output directory}
[[ ! -e "$output" ]] || { echo "Refusing to reuse $output" >&2; exit 1; }
mkdir -p "$output/Library" "$output/out" "$output/Dialogs/Chromium"
output=$(cd "$output" && pwd)
open -g -n -W --env "CFFIXED_USER_HOME=$output" \
  --stderr "$output/stderr.log" --stdout "$output/stdout.log" "$app" --args \
  --engine=chromium --snapshot "$output/out" --script dialogs \
  --data-dir "$output/Dialogs" --airc-data-dir="$output/Dialogs" --airc-test=modalDialogs
cat "$output/out/log.txt"
grep -qx '\[dialogs\]' "$output/out/log.txt"
! grep -q '^FAIL' "$output/out/log.txt"
! grep -Eq 'Received signal|FATAL:|Check failed:' "$output/stderr.log"
