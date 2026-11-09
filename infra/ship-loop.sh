#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Daytime continuous shipping: whenever main has new commits and no other run is active, run
# `infra/nightly.sh --ship` (Chromium-gated build, test and publish to the dev channel).
#
#   tmux new -d -s airc-ship infra/ship-loop.sh     run until stopped (tmux kill-session -t airc-ship)
#
# Env: AIRC_SHIP_QUIET (seconds the newest commit must be old before a run starts, default 120, so an agent's
# series of commits lands in one build), AIRC_STATUS_DIR (default ../status next to the repo).
# Red runs wait for new commits. Locked-screen and ENV runs retry after three minutes; offline runs also retry.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS="${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}"
QUIET="${AIRC_SHIP_QUIET:-120}"
LOG="$STATUS/ship-loop.log"
last=""

note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

note "ship loop started"
while true; do
  head=$(git -C "$ROOT" rev-parse HEAD)
  newest=$(git -C "$ROOT" log -1 --format=%ct)
  # Only deferred artifact uploads depend on the Mac's uplink speed.
  # The 01:15 UTC cron nightly (and its public Nightly) needs the lock: start nothing from 01:00 to 01:25 UTC.
  hm=$((10#$(date -u +%H%M)))
  if (( hm >= 100 && hm < 125 )); then sleep 60; continue; fi
  if [[ $head != "$last" ]] && (( $(date +%s) - newest >= QUIET )) && flock -n "$STATUS/.lock" true; then
    note "run for $(git -C "$ROOT" rev-parse --short HEAD)"
    "$ROOT/infra/nightly.sh" --ship >> "$LOG" 2>&1
    run=$(ls -td "$STATUS"/runs/*/ 2>/dev/null | head -1)
    if grep -q $'^engine-ready\t75' "$run/steps.tsv" 2>/dev/null; then
      note "waiting for engine owner"
      sleep 60
      continue
    fi
    if python3 "$ROOT/infra/run_result.py" "$run" >> "$LOG"; then
      note "UI environment unavailable; retrying in three minutes"
      sleep 60; sleep 60; sleep 60
      continue
    fi
    # A HEAD counts as tested only once its sources reached the Mac: the Mac can answer the online check and drop
    # before the export (a sleeping laptop's short wakes), which must not mark the HEAD done.
    if grep -q $'^mac-online\t0' "$run/steps.tsv" 2>/dev/null && grep -q $'^export\t0' "$run/steps.tsv" 2>/dev/null; then
      last=$head
      note "finished: $(awk -F'\t' '$1=="publish-dev"{print "publish-dev exit " $2}' "$run/steps.tsv")"
    else
      note "Mac offline; retrying"
    fi
  fi
  sleep 60
done
