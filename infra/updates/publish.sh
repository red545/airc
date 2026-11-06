#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Linux entrypoint: publish an already built owner Chromium bundle after a fresh launch check.
#   infra/updates/publish.sh [REMOTE]   REMOTE: the build copy on the Mac (default arcfork/nightly)
# Config: the operator's airc.env beside the checkout (AIRC_UPDATES_CONFIG overrides; never committed). Evidence goes to
# artifacts/release/dev-channel beside the checkout (AIRC_ARTIFACTS_DIR overrides).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG=${AIRC_UPDATES_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f "$CONFIG" ]] || source "$CONFIG"
: "${AIRC_UPDATE_FEED:?Set AIRC_UPDATE_FEED in local updates.env}"
HOST=${AIRC_MAC_HOST:-mac}
REMOTE=${1:-arcfork/nightly}
[[ "$REMOTE" =~ ^arcfork/[a-zA-Z0-9/_-]+$ ]] || exit 2
DIR=${AIRC_UPDATES_DIR:-$(dirname "$ROOT")/updates}
EVIDENCE=${AIRC_ARTIFACTS_DIR:-$(dirname "$ROOT")/artifacts}/release/dev-channel
mkdir -p "$DIR" "$EVIDENCE"
exec 8>"$DIR/.publish.lock"
flock -n 8 || { echo "another publish is running ($DIR/.publish.lock)" >&2; exit 1; }
STAGE=$(mktemp -d "$EVIDENCE/publish.XXXXXX")
# Send the prepare helper and its signing/smoke dependencies together, without deleting the tested checkout.
scp -q "$ROOT/infra/updates/prepare-mac.sh" "$HOST:$REMOTE/infra/updates/prepare-mac.sh"
scp -q "$ROOT/scripts/release/sign.py" "$ROOT/scripts/release/smoke.sh" \
  "$ROOT/scripts/release/smoke-window.swift" "$ROOT/scripts/release/deltas.py" "$HOST:$REMOTE/scripts/release/"
# Forward only paths, never the keychain password. sign.py unlocks it on the Mac.
printf -v signing 'AIRC_SIGN_IDENTITY=%q AIRC_SIGN_KEYCHAIN=%q AIRC_SIGN_KEYCHAIN_PASSWORD_FILE=%q' \
  "${AIRC_SIGN_IDENTITY:--}" "${AIRC_SIGN_KEYCHAIN:-}" "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:-}"
printf -v feed '%q' "$AIRC_UPDATE_FEED"
timeout --kill-after=15s 10m ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
  "cd $REMOTE && AIRC_UPDATE_FEED=$feed $signing caffeinate -i -s bash infra/updates/prepare-mac.sh" > "$STAGE/prepare.log" 2>&1
for name in update.zip signature.txt Info.plist sha256.txt spctl.txt deltas.json; do
  rsync -a "$HOST:$REMOTE/build/dev-update/$name" "$STAGE/"
done
rsync -a --include='*.delta' --exclude='*' "$HOST:$REMOTE/build/dev-update/" "$STAGE/"
rsync -a "$HOST:$REMOTE/build/dev-update/smoke/" "$STAGE/smoke/"
python3 "$ROOT/infra/updates/publish.py" "$ROOT" "$DIR" "$STAGE" "$AIRC_UPDATE_FEED"
curl --fail --silent --show-error "$AIRC_UPDATE_FEED" > "$STAGE/served-appcast.xml"
build=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleVersion"])' "$STAGE/Info.plist")
[[ $build =~ ^[0-9]{12}$ ]] || exit 1
ssh "$HOST" "touch arcfork/updates-cache/dev/$build/published"
rm -f "$STAGE/"*.delta
rm -f "$STAGE/update.zip"   # published in $DIR; the evidence keeps its sha256
ssh "$HOST" "rm -rf $REMOTE/build/dev-update"
echo "Published; evidence: $STAGE"
# Crash symbols (docs/user/telemetry.md, "Crash reports"): the build's new dSYMs to PostHog. Best effort.
timeout --kill-after=30s 30m "$ROOT/infra/updates/upload-symbols.sh" "$REMOTE" > "$STAGE/upload-symbols.log" 2>&1 \
  || echo "symbols: not uploaded (best effort), see $STAGE/upload-symbols.log"
