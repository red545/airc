#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Durable queue consumer; runs independently of the ship lock, retries after link loss.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG=${AIRC_UPDATES_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f "$CONFIG" ]] || source "$CONFIG"
STATUS=${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}
HOST=${AIRC_MAC_HOST:-buildmac}
mkdir -p "$STATUS"
exec 6>"$STATUS/.deferred.lock"
flock -n 6 || exit 0
source "$ROOT/infra/updates/link.sh"
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
while true; do
  if ! link_ok; then
    note 'deferred uploads: link slow; retry in 10 minutes (ship lock not held)'
  else
    jobs=$(timeout 30s ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'ls -1 arcfork/update-jobs 2>/dev/null') || jobs=''
    for stamp in $jobs; do
      [[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$ ]] || continue
      remote="arcfork/update-jobs/$stamp"
      run="$STATUS/runs/$stamp"
      mkdir -p "$run"
      note "deferred uploads: $stamp"
      # Preserve partial transfers and retry; a later build cannot mutate this queued source.
      timeout --kill-after=15s 20m "$ROOT/infra/updates/upload-symbols.sh" "$remote" >> "$run/upload-symbols.log" 2>&1 || continue
      timeout --kill-after=15s 10m rsync -az --partial --timeout=30 "$HOST:$remote/build/snapshots/" "$run/snapshots/" >> "$run/deferred.log" 2>&1 || continue
      timeout 30s ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "rm -rf $remote" || continue
      note "deferred uploads: completed $stamp"
      python3 "$ROOT/infra/status.py" "$STATUS" --live
      if [[ -d "$ROOT/apps/marketing/node_modules" ]]; then
        (cd "$ROOT/apps/marketing" && AIRC_STATUS_DIR="$STATUS" node scripts/sync-status.mjs) >> "$run/site-sync.log" 2>&1 || true
      fi
    done
  fi
  [[ ${1:-} != --once ]] || exit 0
  sleep 600
done
