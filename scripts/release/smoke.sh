#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Launch smoke for a public build, which has no scripted scenarios: mount the DMG read-only, start its app in the
# background (open -g, never focused) on a scratch home and data folder with Chromium's mock keychain, wait for its
# window, check it stays up, quit it as the Quit menu does. A second launch adds the test options (--snapshot, --script,
# --automated, AIRC_AUTOMATED=1) and the engine's trace switch on a scratch profile that its test gate would accept: a
# public build ignores them all, opens its window the same way, writes nothing to the snapshot folder and logs no
# engine trace. Results go to OUT/smoke.txt (default build/smoke); each launch's stderr to OUT/NAME/stderr.log.
#
#   smoke.sh [--plain-only] FILE.dmg|Airc.app [OUT]
# --plain-only also works on signed dev bundles: no scripted or engine test switches.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
plain_only=0
if [[ ${1:-} == --plain-only ]]; then plain_only=1; shift; fi
input=${1:?Usage: smoke.sh FILE.dmg|Airc.app [OUT]}
out=${2:-$ROOT/build/smoke}
rm -rf "$out"; mkdir -p "$out"; out=$(cd "$out" && pwd)
pid=
cleanup() {
  [[ -z $pid ]] || kill -9 "$pid" 2>/dev/null || true
  [[ ! -d "$out/mount" ]] || hdiutil detach "$out/mount" -quiet 2>/dev/null || true
}
trap cleanup EXIT
report() { echo "$*" | tee -a "$out/smoke.txt"; }
fail() { report "FAIL $*"; exit 1; }

if [[ "$input" == *.dmg ]]; then
  mkdir "$out/mount"
  hdiutil attach -readonly -nobrowse -quiet -mountpoint "$out/mount" "$input"
  app="$out/mount/Airc.app"
else
  app=$(cd "$input" && pwd)
fi
[[ -x "$app/Contents/MacOS/Airc" ]] || fail "no app at $input"
xcrun swiftc -O "$ROOT/scripts/release/smoke-window.swift" -o "$out/smoke-window" > "$out/swiftc.log" 2>&1 \
  || fail "the smoke helper didn't compile ($out/swiftc.log)"
if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then report "note: the screen is locked"; fi

# launch NAME [--env K=V …] -- [app arguments …]
launch() {
  local name=$1; shift
  local home="$out/$name/home" envs=() before
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  # The engine's test gate compares real paths: the scratch profile folder exists before launch.
  mkdir -p "$home/Library" "$home/Airc/Chromium"
  before=$(pgrep -f "^$app/Contents/MacOS/Airc" || true)
  # AIRC_TELEMETRY_ENABLED=0: a smoke launch is not an owner install (it reached PostHog as a new install, 2026-11-06).
  open -g -n --stderr "$out/$name/stderr.log" --env "CFFIXED_USER_HOME=$home" --env AIRC_TELEMETRY_ENABLED=0 ${envs[@]+"${envs[@]}"} "$app" \
    --args -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO --data-dir "$home/Airc" --use-mock-keychain "$@"
  pid=
  for _ in $(seq 1 80); do
    pid=$(pgrep -f "^$app/Contents/MacOS/Airc" | grep -vxF "${before:-none}" | head -1 || true)
    [[ -z $pid ]] || break
    sleep 0.25
  done
  [[ -n $pid ]] || fail "$name: the app didn't start"
  local window
  window=$("$out/smoke-window" window "$pid" 90) || fail "$name: $window"
  report "PASS $name: $window"
  sleep 8
  kill -0 "$pid" 2>/dev/null || fail "$name: the app exited by itself"
  report "PASS $name: still running 8 s later"
  [[ -f "$home/Airc/spaces.sqlite" ]] || fail "$name: nothing written to the scratch data folder"
  report "PASS $name: its data is in the scratch folder"
}
quit() {
  local name=$1 result
  result=$("$out/smoke-window" quit "$pid" 60) || fail "$name: $result"
  report "PASS $name: $result"
  pid=
}

launch plain --
quit plain

if [[ $plain_only == 0 ]]; then
mkdir -p "$out/test-options/snapshot"
launch test-options --env AIRC_AUTOMATED=1 -- --snapshot "$out/test-options/snapshot" --script showcase --automated \
  --airc-data-dir="$out/test-options/home/Airc" --airc-trace=profileGate
[[ -z $(ls -A "$out/test-options/snapshot") ]] || fail "test-options: the app wrote to the snapshot folder"
! grep -q '\[airc\] profile gate' "$out/test-options/stderr.log" || fail "test-options: the engine took the trace switch"
report "PASS test-options: ignored (nothing in the snapshot folder, no scripted quit, no engine trace)"
quit test-options
fi

report "PASS smoke ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"))"
