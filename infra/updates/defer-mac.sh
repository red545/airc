#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Freeze symbols and screenshots before the next nightly deletes its build tree.
set -euo pipefail
stamp=${1:?run stamp}
[[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$ ]] || exit 2
queue="$HOME/arcfork/update-jobs"
job="$queue/$stamp"
mkdir -p "$queue"
[[ ! -e "$job" ]] || exit 0
stage=$(mktemp -d "$queue/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/build"
for name in dSYMs snapshots; do
  [[ ! -d build/$name ]] || cp -cR "build/$name" "$stage/build/$name"
done
[[ ! -f build/Airc-Chromium.app/Contents/Info.plist ]] || cp build/Airc-Chromium.app/Contents/Info.plist "$stage/build/Info.plist"
mkdir -p "$stage/build/snapshots"
mv "$stage" "$job"
