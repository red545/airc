#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Copy complete licence texts before the app is signed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:?Usage: copy-licenses.sh APP CHROMIUM_OUT}
out=${2:?Chromium output directory required}
dest="$app/Contents/Resources/Licenses"
mkdir -p "$dest"
cp "$ROOT/LICENSE" "$dest/LICENSE"
cp "$ROOT/NOTICE" "$dest/NOTICE"
src=${CHROMIUM_SRC:-$out/../..}
if [[ -f "$src/LICENSE" ]]; then
  cp "$src/LICENSE" "$dest/Chromium-LICENSE"
else
  # WebKit-only developers need not have a Chromium checkout.
  cp "$ROOT/infra/release/licenses/Chromium-LICENSE" "$dest/Chromium-LICENSE"
fi
if [[ -n ${SPARKLE_ROOT:-} ]]; then
  # The pinned distribution includes MIT plus its external component licences.
  cp "$SPARKLE_ROOT/LICENSE" "$dest/Sparkle-LICENSE"
fi
# Preserve build-matched credits when available; the gate rejects the empty stub. AIRC_CHROMIUM_CREDITS: a page made
# by chromium-credits.sh from the same checkout, for an engine output built without generated credits (package.sh).
credits=${AIRC_CHROMIUM_CREDITS:-$out/gen/components/resources/about_credits.html}
if [[ -f "$credits" ]]; then cp "$credits" "$dest/Chromium-credits.html"; fi
