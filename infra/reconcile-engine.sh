#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Linux engine-owner entry point. Never run from nightly or concurrently with another owner.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATUS=${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}
HOST=${AIRC_MAC_HOST:-buildmac}
[[ $HOST == buildmac ]] || { echo 'engine reconciliation requires the dedicated host'; exit 2; }
mkdir -p "$STATUS"
exec 9>"$STATUS/.lock"
flock 9
[[ ! -e "$STATUS/release-staging" && ! -e "$STATUS/quiet-pending" ]] || exit 75
REV=$(git -C "$ROOT" rev-parse HEAD)
ready=$(awk 'NR==1 {print $1}' "$STATUS/buildmac-engine-ready" 2>/dev/null || true)
if [[ $ready =~ ^[0-9a-f]{40}$ ]] && git -C "$ROOT" diff --quiet "$ready" "$REV" -- engine/core engine/patches ':(glob)engine/*.gn' ':(glob)engine/*.gni' ':(glob)engine/BUILD*' CHROMIUM_VERSION; then
  echo "engine already ready: $ready"; exit 0
fi
(set -C; printf 'buildmac-reconcile pid=%s revision=%s\n' "$$" "$REV" > "$STATUS/relink-pending")
trap 'rm -f "$STATUS/relink-pending"' EXIT
exec 8>"$STATUS/.agent-build.lock"
flock 8
# A failed/partial build must never leave an old ready attestation visible.
if [[ -f "$STATUS/buildmac-engine-ready" ]]; then
  cat "$STATUS/buildmac-engine-ready" >> "$STATUS/buildmac-engine-history"
  rm "$STATUS/buildmac-engine-ready"
fi
REMOTE=arcfork/setup/routing-engine/current
# Use a fresh source directory per revision, avoiding files removed by later commits.
ssh "$HOST" "mkdir -p ~/$REMOTE-$REV"
git -C "$ROOT" archive "$REV" engine CHROMIUM_VERSION scripts/build-lock.py | ssh "$HOST" "tar -x -C ~/$REMOTE-$REV"
ssh "$HOST" "export DEPOT_TOOLS=\$HOME/arcfork/tools/depot_tools; export PATH=\$DEPOT_TOOLS/python-bin:\$DEPOT_TOOLS:\$PATH; export AIRC_BUILD_LOG=\$HOME/arcfork/setup/routing-engine/engine-$REV.log AIRC_BUILD_JOBS=8; cd ~/$REMOTE-$REV && caffeinate -i -s python3 scripts/build-lock.py bash engine/build.sh --run && python3 engine/apply.py --check"
printf '%s %s\n' "$REV" "$(date -u +%FT%TZ)" > "$STATUS/buildmac-engine-ready.tmp"
mv "$STATUS/buildmac-engine-ready.tmp" "$STATUS/buildmac-engine-ready"
cat "$STATUS/buildmac-engine-ready" | tee -a "$STATUS/buildmac-engine-history"
