#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run from the build checkout. Only public signing output leaves this machine.
# Every check ends in `|| fail`: macOS's bash 3.2 doesn't stop a set -e script on a false [[ ]].
set -Eeuo pipefail
phase=initialization
failure_line=unknown
trap 'failure_line=$LINENO' ERR
report_exit() {
  local rc=$?
  if [[ $rc != 0 ]]; then
    printf '%s: failed during %s (exit %s, line %s)\n' "${0##*/}" "$phase" "$rc" "$failure_line" >&2
  fi
  exit "$rc"
}
trap report_exit EXIT
echo "${0##*/}: starting"
fail() { echo "prepare-mac.sh: $*" >&2; exit 1; }
phase="validating candidate metadata and signature"
ROOT=$PWD
source infra/updates/dev-paths.sh
: "${AIRC_UPDATE_FEED:?Set the dev feed}"
APP="$ROOT/build/Airc-Chromium.app"
OUT="$ROOT/build/dev-update"
PLIST="$APP/Contents/Info.plist"
readkey() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
[[ $(readkey AircDefaultEngine) == chromium && $(readkey AircDevChannel) == true ]] || fail 'not a dev-channel Chromium build'
[[ $(readkey SUFeedURL) == "$AIRC_UPDATE_FEED" ]] || fail 'the bundle names another feed'
[[ $(readkey SUPublicEDKey) == "$(cat infra/release/sparkle-public-key.txt)" ]] || fail 'the bundle has another public key'
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" && -d "$APP/Contents/Frameworks/Airc Framework.framework" ]] \
  || fail 'Sparkle or the Chromium framework is missing'
codesign --verify --deep --strict "$APP"
rm -rf "$OUT"
mkdir -p "$OUT"
# Preserve the tested ad-hoc bundle. Sign only the exact staged payload after testing;
# distribution signatures intentionally disable the engine's test hooks.
phase="staging the tested app"
ditto "$APP" "$OUT/Airc.app"
STAGED="$OUT/Airc.app/Contents/Info.plist"
# Tested builds carry a test identity (scripts/build-app.sh); the published copy gets the real one back, then is signed.
published=$(/usr/libexec/PlistBuddy -c "Print :AircPublishedBundleID" "$STAGED" 2>/dev/null || true)
if [[ -n "$published" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $published" -c "Delete :AircPublishedBundleID" "$STAGED"
fi
phase="signing the staged app"
identity=${AIRC_SIGN_IDENTITY:--}
if [[ "$identity" != - ]]; then
  : "${AIRC_SIGN_KEYCHAIN:?Developer ID publishing requires the dedicated keychain}"
  : "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:?Set its password file on the build Mac}"
  python3 scripts/release/sign.py "$OUT/Airc.app" "$identity"
  # The final re-sign must preserve the Google CDM exception only on its utility
  # helper. The browser, renderer, GPU, Sparkle and other binaries retain validation.
  python3 scripts/release/check-entitlements.py "$OUT/Airc.app"
  codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$OUT/Airc.app"
elif [[ -n "$published" ]]; then
  python3 scripts/release/sign.py "$OUT/Airc.app" -
fi
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$STAGED") == "${published:-$(readkey CFBundleIdentifier)}" ]] \
  || fail 'the staged copy does not carry the published identity'
codesign --verify --deep --strict --verbose=2 "$OUT/Airc.app"
# Gatekeeper rejects an unnotarized Developer ID app; keep this informational.
spctl -a -vv --type exec "$OUT/Airc.app" > "$OUT/spctl.txt" 2>&1 || true
before=$(codesign -d --verbose=4 "$OUT/Airc.app" 2>&1 | sed -n 's/^CDHash=//p')
# No scripted scenarios or engine test hooks on a distribution-signed app.
phase="signed app launch smoke"
scripts/release/smoke.sh --plain-only "$OUT/Airc.app" "$OUT/smoke"
codesign --verify --deep --strict "$OUT/Airc.app"
after=$(codesign -d --verbose=4 "$OUT/Airc.app" 2>&1 | sed -n 's/^CDHash=//p')
[[ -n "$before" && "$before" == "$after" ]] || fail 'the payload changed during smoke'

phase="validating Sparkle signing key"
key=${AIRC_SPARKLE_KEY_FILE:-$HOME/arcfork/secrets/sparkle_ed25519_private}
sparkle=${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}
[[ -f "$key" && ! -L "$key" && $(stat -f %Lp "$key") == 600 && $(stat -f %u "$key") == $(id -u) ]] \
  || fail 'the signing key must be a mode-600 file of ours'
[[ $(swift infra/release/key-public.swift "$key") == "$(cat infra/release/sparkle-public-key.txt)" ]] \
  || fail 'the signing key does not match infra/release/sparkle-public-key.txt'
# Canonical archive name matches the stable installation name, without changing its signature.
phase="archiving and signing update"
ditto -c -k --sequesterRsrc --keepParent "$OUT/Airc.app" "$OUT/update.zip"
"$sparkle/bin/sign_update" --ed-key-file "$key" "$OUT/update.zip" > "$OUT/signature.txt"
cp "$STAGED" "$OUT/Info.plist"
# Up to three acknowledged published source apps, plus one pending copy. Keys stay on the Mac.
phase="generating deltas and recording cache"
python3 scripts/release/deltas.py "$OUT/Airc.app" "$OUT" "$DEV_CACHE_DIR"
shasum -a 256 "$OUT/update.zip" > "$OUT/sha256.txt"
# The smoke launched the staged copy, which registered it with Launch Services under the owner's identity: unregister it
# before deleting it, or links from other apps go to a missing app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OUT/Airc.app" 2>/dev/null || true
rm -rf "$OUT/Airc.app" "$OUT/smoke/plain/home"
