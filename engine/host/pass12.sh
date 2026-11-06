#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
variant=${1:?dev or release}
case "$variant" in dev) variant_out=Airc;; release) variant_out=AircRelease;; *) exit 2;; esac
export CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/$variant_out"
export PATH="$HOME/arcfork/chromium/src/third_party/node/mac_arm64/node-darwin-arm64/bin:$PATH"
run=${2:?fresh output directory}
mkdir -p "$run"
engine/host/build.sh "$run/host" > "$run/host-build.log" 2>&1
node engine/host/acceptance.mjs "$run/host/AircHost.app" "$run/pass12" pass12 > "$run/pass12.log" 2>&1
node engine/host/acceptance.mjs "$run/host/AircHost.app" "$run/isolation" > "$run/isolation.log" 2>&1
node engine/host/acceptance.mjs "$run/host/AircHost.app" "$run/discard" memory > "$run/discard.log" 2>&1
node engine/host/acceptance.mjs "$run/host/AircHost.app" "$run/extensions" extension > "$run/extensions.log" 2>&1
for kind in auth beforeunload auth-close platform; do
  AIRC_NATIVE_CASE="$kind" node engine/host/acceptance.mjs "$run/host/AircHost.app" "$run/dialog-$kind" dialogs > "$run/dialog-$kind.log" 2>&1
done
echo PASS
