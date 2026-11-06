#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
infra/updates/local-feed.sh
feed="$HOME/arcfork/updates-local"
if [[ ! -e "$feed/appcast.xml" && -f build/dev-seed.xml ]]; then
  cp build/dev-seed.xml "$feed/appcast.xml.tmp"
  mv "$feed/appcast.xml.tmp" "$feed/appcast.xml"
fi
bash infra/updates/prepare-mac.sh
python3 infra/updates/publish.py "$PWD" "$feed" "$PWD/build/dev-update" "$AIRC_UPDATE_FEED"
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/dev-update/Info.plist)
touch "$HOME/arcfork/updates-cache.noindex/dev/$build/published"
curl --fail --silent --show-error --retry 3 "$AIRC_UPDATE_FEED" > build/dev-update/served-appcast.xml
# Keep tiny evidence; enclosures are already durable in the feed.
rm -f build/dev-update/update.zip build/dev-update/*.delta
