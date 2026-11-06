#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# check-release.py on an app bundle, or on every app in a DMG (mounted read-only).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
input=${1:?Usage: check-release.sh APP_OR_DMG}
[[ $# == 1 ]] || exit 2
if [[ -d "$input/Contents" ]]; then
  exec python3 "$ROOT/scripts/release/check-release.py" "$input"
fi
[[ "$input" == *.dmg && $(uname) == Darwin ]] || { echo 'Expected an app bundle or a DMG on macOS.' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/airc-check.XXXXXX")
cleanup() { hdiutil detach "$work/mount" -quiet 2>/dev/null || true; rmdir "$work/mount" "$work" 2>/dev/null || true; }
trap cleanup EXIT
mkdir "$work/mount"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$work/mount" "$input"
found=0
for app in "$work/mount"/*.app; do
  [[ -d "$app" ]] || continue
  found=1
  python3 "$ROOT/scripts/release/check-release.py" "$app"
done
[[ $found == 1 ]] || { echo 'No app found in DMG.' >&2; exit 1; }
