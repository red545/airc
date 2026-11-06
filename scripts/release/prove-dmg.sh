#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Signature and Gatekeeper evidence for a DMG's app, then the public-build launch smoke (smoke.sh: background launch on
# a scratch home with the mock keychain, window, quit). Public builds have no scripted scenarios to capture.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
dmg=${1:?Usage: prove-dmg.sh FILE.dmg}
proof="$ROOT/build/dmg-proof"
rm -rf "$proof"; mkdir -p "$proof/mount"
trap 'hdiutil detach "$proof/mount" -quiet 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$proof/mount" "$dmg"
codesign --verify --deep --strict --verbose=2 "$proof/mount/Airc.app" > "$proof/codesign.txt" 2>&1
set +e
spctl -a -vv "$proof/mount/Airc.app" > "$proof/spctl.txt" 2>&1
status=$?
set -e
printf '\nexit status: %s\n' "$status" >> "$proof/spctl.txt"
hdiutil detach "$proof/mount" -quiet
cat "$proof/codesign.txt" "$proof/spctl.txt"
"$ROOT/scripts/release/smoke.sh" "$dmg" "$proof/smoke"
echo 'PASS mounted app verified, launched in the background, showed its window and quit.'
