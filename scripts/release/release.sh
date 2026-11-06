#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Linux entrypoint. Export committed HEAD; never publish or touch the private dev feed.
set -euo pipefail
# Keep the entrypoint stable even when another agent commits edits in the shared checkout.
if [[ ${AIRC_RELEASE_SCRIPT_LOADED:-0} != 1 ]]; then
 exec env AIRC_RELEASE_SCRIPT_LOADED=1 bash -c "$(cat "$0")" "$0" "$@"
fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
channel=stable; green=; dry=0
while [[ $# -gt 0 ]]; do
 case "$1" in
 --channel) channel=$2; shift 2;;
 --green-run) green=$2; shift 2;;
 --dry-run) dry=1; shift;;
 --help) echo 'release.sh [--channel stable|nightly] [--green-run STATUS_RUN] [--dry-run]'; exit 0;;
 *) echo 'Unknown argument' >&2; exit 2;;
 esac
done
[[ $channel == stable || $channel == nightly ]] || exit 2
config=${AIRC_RELEASE_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f $config ]] || source "$config"
: "${AIRC_SIGN_IDENTITY:?Configure Developer ID}"
: "${AIRC_SIGN_KEYCHAIN:?Configure dedicated keychain}"
: "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:?Configure Mac password path}"
: "${AIRC_NOTARY_PROFILE:?Configure notarization}"
[[ $AIRC_SIGN_IDENTITY != - ]] || exit 2
host=${AIRC_MAC_HOST:-mac}
artifacts=${AIRC_ARTIFACTS_DIR:-$(dirname "$ROOT")/artifacts}
base="$artifacts/release/$channel"
mkdir -p "$base"
exec 9>"$artifacts/release/.public-release.lock"
flock -n 9 || { echo 'Another public release is running' >&2; exit 1; }
rev=$(git -C "$ROOT" rev-parse HEAD)
if [[ -z $green ]]; then
 green=$(python3 "$ROOT/scripts/release/green.py" "$ROOT" "${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}/runs" "$rev" || true)
fi
qualified=0
if [[ -n $green ]]; then
 python3 "$ROOT/scripts/release/green.py" "$ROOT" "$green" "$rev" --check
 qualified=1
elif [[ $dry != 1 ]]; then
 echo 'No green test run for HEAD application sources. Supply --green-run or use --dry-run (not uploadable).' >&2; exit 1
fi
# A global sequence spans stable/nightly. Reserve builds even after failed attempts.
build=$(python3 - "$artifacts/release" <<'PY'
import datetime,pathlib,sys
p=pathlib.Path(sys.argv[1])/'.last-public-build'
now=datetime.datetime.now(datetime.timezone.utc)
if p.exists():
 previous=datetime.datetime.strptime(p.read_text().strip(), '%Y%m%d%H%M').replace(tzinfo=datetime.timezone.utc)
 now=max(now,previous+datetime.timedelta(minutes=1))
b=now.strftime('%Y%m%d%H%M');p.write_text(b+'\n');print(b)
PY
)
version=${AIRC_RELEASE_VERSION:-0.1.0}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
stage="$base/$version-$build"
mkdir "$stage"
scratch=$(mktemp -d "$artifacts/release/.source.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
# Read APFS available container bytes, not df's misleading volume capacity.
free=$(ssh "$host" "diskutil info /System/Volumes/Data" | sed -n 's/.*Container Free Space:.*(\([0-9]*\) Bytes).*/\1/p')
[[ $free =~ ^[0-9]+$ && $free -ge 15000000000 ]] || { echo 'Build Mac has less than 15 GB free; stop and clean owned intermediates.' >&2; exit 1; }
ssh "$host" 'test ! -d arcfork/work/launchprep/build/.release-running' || {
 echo 'A remote release is still running (or needs recovery); do not overwrite its work copy.' >&2; exit 1;
}
git -C "$ROOT" archive "$rev" | tar -x -C "$scratch"
AIRC_MAC_HOST="$host" "$scratch/scripts/mac.sh" -w launchprep sync > "$stage/sync.log" 2>&1
# Only credential paths and the identity travel. Password and EdDSA seed remain on the Mac.
(umask 077
 for name in AIRC_SIGN_IDENTITY AIRC_SIGN_KEYCHAIN AIRC_SIGN_KEYCHAIN_PASSWORD_FILE AIRC_NOTARY_PROFILE; do
  printf 'export %s=%q\n' "$name" "${!name}"
 done
 printf 'export AIRC_SOURCE_REV=%q AIRC_RELEASE_VERSION=%q AIRC_RELEASE_BUILD=%q AIRC_RELEASE_CHANNEL=%q AIRC_RELEASE_QUALIFIED=%q AIRC_KEEP_RELEASE_APP=1\n' "$rev" "$version" "$build" "$channel" "$qualified"
) > "$scratch/release.env"
ssh "$host" 'mkdir -p arcfork/work/launchprep/build; chmod 700 arcfork/work/launchprep/build; rm -f arcfork/work/launchprep/build/release-exit; rm -rf arcfork/work/launchprep/build/stable-stage arcfork/work/launchprep/build/launchprep-delta arcfork/work/launchprep/build/launchprep-full'
scp -q "$scratch/release.env" "$host:arcfork/work/launchprep/build/release.env"
# The remote job survives an SSH disconnect. Reconnect using the recovery commands in the runbook.
ssh "$host" 'cd arcfork/work/launchprep && nohup caffeinate -i -s bash -c '\''scripts/release/worker.sh > build/release-worker.log 2>&1; echo $? > build/release-exit'\'' < /dev/null > /dev/null 2>&1 &'
echo "Building $channel $version ($build) at $rev"
while ! ssh "$host" 'test -f arcfork/work/launchprep/build/release-exit'; do sleep 15; done
rc=$(ssh "$host" 'cat arcfork/work/launchprep/build/release-exit; rm arcfork/work/launchprep/build/release-exit')
AIRC_MAC_HOST="$host" "$scratch/scripts/mac.sh" -w launchprep get build/stable-stage/ "$stage/" > "$stage/transfer.log" 2>&1
[[ $rc == 0 ]] || { echo "Release failed; evidence: $stage" >&2; exit 1; }
python3 "$ROOT/scripts/release/upload.py" "$stage" --verify-only
# Keep symbols on Linux, no SwiftPM trees, test profiles or duplicate DMGs on the Mac.
AIRC_MAC_HOST="$host" "$scratch/scripts/mac.sh" -w launchprep get build/dSYMs/ "$stage/private-symbols/" >> "$stage/transfer.log" 2>&1 || true
ssh "$host" 'rm -rf arcfork/work/launchprep/build arcfork/work/launchprep/packages/*/.build arcfork/work/launchprep/apps/browser/.build'
if [[ $channel == stable ]]; then printf '%s\n' "$stage" > "$artifacts/release/.last-stage"; fi
echo "Staged: $stage"
