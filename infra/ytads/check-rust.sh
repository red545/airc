#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run under the coordinated build lock on the build Mac.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'Run on the build Mac.' >&2; exit 1; }
root=$(cd "$(dirname "$0")/../.." && pwd)
export PATH="${CHROMIUM_SRC:-$HOME/arcfork/chromium/src}/third_party/rust-toolchain/bin:$PATH"
export CARGO_HOME="$root/build/blocking/cargo-home" CARGO_TARGET_DIR="$root/build/blocking/target"
export MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_BUILD_JOBS=4
export RUSTFLAGS="--remap-path-prefix=$root=/airc --remap-path-prefix=$HOME=/build-home"
python3 - "$root" <<'PY'
import base64, json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'engine/core/blocking-rust/src'
resource = json.loads((root / 'video_ads_resource.json').read_text())[0]
assert base64.b64decode(resource['content']) == (root / 'video_ads.js').read_bytes()
print('Bundled resource exactly matches original JS source')
PY
cd "$root/engine/core/blocking-rust"
cargo test --release --locked --offline --lib video_resource_selection_and_exceptions
