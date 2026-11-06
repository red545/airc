#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Chromium's credits page (every shipped third-party licence) for a checkout, made by Chromium's own
# tools/licenses/licenses.py with the arguments of its about_credits action (components/resources/BUILD.gn), which only
# runs when the engine is built with generate_about_credits (engine/build.sh). For an engine output built without it,
# whose gen/ page is the 401-byte sample: package.sh puts this page in the bundle's Licenses/ instead. The engine's own
# chrome://credits keeps the sample until the engine is rebuilt. Read-only on the checkout.
#
#   chromium-credits.sh CHROMIUM_SRC OUT.html
set -euo pipefail
src=${1:?Usage: chromium-credits.sh CHROMIUM_SRC OUT.html}
out=${2:?Usage: chromium-credits.sh CHROMIUM_SRC OUT.html}
[[ -f "$src/tools/licenses/licenses.py" ]] || { echo "No Chromium checkout at $src" >&2; exit 1; }
out_dir=$(cd "$(dirname "$out")" && pwd)
export PATH="${DEPOT_TOOLS:-$HOME/arcfork/depot_tools}:$PATH"
(cd "$src" && PYTHONDONTWRITEBYTECODE=1 python3 tools/licenses/licenses.py credits --target-os=mac "$out_dir/$(basename "$out")")
grep -q 'Neither the name' "$out" || { echo "The generated credits page lacks Chromium's licence text" >&2; exit 1; }
echo "Chromium credits: $(grep -c 'class="product"' "$out") products, $(wc -c < "$out" | tr -d ' ') bytes"
