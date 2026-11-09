#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Standalone WebKit only. Chromium uses BUILD.gn and its existing Rust runtime.
set -euo pipefail
crate="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$crate/../../.." && pwd)"
output=${1:?Usage: build-standalone.sh OUTPUT_DIRECTORY}
mkdir -p "$output"
output="$(cd "$output" && pwd)"
toolchain="${CHROMIUM_SRC:-$HOME/arcfork/chromium/src}/third_party/rust-toolchain/bin"
if [[ -x "$toolchain/cargo" ]]; then
  export PATH="$toolchain:$PATH" RUSTC="$toolchain/rustc"
fi
export CARGO_HOME="$output/cargo-home" CARGO_TARGET_DIR="$output/target"
export MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_BUILD_JOBS=4
# Rust panic/source metadata must not expose the build host in the public binary.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$root=/airc --remap-path-prefix=$HOME=/build-home"
cd "$crate"
cargo build --release --locked --offline
xcrun clang++ -std=c++20 -O2 -ffile-prefix-map="$root=/airc" -ffile-prefix-map="$HOME=/build-home" \
  export.cc "$output/target/release/libairc_blocking.a" \
  -framework Security -framework CoreFoundation -lresolv -liconv -o "$output/export-rules"
