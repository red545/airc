#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Read-only gate. Never print matched private values.
#   scan-bundle.sh Airc.app      every file of the bundle
#   scan-bundle.sh Airc.dmg      the image's own bytes outside compressed chunks, plus every file of its volume
#                                (read-only hdiutil mount on macOS, 7-Zip elsewhere: AIRC_7ZZ, 7zz or 7z).
#                                Without either, it fails closed: "DMG contents not scanned".
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
input=${1:?Usage: scan-bundle.sh APP_OR_DMG}
[[ $# == 1 ]] || exit 2
if [[ -d "$input/Contents" || ( "$input" == *.dmg && -f "$input" ) ]]; then
  exec python3 "$ROOT/scripts/release/scan-bundle.py" "$input"
fi
echo 'Expected an app bundle or a DMG.' >&2
exit 2
