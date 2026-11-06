#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
version=2.10.1
root=${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}
mkdir -p "$root"
curl -fL --retry 3 --max-time 180 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$root/archive.tar.xz"
echo "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  $root/archive.tar.xz" | shasum -a 256 -c -
tar -xf "$root/archive.tar.xz" -C "$root"
echo 'Sparkle 2.10.1 installed. Run bin/generate_keys locally on the Mac for keychain setup.'
