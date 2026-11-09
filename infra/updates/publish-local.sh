#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
phase=initialization
failure_line=unknown
trap 'failure_line=$LINENO' ERR
report_exit() {
  local rc=$?
  if [[ $rc != 0 ]]; then
    printf '%s: failed during %s (exit %s, line %s)\n' "${0##*/}" "$phase" "$rc" "$failure_line" >&2
  fi
  exit "$rc"
}
trap report_exit EXIT
echo "${0##*/}: starting"
[[ ${AIRC_PUBLISH_HOLD:-0} != 1 && ${AIRC_PREPARATION:-0} != 1 ]] || {
  echo 'local publication held; no feed or cache changed' >&2; exit 2;
}
source infra/updates/dev-paths.sh
phase="installing and checking the loopback LaunchAgent"
if [[ -n ${AIRC_SCRATCH_PUBLISH_ROOT:-} ]]; then
  # The caller owns a separately rooted scratch server. Never install/change the live LaunchAgent.
  mkdir -p "$DEV_FEED_DIR"
  python3 infra/updates/scratch_paths.py --probe "$DEV_FEED_DIR" "$AIRC_UPDATE_FEED"
else
  infra/updates/local-feed.sh
fi
feed="$DEV_FEED_DIR"
phase="seeding transition history"
if [[ ! -e "$feed/appcast.xml" && -f build/dev-seed.xml ]]; then
  cp build/dev-seed.xml "$feed/appcast.xml.tmp"
  mv "$feed/appcast.xml.tmp" "$feed/appcast.xml"
fi
phase="signing and preparing the candidate"
bash infra/updates/prepare-mac.sh
phase="verifying enclosures and atomically publishing the feed"
python3 infra/updates/publish.py "$PWD" "$feed" "$PWD/build/dev-update" "$AIRC_UPDATE_FEED"
phase="acknowledging delta cache"
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/dev-update/Info.plist)
touch "$DEV_CACHE_DIR/$build/published"
phase="checking served appcast"
curl --fail --silent --show-error --retry 3 "$AIRC_UPDATE_FEED" > build/dev-update/served-appcast.xml
# Keep tiny evidence; enclosures are already durable in the feed.
phase="cleaning staged enclosures"
rm -f build/dev-update/update.zip build/dev-update/*.delta
