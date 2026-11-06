#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Build and test the committed tree (HEAD) on the build Mac, then refresh the status page.
# Runs from the Linux box: nightly from cron, or by hand whenever a build is wanted.
#
#   infra/nightly.sh            full run
#   infra/nightly.sh --no-engine  skip starting the Chromium engine build
#   infra/nightly.sh --ship       daytime shipping (infra/ship-loop.sh): the publish gate is the package tests, both
#                                 bundles and every snapshot check on Chromium, the owner's engine; the WebKit dev
#                                 engine's checks run after publishing as advice for agents; no engine build, no perf
#
# Env: AIRC_MAC_HOST (ssh alias, default "mac"), AIRC_STATUS_DIR (default ../status next to the repo).
# The operator's local config, airc.env beside the checkout (AIRC_UPDATES_CONFIG overrides; never committed), may set
# AIRC_DEV_CHANNEL=1 and AIRC_UPDATE_FEED: then the Chromium bundle is a dev-channel build, and a green run (every
# package test and every snapshot check on both engines) is published to the dev feed after a fresh launch smoke
# (infra/updates/publish.sh, docs/release.md "Private dev channel"). AIRC_SIGN_IDENTITY there signs those builds with a
# certificate on the Mac after testing, in prepare-mac.sh; test bundles stay ad hoc.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATES_CONFIG=${AIRC_UPDATES_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f "$UPDATES_CONFIG" ]] || source "$UPDATES_CONFIG"
HOST="${AIRC_MAC_HOST:-mac}"
STATUS="${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}"
ENGINE=1; PERF=0; SHIP=0
for arg in "$@"; do
  case "$arg" in
    --no-engine) ENGINE=0 ;;
    --ship) SHIP=1; ENGINE=0 ;;
    --perf) PERF=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
STAMP="$(date -u +%Y-%m-%d_%H%M)"
RUN="$STATUS/runs/$STAMP"
REMOTE="arcfork/nightly"
mkdir -p "$RUN"
exec 9>"$STATUS/.lock"; flock -n 9 || { echo "another run is in progress"; exit 1; }

git -C "$ROOT" rev-parse --short HEAD > "$RUN/rev.txt"
git -C "$ROOT" log -1 --format='%s' > "$RUN/subject.txt"
: > "$RUN/steps.tsv"

# step NAME CMD...: run, log to NAME.log, record "name<TAB>exit<TAB>seconds".
step() {
  local name="$1"; shift
  local t0; t0=$(date +%s)
  "$@" > "$RUN/$name.log" 2>&1
  local rc=$?
  printf '%s\t%s\t%s\n' "$name" "$rc" "$(( $(date +%s) - t0 ))" >> "$RUN/steps.tsv"
  return $rc
}
in_head() { git -C "$ROOT" cat-file -e "HEAD:$1" 2>/dev/null; }  # build only what is committed
mac() { ssh -o ConnectTimeout=15 "$HOST" "zsh -lc $(printf '%q' "$*")"; }

# Preserve the existing remote command while supplying dev flags to the build.
if [[ ${AIRC_DEV_CHANNEL:-0} == 1 ]]; then
  : "${AIRC_UPDATE_FEED:?Dev publishing requires the operator feed URL}"
  mac() {
    local command
    printf -v command 'export AIRC_DEV_CHANNEL=1 AIRC_UPDATE_CHANNEL=dev AIRC_UPDATE_FEED=%q AIRC_SIGN_IDENTITY=%q AIRC_SIGN_KEYCHAIN=%q AIRC_SIGN_KEYCHAIN_PASSWORD_FILE=%q; export SPARKLE_ROOT="$HOME/arcfork/tools/sparkle"; %s' "$AIRC_UPDATE_FEED" "${AIRC_SIGN_IDENTITY:-}" "${AIRC_SIGN_KEYCHAIN:-}" "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:-}" "$*"
    ssh -o ConnectTimeout=15 "$HOST" "zsh -lc $(printf '%q' "$command")"
  }
fi

finish() { python3 "$ROOT/infra/status.py" "$STATUS" --live; exit 0; }

if ! step mac-online mac 'sw_vers -productVersion; pmset -g batt | head -2; df -h / | tail -1'; then
  finish
fi

step export bash -c "ssh -o ConnectTimeout=15 '$HOST' 'rm -rf ~/$REMOTE && mkdir -p ~/$REMOTE' && git -C '$ROOT' archive HEAD | ssh '$HOST' 'tar -x -C ~/$REMOTE'" \
  || finish

GREEN=1   # every step so far passed: only a green run is published
for name in $(git -C "$ROOT" ls-tree --name-only HEAD packages/ | xargs -n1 basename 2>/dev/null); do
  in_head "packages/$name/Package.swift" || continue
  step "test-$name" mac "cd ~/$REMOTE && caffeinate -i -s swift test --package-path packages/$name" || GREEN=0
done

if in_head scripts/build-app.sh; then
  # --ship gates on Chromium only (with the framework present); WebKit's checks follow the publish below.
  SNAPSHOT_GATE=""
  if [[ $SHIP == 1 ]] && ssh -o ConnectTimeout=15 "$HOST" 'test -d ~/arcfork/chromium/src/out/AircRelease/"Airc Framework.framework"'; then
    SNAPSHOT_GATE="--snapshot-engines chromium"
  fi
  # Builds Airc.app and runs the scripted scenario, which writes window snapshots.
  # The owner's build uses the DCHECK-off framework (out/AircRelease, like Chrome stable) once it exists;
  # agents test against out/Airc with DCHECKs on.
  # The export has no .git: the bundles record the commit through AIRC_SOURCE_REV.
  step build-app mac "cd ~/$REMOTE && export AIRC_SOURCE_REV=$(cat "$RUN/rev.txt"); R=~/arcfork/chromium/src/out/AircRelease; if [ -d \"\$R/Airc Framework.framework\" ]; then export CHROMIUM_OUT=\$R; echo \"framework: \$R\"; fi; AIRC_SIGN_IDENTITY=- AIRC_SHIP_GATE=$SHIP caffeinate -i -s scripts/build-app.sh --snapshots build/snapshots $SNAPSHOT_GATE" \
    || GREEN=0
  # Dev channel: publish only a green run, and only after publish.sh's own fresh launch smoke of the Chromium bundle.
  if [[ ${AIRC_DEV_CHANNEL:-0} == 1 ]] && in_head infra/updates/publish.sh; then
    if [[ $GREEN == 1 ]]; then
      step publish-dev "$ROOT/infra/updates/publish.sh" "$REMOTE"
    else
      step publish-dev bash -c 'echo "not published: a test or snapshot check failed (see the steps above)"; exit 3'
    fi
  fi
  if [[ -n $SNAPSHOT_GATE ]]; then
    # Advice, not a gate: the WebKit dev engine's checks on the same build, after the owner's build is out.
    step snapshots-webkit mac "cd ~/$REMOTE && AIRC_SIGN_IDENTITY=- caffeinate -i -s scripts/build-app.sh --no-test --engine webkit --snapshots build/snapshots-webkit"
  fi
  # Refresh the owner's copy whenever the bundles were built, even if a check failed (the status page shows it).
  if ssh -o ConnectTimeout=15 "$HOST" "test -d ~/$REMOTE/build/Airc.app"; then
    # The copy the owner opens to try the latest build (~/arcfork/try/Airc.app); skipped while it's running.
    step try-copy mac "[ -d ~/Applications/Airc.app ] && { echo 'the owner runs ~/Applications/Airc.app, which updates itself; try copies are no longer refreshed'; exit 3; }; pgrep -f 'arcfork/try/Airc' >/dev/null && { echo 'Airc is open; keeping the current copies'; exit 3; }; mkdir -p ~/arcfork/try && rsync -a --delete ~/$REMOTE/build/Airc.app/ ~/arcfork/try/Airc.app/ && if [ -d ~/$REMOTE/build/Airc-Chromium.app ]; then rsync -a --delete ~/$REMOTE/build/Airc-Chromium.app/ ~/arcfork/try/Airc-Chromium.app/; fi; rm -rf ~/arcfork/try/Airc-new.app"
  fi
  rsync -az "$HOST:$REMOTE/build/snapshots/" "$RUN/snapshots/" >/dev/null 2>&1 || true
fi

# Performance is intrusive enough to reserve for 23:00–07:00 UTC, unless requested.
if [[ $SHIP == 0 ]] && in_head scripts/perf.sh; then
  hour=$(date -u +%H)
  if [[ $PERF == 1 ]] || (( 10#$hour < 7 || 10#$hour >= 23 )); then
    # The instrumented reference workload (--script perf) on both engines. The status page trend reads
    # results.json, which is the Chromium run (the real product); WebKit is kept alongside.
    step perf-webkit timeout --kill-after=30s 15m ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$HOST" \
      "cd ~/$REMOTE && caffeinate -d -i -s -t 900 scripts/perf.sh --instrumented --app build/Airc.app --output ~/$REMOTE/build/perf-webkit"
    timeout 30s rsync -az "$HOST:$REMOTE/build/perf-webkit/results.json" "$RUN/results-webkit.json" >> "$RUN/perf.log" 2>&1 || true
    if ssh -o ConnectTimeout=15 "$HOST" "test -d ~/$REMOTE/build/Airc-Chromium.app"; then
      step perf timeout --kill-after=30s 15m ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$HOST" \
        "cd ~/$REMOTE && caffeinate -d -i -s -t 900 scripts/perf.sh --instrumented --app build/Airc-Chromium.app --output ~/$REMOTE/build/perf"
      timeout 30s rsync -az "$HOST:$REMOTE/build/perf/results.json" "$RUN/results.json" >> "$RUN/perf.log" 2>&1 || true
      timeout 30s rsync -az "$HOST:$REMOTE/build/perf/summary.txt" "$RUN/perf-summary.txt" >> "$RUN/perf.log" 2>&1 || true
    fi
  else
    step perf bash -c 'echo "daytime: use --perf to override"; exit 3'
  fi
fi

# The engine build takes hours: start it detached on the Mac (if the checkout is ready and no
# build is running) and let the status page read its log.
if [[ $ENGINE == 1 ]] && in_head engine/build.sh; then
  step engine-start mac "
    if screen -ls | grep -q '[.]airc-engine[[:space:]]'; then echo 'engine build already running'; exit 0; fi
    if ! tail -n 1 ~/arcfork/fetch-chromium.log 2>/dev/null | grep -q 'EXIT 0'; then echo 'Chromium checkout not ready'; exit 3; fi
    mkdir -p ~/arcfork/engine-src && rsync -a --delete ~/$REMOTE/ ~/arcfork/engine-src/
    ~/arcfork/engine-src/engine/build.sh --start"
fi

finish
