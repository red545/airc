#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Start the first Chromium engine build as soon as the Mac checkout is ready (run from cron every 30 min).
# Later builds are started by infra/nightly.sh. Does nothing once ~/arcfork/airc-engine.log exists.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${AIRC_MAC_HOST:-mac}"
git -C "$ROOT" cat-file -e HEAD:engine/build.sh 2>/dev/null || exit 0
ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" 'zsh -lc "
  [[ -e ~/arcfork/airc-engine.log ]] && exit 0
  tail -n 1 ~/arcfork/fetch-chromium.log 2>/dev/null | grep -q \"EXIT 0\" || exit 0
  screen -ls | grep -q airc-engine && exit 0
  exit 10"'
[[ $? == 10 ]] || exit 0
ssh "$HOST" "rm -rf ~/arcfork/engine-src && mkdir -p ~/arcfork/engine-src" \
  && git -C "$ROOT" archive HEAD | ssh "$HOST" "tar -x -C ~/arcfork/engine-src" \
  && ssh "$HOST" "~/arcfork/engine-src/engine/build.sh --start" \
  && echo "$(date -u) engine build started"
