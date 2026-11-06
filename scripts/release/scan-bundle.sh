#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Read-only gate. Never print matched private values.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
input=${1:?Usage: scan-bundle.sh APP_OR_DMG}
[[ $# == 1 ]] || exit 2
if [[ -d "$input/Contents" ]]; then
  exec python3 "$ROOT/scripts/release/scan-bundle.py" "$input"
fi
[[ "$input" == *.dmg && $(uname) == Darwin ]] || { echo 'Expected an app bundle or a DMG on macOS.' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/airc-scan.XXXXXX")
cleanup() { hdiutil detach "$work/mount" -quiet 2>/dev/null || true; rmdir "$work/mount" "$work" 2>/dev/null || true; }
trap cleanup EXIT
mkdir "$work/mount"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$work/mount" "$input"
found=0
for app in "$work/mount"/*.app; do
  [[ -d "$app" ]] || continue
  found=1
  python3 "$ROOT/scripts/release/scan-bundle.py" "$app"
done
[[ $found == 1 ]] || { echo 'No app found in DMG.' >&2; exit 1; }
