#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Renders the social videos' frame sequences on the build Mac (tools/social/README.md).
#
#   tools/social/mac-frames.sh                         swipe and capture: build, render, copy the frames back
#   tools/social/mac-frames.sh --motions capture       some motions (swipe, capture, multiselect, boosts, commandbar, notes)
#   tools/social/mac-frames.sh --rev bde185a           build a release's own source (its features' videos show that
#                                                     release, not what came after); motion files of later
#                                                     releases (social-needs) and SocialNext.swift are left out
#   tools/social/mac-frames.sh --no-build              render with the copy's last build
#   tools/social/mac-frames.sh --keep                  leave the Mac copy (it's deleted after rendering by default)
#   tools/social/mac-frames.sh --clean                 delete the copy on the Mac
#   AIRC_MAC_WORK=social-rel                           the Mac folder (~/arcfork/work/<it>; default social), for a
#                                                     second build kept beside the first (--keep)
#
# From the Linux box, to the build Mac (AIRC_MAC_HOST, default buildmac; never the owner's laptop). The Mac copy is
# made from `git archive HEAD` plus this tool's own files, never from the shared tree alone (other agents' uncommitted
# hunks may not compile). The build is its own step: once status/buildmac-engine-ready names an engine this source's
# engine/ isn't newer than, after any pending relink or quiet window, under the agent build lock (status/.agent-build.lock
# next to the repo, as briefs/common.md asks: agent builds one at a time; the ship lock is the ship runs'), not during a
# priority build of someone else's, never started from 01:00 to 01:50 UTC (the nightly), and only
# with AIRC_MAC_MIN_FREE_GB free on the Mac (default 15). Then, without the lock, for each motion:
#   - the app is scripts/build-app.sh --no-test's, on the release engine;
#   - it waits for the screen to be unlocked and idle for 120 s (the owner isn't using it), else exits 75: try later;
#   - Airc-Chromium.app --script social runs under scripts/ui-check-lock.py with `open -g -n -W`, never focused, its
#     window off screen, in its own data folder (deleted afterwards). If the lock times out ("timeout, proceeding"),
#     the launch quits instead of proceeding. The frames are drawn by the app's own views (SocialFrames.swift): no
#     screen recording, no camera or microphone.
# The frames land in ARTIFACTS/social/_frames/<motion>/ on the Linux box (default: artifacts next to the repo), and
# the whole Mac copy is deleted right after (unless --keep).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MOTIONS="swipe capture multiselect boosts commandbar notes"
BUILD=1
BUILD_ONLY=0
KEEP=0
REV_ARG=""
ON_MAC=0
CLEAN=0
MIN_FREE_GB="${AIRC_MAC_MIN_FREE_GB:-15}"
while [ $# -gt 0 ]; do
  case "$1" in
    --motions) MOTIONS="$(echo "$2" | tr ',' ' ')"; shift ;;
    --no-build) BUILD=0 ;;
    --build-only) BUILD_ONLY=1 ;;
    --keep) KEEP=1 ;;
    --rev) REV_ARG="$2"; shift ;;
    --on-mac) ON_MAC=1 ;;
    --clean) CLEAN=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$ON_MAC" = 1 ]; then
  # ---- On the build Mac (macOS bash 3.2: plain [ ] tests only). ----
  cd "$ROOT"
  export CHROMIUM_OUT="${CHROMIUM_OUT:-$HOME/arcfork/chromium/src/out/AircRelease}"
  if [ "$BUILD" = 1 ]; then
    free=$(diskutil info /System/Volumes/Data | sed -n 's/.*Container Free Space:.*(\([0-9]*\) Bytes).*/\1/p')
    [ -n "$free" ] || free=0
    if [ "$free" -lt $((MIN_FREE_GB * 1000000000)) ]; then
      echo "social: under $MIN_FREE_GB GB free on the build Mac ($free bytes); not building, try later" >&2; exit 75
    fi
    caffeinate -i -s scripts/build-app.sh --no-test
    # The revision this app was built from, for the frames' source.txt (a later --no-build render can't know it).
    echo "${AIRC_SOURCE_REV:-}" > build/social-source-rev.txt
  fi
  [ "$BUILD_ONLY" = 0 ] || exit 0
  app="$ROOT/build/Airc-Chromium.app"
  [ -d "$app" ] || { echo "error: no $app" >&2; exit 1; }
  out="$ROOT/build/social"; home="$ROOT/build/social-home"
  rm -rf "$out" "$home"; mkdir -p "$out" "$home/Library"
  for m in $MOTIONS; do
    # Drawing waits for an unlocked screen nobody is using (HID idle for 120 s).
    # (Whole outputs first: a reader that stops early would end the pipe with SIGPIPE under pipefail.)
    session=$(ioreg -n Root -d1 2>/dev/null || true)
    case "$session" in *'"CGSSessionScreenIsLocked"=Yes'*) echo "social: the screen is locked; try later"; exit 75 ;; esac
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !n {n = 1; print int($NF / 1000000000)}')
    if [ "${idle:-0}" -lt 120 ]; then echo "social: the Mac is in use (idle ${idle:-0} s); try later"; exit 75; fi
    port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    secure=""
    for h in meet video radio files trips; do secure="$secure${secure:+,}http://$h.aircbrowser.com"; done
    mkdir -p "$out/$m"
    echo "== social: $m"
    # The wrapper writes its own pid into the lock file only when it holds the lock; the child checks that.
    # shellcheck disable=SC2016
    python3 scripts/ui-check-lock.py /bin/sh -c 'grep -q "^pid=$PPID " "$HOME/arcfork/.ui-check.lock" || { echo "social: the UI lock timed out; quitting"; exit 75; }; exec "$@"' sh \
      open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_MARKETING_PART=social" --env "AIRC_SOCIAL_MOTION=$m" \
      --env "AIRC_MARKETING_PORT=$port" --env "AIRC_LIVE_SUGGESTIONS=0" "$app" --args \
      --engine=chromium --snapshot "$out/$m" --script social --ephemeral --data-dir "$home/$m" \
      --autoplay-policy=no-user-gesture-required "--host-resolver-rules=MAP *.aircbrowser.com 127.0.0.1:$port" \
      "--unsafely-treat-insecure-origin-as-secure=$secure" --disable-features=HttpsUpgrades \
      -AppleLanguages '(en-GB)' -AppleLocale en_GB
    grep -E "social: |MISSING|FAIL" "$out/$m/log.txt" 2>/dev/null | sed 's/^/  /' || echo "  social: $m wrote no log (crash?)"
  done
  rm -rf "$home"
  exit 0
fi

# ---- On the Linux box ----
WORK="${AIRC_MAC_WORK:-social}"
# Its own folder on the Mac and here, so a release's build and main's can wait side by side: social or social-<name>.
case "$WORK" in social|social-*) ;; *) echo "error: AIRC_MAC_WORK must be social or social-<name>" >&2; exit 2 ;; esac
case "$WORK" in *[!a-z0-9-]*) echo "error: AIRC_MAC_WORK takes a-z, 0-9 and -" >&2; exit 2 ;; esac
# The build Mac only. The owner's laptop (ssh alias mac) runs nothing of ours (owner, 2026-11-09; briefs/common.md).
export AIRC_MAC_HOST="${AIRC_MAC_HOST:-buildmac}"
case "$AIRC_MAC_HOST" in mac|mac-*) echo "error: not on the owner's laptop ($AIRC_MAC_HOST); use buildmac" >&2; exit 2 ;; esac
STATUS="$(cd "$ROOT/.." && pwd)/status"
if [ "$CLEAN" = 1 ]; then
  "$ROOT/scripts/mac.sh" ssh "rm -rf ~/arcfork/work/$WORK"
  echo "deleted the Mac copy"
  exit 0
fi
ARTIFACTS="${AIRC_SOCIAL_ARTIFACTS:-$(cd "$ROOT/.." && pwd)/artifacts/social}"
SRC="$(cd "$ROOT/.." && pwd)/work/$WORK-src"
# HEAD, plus this tool's files and its scenario as they are now (they may not be committed yet).
case "$SRC" in */work/social-src|*/work/social-*-src) rm -rf -- "$SRC" ;; *) echo "error: unexpected source folder $SRC" >&2; exit 1 ;; esac
mkdir -p "$SRC"
git -C "$ROOT" archive "${REV_ARG:-HEAD}" | tar -x -C "$SRC"
# HEAD's own copy and UI lock, whatever the app is built from: a release's scripts can be older (0.1.3's mac.sh
# defaults to the laptop).
git -C "$ROOT" archive HEAD scripts/mac.sh scripts/ui-check-lock.py | tar -x -C "$SRC"
# A release from before the build Mac's toolchain doesn't compile there (Swift 6.3, Xcode 26.4): its source gets the
# compile-only fixes that came after it, nothing that changes what the app draws. source.txt says which.
TOOLCHAIN_FIXES="f448005"
COMPAT=""
if [ -n "$REV_ARG" ]; then
  for c in $TOOLCHAIN_FIXES; do
    git -C "$ROOT" merge-base --is-ancestor "$c" "$REV_ARG" && continue
    git -C "$ROOT" diff "$c^" "$c" | patch -s -p1 -d "$SRC" || { echo "error: toolchain fix $c doesn't apply to $REV_ARG" >&2; exit 1; }
    COMPAT="$COMPAT + $c"
  done
fi
mkdir -p "$SRC/tools/social"
cp -R "$ROOT/tools/social/." "$SRC/tools/social/"
DEBUG="$ROOT/apps/browser/Sources/Airc/Debug"
# The source's own Social*.swift go first: a release's tree can hold an older copy of a motion file (0.1.3's has the
# SocialNext.swift of its day) that would declare the same motions again.
rm -f "$SRC"/apps/browser/Sources/Airc/Debug/Social*.swift
cp "$DEBUG/SocialFrames.swift" "$DEBUG/SocialMotions.swift" "$SRC/apps/browser/Sources/Airc/Debug/"
# Motions of features newer than a release don't build on its source. A later release's file says the commit it needs
# ("// social-needs: <commit>") and goes into builds of that commit and after; SocialNext.swift only into HEAD's.
for f in "$DEBUG"/SocialMotions0*.swift "$DEBUG/SocialNext.swift"; do
  [ -f "$f" ] || continue
  needs=$(sed -n 's|^// social-needs: \([0-9a-f]\{7,40\}\).*|\1|p' "$f" | head -n 1)
  if [ -z "$REV_ARG" ] || { [ -n "$needs" ] && git -C "$ROOT" merge-base --is-ancestor "$needs" "$REV_ARG"; }; then
    cp "$f" "$SRC/apps/browser/Sources/Airc/Debug/"
  fi
done
runner="$SRC/apps/browser/Sources/Airc/Debug/SnapshotRunner.swift"
if ! grep -q 'case "social": socialScenario()' "$runner"; then
  # The one line in the script table, after the marketing line.
  line='        case "social": socialScenario()   // video frames for the social studio, not a check: tools/social/mac-frames.sh only'
  awk -v add="$line" '{ print } /case "marketing": marketingScenario\(\)/ { print add }' "$runner" > "$runner.new" && mv "$runner.new" "$runner"
fi
REV="$(git -C "$ROOT" rev-parse --short "${REV_ARG:-HEAD}")"
ENV="AIRC_SOURCE_REV='$REV' AIRC_MAC_MIN_FREE_GB='$MIN_FREE_GB'"
LOCK="$(cd "$ROOT/.." && pwd)/status/.agent-build.lock"
status=0
if [ "$BUILD" = 1 ]; then
  # buildmac's engine: once its ready marker exists, and only for a source whose engine/ isn't newer than the commit it
  # names (else wait for the next marker).
  if [ "$AIRC_MAC_HOST" = buildmac ]; then
    ready="$STATUS/buildmac-engine-ready"
    [ -f "$ready" ] || { echo "social: no $ready yet; try later" >&2; exit 75; }
    engine=$(head -n 1 "$ready" | awk '{print $1}')
    if [ -n "$(git -C "$ROOT" log --oneline "$engine..${REV_ARG:-HEAD}" -- engine/ | head -n 1)" ]; then
      echo "social: engine/ is newer than buildmac's ($engine); try after the next marker" >&2; exit 75
    fi
  fi
  # An engine relink or a quiet window goes first: an unstarted build waits while either is pending.
  while [ -e "$STATUS/relink-pending" ] || [ -e "$STATUS/quiet-pending" ]; do sleep 60; done
  # The build alone holds the agent build lock (one agent build at a time on the Mac); the time and a priority build
  # (only the agents its first line names) are checked once it's ours.
  # shellcheck disable=SC2016
  PRIORITY="$STATUS/priority-build" flock -E 75 -w "${AIRC_LOCK_WAIT:-900}" "$LOCK" bash -c '
    if [ -e "$PRIORITY" ] && ! head -n 1 "$PRIORITY" | grep -qiw social; then echo "social: a priority build is on; try later"; exit 75; fi
    now=$(date -u +%H%M)
    if [ "$now" -ge 0100 ] && [ "$now" -lt 0150 ]; then echo "social: not starting a build from 01:00 to 01:50 UTC (the nightly)"; exit 75; fi
    exec "$@"' sh "$SRC/scripts/mac.sh" -w "$WORK" run "$ENV bash tools/social/mac-frames.sh --on-mac --build-only" || status=$?
  if [ "$status" != 0 ]; then
    echo "social: no build (exit $status)" >&2
    # The sync may have copied the source before the Mac said no: nothing of ours stays there.
    [ "$KEEP" = 1 ] || "$SRC/scripts/mac.sh" ssh "rm -rf ~/arcfork/work/$WORK"
    exit "$status"
  fi
fi
# No launches in a measurement agent's quiet window.
if [ -e "$STATUS/quiet-pending" ]; then echo "social: a quiet window is on; try later"; exit 75; fi
# caffeinate -i: the Mac doesn't fall asleep idle while it draws (the screen still sleeps and locks as it would).
"$SRC/scripts/mac.sh" -w "$WORK" run "$ENV caffeinate -i bash tools/social/mac-frames.sh --on-mac --no-build --motions $(echo "$MOTIONS" | tr ' ' ',')" || status=$?
for m in $MOTIONS; do
  dest="$ARTIFACTS/_frames/$m"
  if "$SRC/scripts/mac.sh" ssh "test -f ~/arcfork/work/$WORK/build/social/$m/$m.json"; then
    # A new take replaces the old one whole, and says which source drew it.
    case "$dest" in */_frames/*) rm -rf -- "$dest" ;; esac
    mkdir -p "$dest"
    "$SRC/scripts/mac.sh" -w "$WORK" get "build/social/$m/" "$dest/"
    # (A build from before this file existed has none: under set -e and pipefail a failed read must not end the run.)
    built=$("$SRC/scripts/mac.sh" ssh "cat ~/arcfork/work/$WORK/build/social-source-rev.txt 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)
    echo "${built:-$REV}${REV_ARG:+ (release source)}${COMPAT:+$COMPAT (toolchain fix)}" > "$dest/source.txt"
  else
    echo "  social: no frames for $m"
  fi
done
if [ "$KEEP" = 1 ]; then
  "$SRC/scripts/mac.sh" ssh "rm -rf ~/arcfork/work/$WORK/build/social"
else
  "$SRC/scripts/mac.sh" ssh "rm -rf ~/arcfork/work/$WORK"
  echo "== deleted the Mac copy"
fi
echo "== frames: $ARTIFACTS/_frames"
exit $status
