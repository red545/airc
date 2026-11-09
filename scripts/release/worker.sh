#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
mkdir "$ROOT/build/.release-running"
source "$ROOT/build/release.env"
trap 'rm -f "$ROOT/build/release.env"; rmdir "$ROOT/build/.release-running"' EXIT
export AIRC_TELEMETRY_ENABLED=0 AIRC_MEDIA_PROMPT_CHECKS=0
out="$ROOT/build/stable-stage"
mkdir -p "$out/evidence"
[[ -f "$out/started-at" ]] || date +%s > "$out/started-at"
start=$(cat "$out/started-at")
if [[ ! -f "$out/package.done" ]]; then
scripts/release/package.sh --output "$out/package" --notary-profile "$AIRC_NOTARY_PROFILE" > "$out/evidence/package.log" 2>&1
mv "$out/package/Airc-$AIRC_RELEASE_VERSION-$AIRC_RELEASE_BUILD.dmg" "$out/Airc-$AIRC_RELEASE_VERSION.dmg"
cp "$out/package/Airc.app/Contents/Info.plist" "$out/Info.plist"
touch "$out/package.done"
fi
python3 scripts/ui-check-lock.py scripts/release/qualify.sh "$out/Airc-$AIRC_RELEASE_VERSION.dmg" "$out/evidence/install" > "$out/evidence/qualification.log" 2>&1
for kind in delta full; do
 AIRC_PROOF_CHANNEL="$AIRC_RELEASE_CHANNEL" AIRC_PROOF_DIR="$ROOT/build/launchprep-$kind" AIRC_PROOF_FULL=$([[ $kind == full ]] && echo 1 || echo 0) \
 AIRC_PROOF_FROM_IDENTITY="$AIRC_SIGN_IDENTITY" AIRC_PROOF_TO_IDENTITY="$AIRC_SIGN_IDENTITY" \
 python3 scripts/ui-check-lock.py infra/release/test-updater/run.sh > "$out/evidence/sparkle-$kind.log" 2>&1
 cp "$ROOT/build/launchprep-$kind/releases/appcast.xml" "$out/evidence/sparkle-$kind.xml"
done
ditto -c -k --sequesterRsrc --keepParent "$out/package/Airc.app" "$out/Airc-$AIRC_RELEASE_VERSION.zip"
python3 scripts/release/deltas.py "$out/package/Airc.app" "$out" "$HOME/arcfork/updates-cache/public"
python3 scripts/release/manifest.py "$out" docs/release-notes-beta.md "$AIRC_RELEASE_CHANNEL" "$AIRC_RELEASE_QUALIFIED"
cp "$out/package/"*notary-log.json "$out/evidence/"
printf '%s\n' "$(( $(date +%s) - start ))" > "$out/evidence/elapsed-seconds.txt"
# Private logs/metadata are never included in upload's allowlist.
rm -rf "$out/package" "$ROOT/build/launchprep-delta" "$ROOT/build/launchprep-full" "$ROOT/build/release-tool-home"
echo 'PASS release staged (not published)'
