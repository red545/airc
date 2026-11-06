#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Daytime continuous shipping: whenever main has new commits and no other run is active, run
# `infra/nightly.sh --ship` (Chromium-gated build, test and publish to the dev channel).
#
#   tmux new -d -s airc-ship infra/ship-loop.sh     run until stopped (tmux kill-session -t airc-ship)
#
# Env: AIRC_SHIP_QUIET (seconds the newest commit must be old before a run starts, default 120, so an agent's
# series of commits lands in one build), AIRC_STATUS_DIR (default ../status next to the repo).
# A red run is not retried until main moves again; a run that found the Mac offline is retried.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS="${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}"
QUIET="${AIRC_SHIP_QUIET:-120}"
LOG="$STATUS/ship-loop.log"
last=""

note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
link_ok() {
  local t0 t1 limit=${AIRC_SHIP_MIN_LINK_SECONDS:-10}
  t0=$(date +%s)
  timeout $((limit + 5)) ssh -o ConnectTimeout=15 "${AIRC_MAC_HOST:-mac}" 'head -c 2000000 /dev/zero' > /dev/null 2>&1 || return 1
  t1=$(date +%s)
  (( t1 - t0 <= limit ))
}

note "ship loop started"
while true; do
  head=$(git -C "$ROOT" rev-parse HEAD)
  newest=$(git -C "$ROOT" log -1 --format=%ct)
  # A slow Mac uplink (the owner's laptop on a weak network) turns the 190 MB publish copy into hours with the lock
  # held: wait until 2 MB come back from the Mac within 10 s (AIRC_SHIP_MIN_LINK_SECONDS), checked every 10 minutes.
  if [[ $head != "$last" ]] && (( $(date +%s) - newest >= QUIET )) && ! link_ok; then
    note "Mac link slow; waiting"
    sleep 540
  elif [[ $head != "$last" ]] && (( $(date +%s) - newest >= QUIET )) && flock -n "$STATUS/.lock" true; then
    note "run for $(git -C "$ROOT" rev-parse --short HEAD)"
    "$ROOT/infra/nightly.sh" --ship >> "$LOG" 2>&1
    run=$(ls -td "$STATUS"/runs/*/ 2>/dev/null | head -1)
    if grep -q $'^mac-online\t0' "$run/steps.tsv" 2>/dev/null; then
      last=$head
      note "finished: $(awk -F'\t' '$1=="publish-dev"{print "publish-dev exit " $2}' "$run/steps.tsv")"
    else
      note "Mac offline; retrying"
    fi
  fi
  sleep 60
done
