#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run things on the build Mac from the Linux box.
#
#   scripts/mac.sh [-w NAME] sync              copy this working tree to the Mac
#   scripts/mac.sh [-w NAME] run 'CMD'         sync, then run CMD in the copy (zsh login shell)
#   scripts/mac.sh [-w NAME] get REMOTE LOCAL  copy a file or folder back from the copy
#   scripts/mac.sh ssh 'CMD'                   run CMD on the Mac without syncing
#
# Each NAME gets its own copy at ~/arcfork/work/NAME on the Mac, so parallel agents don't share
# build folders. Defaults: NAME=main, host = ssh alias "mac" (override with AIRC_MAC_HOST).
set -euo pipefail

HOST="${AIRC_MAC_HOST:-mac}"
NAME="main"
if [[ "${1:-}" == "-w" ]]; then NAME="$2"; shift 2; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="arcfork/work/$NAME"

sync() {
  ssh "$HOST" "mkdir -p $REMOTE"
  rsync -az --delete \
    --exclude .git/ --exclude .build/ --exclude build/ --exclude DerivedData/ \
    --exclude node_modules/ --exclude dist/ --exclude out/ --exclude /artifacts/ \
    "$ROOT/" "$HOST:$REMOTE/"
}

case "${1:-}" in
  sync) sync ;;
  run)  shift; sync; ssh "$HOST" "cd $REMOTE && zsh -lc $(printf '%q' "$*")" ;;
  get)  rsync -az "$HOST:$REMOTE/$2" "$3" ;;
  ssh)  shift; ssh "$HOST" "zsh -lc $(printf '%q' "$*")" ;;
  *)    sed -n '2,11p' "$0"; exit 1 ;;
esac
