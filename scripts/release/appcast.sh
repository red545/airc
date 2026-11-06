#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
usage() { echo 'Usage: appcast.sh stable|nightly RELEASES_DIR ARCHIVE_BASENAME NOTES.md DOWNLOAD_URL_PREFIX'; }
[[ $# == 5 ]] || { usage >&2; exit 2; }
channel=$1; folder=$2; archive=$3; notes=$4; url=$5
[[ "$channel" == stable || "$channel" == nightly ]] || { usage >&2; exit 2; }
[[ "$archive" == "$(basename "$archive")" && -f "$folder/$archive" && -f "$notes" && "$notes" == *.md ]] || { echo 'Archive or Markdown notes missing/invalid.' >&2; exit 2; }
case "$url" in https://*|http://127.0.0.1:*|http://localhost:*) ;; *) echo 'HTTPS required (except loopback test feeds).' >&2; exit 2;; esac
sparkle=${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}
args=()
# Prefer the keychain. Never export it or echo private key contents.
if public=$("$sparkle/bin/generate_keys" -p 2>/dev/null); then
 [[ "$public" == "$(cat "$ROOT/infra/release/sparkle-public-key.txt")" ]] || { echo 'Keychain public key differs from repository key; refusing to sign.' >&2; exit 1; }
else
 key=${AIRC_SPARKLE_KEY_FILE:-$HOME/arcfork/secrets/sparkle_ed25519_private}
 [[ -f "$key" && ! -L "$key" && $(stat -f %Lp "$key") == 600 && $(stat -f %u "$key") == $(id -u) ]] || { echo 'No usable keychain key or owned mode-600 fallback key.' >&2; exit 1; }
 public=$(swift "$ROOT/infra/release/key-public.swift" "$key")
 [[ "$public" == "$(cat "$ROOT/infra/release/sparkle-public-key.txt")" ]] || { echo 'Fallback public key differs from repository key.' >&2; exit 1; }
 args+=(--ed-key-file "$key")
fi
cp "$notes" "$folder/${archive%.*}.md"
# Each channel has its own releases directory; no accidental reclassification of old items.
if [[ -e "$folder/.airc-channel" ]]; then
 [[ $(cat "$folder/.airc-channel") == "$channel" ]] || { echo 'Do not mix channel directories.' >&2; exit 2; }
fi
printf '%s\n' "$channel" > "$folder/.airc-channel"
# Keep extraction cache inside the work tree (Foundation honours this override).
mkdir -p "$ROOT/build/release-tool-home/Library/Caches"
CFFIXED_USER_HOME="$ROOT/build/release-tool-home" "$sparkle/bin/generate_appcast" "${args[@]}" \
 --channel "$channel" --maximum-deltas 3 --maximum-versions 4 \
 --download-url-prefix "${url%/}/" --release-notes-url-prefix "${url%/}/" \
 -o "$folder/appcast.xml" "$folder"
