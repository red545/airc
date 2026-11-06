#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Exact downloaded DMG assessment and throwaway install. No owner app/profile or media.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
dmg=$1; out=$2
mkdir -p "$out"
work=$(mktemp -d "$out/.install.XXXXXX")
cleanup() {
 hdiutil detach "$work/mount" -quiet 2>/dev/null || true
 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$work/installed/Airc.app" 2>/dev/null || true
 rm -rf "$work"
}
trap cleanup EXIT
# spctl's origin includes the private signing identity; do not print or retain it.
assess() {
 local rc=0
 spctl -a -vv "$@" > "$work/assessment" 2>&1 || rc=$?
 sed '/^origin=/d' "$work/assessment"
 [[ $rc == 0 ]] || return "$rc"
}
xcrun stapler validate "$dmg"
assess -t open --context context:primary-signature "$dmg"
cp "$dmg" "$work/download.dmg"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");AircReleaseProof;" "$work/download.dmg"
xattr -p com.apple.quarantine "$work/download.dmg"
assess -t open --context context:primary-signature "$work/download.dmg"
echo 'PASS quarantined DMG accepted'
mkdir "$work/mount" "$work/installed"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$work/mount" "$work/download.dmg"
ditto "$work/mount/Airc.app" "$work/installed/Airc.app"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");AircReleaseProof;" "$work/installed/Airc.app"
codesign --verify --deep --strict "$work/installed/Airc.app"
xcrun stapler validate "$work/installed/Airc.app"
assess --type exec "$work/installed/Airc.app"
# Assessment above exercises quarantine. Remove it only on this throwaway copy before unattended
# launch: App Translocation changes its executable path and breaks the smoke's PID isolation.
xattr -dr com.apple.quarantine "$work/installed/Airc.app"
"$ROOT/scripts/release/smoke.sh" "$work/installed/Airc.app" "$out/smoke"
echo 'PASS throwaway install, Gatekeeper and public smoke'
# Keep logs only, not scratch profiles or compiled smoke helper.
rm -rf "$out/smoke/plain/home" "$out/smoke/test-options/home" "$out/smoke/smoke-window"
