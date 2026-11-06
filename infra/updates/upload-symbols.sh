#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Linux entrypoint: send a built copy's dSYMs (scripts/build-app.sh writes them to build/dSYMs on the Mac) to PostHog
# error tracking, so Airc's crash reports get function names (docs/user/telemetry.md, "Crash reports"). Best effort:
# publish.sh calls it after a publish and ignores its exit code.
#
#   infra/updates/upload-symbols.sh [--dry-run] [REMOTE]   REMOTE: the build copy on the Mac (default arcfork/nightly)
#
# Runs posthog-cli here, never on the Mac: its credentials stay on this box. POSTHOG_CLI (default
# ~/.local/bin/posthog-cli) and AIRC_POSTHOG_CLI_ENV (default secrets/posthog-cli.env beside the checkout: a personal
# API key with error tracking write, and the project ID; never committed, never printed, never copied). Each UUID is
# uploaded once (uploaded.txt in AIRC_SYMBOLS_DIR, default symbols/ beside the checkout); only new dSYMs are copied.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DRY=""
if [[ ${1:-} == --dry-run ]]; then DRY=--dry-run; shift; fi
HOST=${AIRC_MAC_HOST:-mac}
REMOTE=${1:-arcfork/nightly}
[[ "$REMOTE" =~ ^arcfork/[a-zA-Z0-9/_-]+$ ]] || { echo "bad REMOTE $REMOTE" >&2; exit 2; }
CLI=${POSTHOG_CLI:-$HOME/.local/bin/posthog-cli}
CREDENTIALS=${AIRC_POSTHOG_CLI_ENV:-$(dirname "$ROOT")/secrets/posthog-cli.env}
POSTHOG_HOST=${AIRC_POSTHOG_HOST:-https://eu.posthog.com}
STATE=${AIRC_SYMBOLS_DIR:-$(dirname "$ROOT")/symbols}
[[ -x "$CLI" ]] || { echo "symbols: skipped, no posthog-cli at $CLI"; exit 0; }
[[ -n $DRY || -f "$CREDENTIALS" ]] || { echo "symbols: skipped, no credentials file"; exit 0; }
mkdir -p "$STATE"
touch "$STATE/uploaded.txt"
exec 7>"$STATE/.lock"
flock -w 600 7 || { echo "symbols: another upload is still running" >&2; exit 1; }
ssh_mac() { timeout --kill-after=10s 2m ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$@"; }

# What the build made: "UUID<TAB>dSYM name" per architecture, and the release it belongs to.
listing=$(ssh_mac "cd $REMOTE/build/dSYMs 2>/dev/null && for d in *.dSYM; do xcrun dwarfdump --uuid \"\$d\" | sed -E \"s/^UUID: ([0-9A-F-]+) .*/\\1	\$d/\"; done") \
  || { echo "symbols: no dSYMs in $REMOTE/build/dSYMs"; exit 0; }
plist="$REMOTE/build/Airc-Chromium.app/Contents/Info.plist"
version=$(ssh_mac "plutil -extract CFBundleShortVersionString raw -o - $plist" 2>/dev/null || echo 0.0.0)
build=$(ssh_mac "plutil -extract CFBundleVersion raw -o - $plist" 2>/dev/null || echo 0)
[[ $version =~ ^[0-9.]+$ && $build =~ ^[0-9]+$ ]] || { version=0.0.0; build=0; }

# Only dSYMs with a UUID not uploaded yet: Chromium's framework (171 MB) and Sparkle change rarely.
new=()
while IFS=$'\t' read -r id name; do
  [[ -n $id ]] || continue
  grep -qx "$id" "$STATE/uploaded.txt" || [[ " ${new[*]-} " == *" $name "* ]] || new+=("$name")
done <<< "$listing"
if [[ ${#new[@]} == 0 ]]; then
  echo "symbols: all $(grep -c . <<< "$listing") dSYM UUIDs of $version ($build) are already uploaded"
  exit 0
fi

STAGE=$(mktemp -d "$STATE/stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/dSYMs" "$STAGE/bin"
for name in "${new[@]}"; do
  rsync -az "$HOST:$REMOTE/build/dSYMs/$name" "$STAGE/dSYMs/" || { echo "symbols: couldn't copy $name" >&2; exit 1; }
done
# posthog-cli reads each dSYM's UUID with Xcode's dwarfdump and thins universal ones (Sparkle's) with lipo; this box
# has neither.
ln -s "$ROOT/infra/updates/macho-uuid.py" "$STAGE/bin/dwarfdump"
ln -s "$ROOT/infra/updates/macho-uuid.py" "$STAGE/bin/lipo"
echo "symbols: uploading ${new[*]} for $version ($build)${DRY:+ (dry run)}"
args=(--host "$POSTHOG_HOST")
[[ -n $DRY ]] && args+=(--dry-run) || args+=(--dotenv-file "$CREDENTIALS")
# Whatever the CLI prints, no key-like string reaches a log.
PATH="$STAGE/bin:$PATH" "$CLI" "${args[@]}" dsym upload --directory "$STAGE/dSYMs" --release-name airc \
  --release-version "$version" --build "$build" --skip-on-conflict 2>&1 \
  | sed -E 's/(ph[a-z]_)[A-Za-z0-9_-]{6,}/\1[redacted]/g'
rc=${PIPESTATUS[0]}
if [[ $rc == 0 && -z $DRY ]]; then
  for name in "${new[@]}"; do awk -F'\t' -v n="$name" '$2 == n { print $1 }' <<< "$listing"; done >> "$STATE/uploaded.txt"
  echo "symbols: uploaded"
fi
exit "$rc"
