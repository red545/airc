#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Linux coordinator. Payloads and signing keys stay on the build Mac; only metadata returns.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG=${AIRC_UPDATES_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f "$CONFIG" ]] || source "$CONFIG"
HOST=${AIRC_MAC_HOST:-mac}
REMOTE=${1:-arcfork/nightly}
[[ "$REMOTE" =~ ^arcfork/[a-zA-Z0-9/_-]+$ ]] || exit 2
DIR=${AIRC_UPDATES_DIR:-$(dirname "$ROOT")/updates}
EVIDENCE=${AIRC_ARTIFACTS_DIR:-$(dirname "$ROOT")/artifacts}/release/dev-channel
mkdir -p "$DIR/dev" "$EVIDENCE"
exec 8>"$DIR/.publish.lock"
flock -n 8 || { echo 'another publish is running' >&2; exit 1; }
STAGE=$(mktemp -d "$EVIDENCE/publish.XXXXXX")
LOCAL_FEED=http://127.0.0.1:3483/appcast.xml
# Read the built revision: HEAD may have advanced while the Mac was testing.
revision=$(timeout 30s ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
  "plutil -extract AircRevision raw -o - $REMOTE/build/Airc-Chromium.app/Contents/Info.plist")
[[ $revision =~ ^[0-9a-f]{7,40}$ ]] || exit 2
python3 - "$ROOT" "$STAGE/source.json" "$revision" <<'PY'
import json, pathlib, subprocess, sys
root,out,revision=sys.argv[1:]
def git(*a): return subprocess.check_output(['git','-C',root,*a],text=True).strip()
pathlib.Path(out).write_text(json.dumps(dict(revision=git('rev-parse',revision+'^{commit}'),notes=git('log','-15','--format=%s',revision))))
PY
timeout 45s scp -q "$STAGE/source.json" "$HOST:$REMOTE/build/dev-source.json"
# Bootstrap the retained-source journal without bringing any archive back across the link.
if [[ -f "$DIR/dev/appcast.xml" ]]; then
  timeout 45s scp -q "$DIR/dev/appcast.xml" "$HOST:$REMOTE/build/dev-seed.xml"
fi
printf -v signing 'AIRC_SIGN_IDENTITY=%q AIRC_SIGN_KEYCHAIN=%q AIRC_SIGN_KEYCHAIN_PASSWORD_FILE=%q' \
  "${AIRC_SIGN_IDENTITY:--}" "${AIRC_SIGN_KEYCHAIN:-}" "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:-}"
timeout --kill-after=15s 15m ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
 "cd $REMOTE && AIRC_UPDATE_FEED=$LOCAL_FEED $signing caffeinate -i -s bash infra/updates/publish-local.sh" > "$STAGE/prepare.log" 2>&1
# No archives, dSYMs, smoke images or snapshot trees on the synchronous path.
for name in Info.plist signature.txt sha256.txt published-sha256.txt deltas.json; do
  timeout 45s rsync -a "$HOST:$REMOTE/build/dev-update/$name" "$STAGE/"
done
for name in appcast.xml published.json; do
  timeout 45s rsync -a "$HOST:arcfork/updates-local/$name" "$STAGE/$name"
  cp "$STAGE/$name" "$DIR/dev/$name.tmp"
  mv "$DIR/dev/$name.tmp" "$DIR/dev/$name"
done
# Old clients still fetch the HTTPS Linux feed, whose new enclosures resolve on their own Mac.
# New clients read the same XML directly over loopback. Keep this bridge until all old clients migrated.
echo "Published locally; metadata and transition feed: $STAGE"
