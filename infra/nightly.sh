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
# Env: AIRC_MAC_HOST (ssh alias, default "buildmac"), AIRC_STATUS_DIR (default ../status next to the repo).
# The operator's local config, airc.env beside the checkout (AIRC_UPDATES_CONFIG overrides; never committed), may set
# AIRC_DEV_CHANNEL=1 and AIRC_UPDATE_FEED: then the Chromium bundle is a dev-channel build, and a green run (every
# package test and every snapshot check on both engines) is published to the dev feed after a fresh launch smoke
# (infra/updates/publish.sh, docs/release.md "Private dev channel"). AIRC_SIGN_IDENTITY there signs those builds with a
# certificate on the Mac after testing, in prepare-mac.sh; test bundles stay ad hoc.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATES_CONFIG=${AIRC_UPDATES_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f "$UPDATES_CONFIG" ]] || source "$UPDATES_CONFIG"
HOST="${AIRC_MAC_HOST:-buildmac}"
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
REMOTE=${AIRC_NIGHTLY_REMOTE:-arcfork/nightly}
[[ $REMOTE =~ ^arcfork/[a-zA-Z0-9/_-]+$ && $REMOTE != *..* && $REMOTE != */ ]] || exit 2
if [[ ${AIRC_PREPARATION:-0} == 1 ]]; then
  [[ $HOST == buildmac && $SHIP == 1 && ${AIRC_DEV_CHANNEL:-0} == 0 && $REMOTE =~ ^arcfork/setup/automation/run-[a-zA-Z0-9_-]+$ ]] || {
    echo 'preparation requires --ship, dev publication disabled and an isolated remote' >&2; exit 2;
  }
  [[ -n ${AIRC_STATUS_DIR:-} && -n ${AIRC_UPDATES_CONFIG:-} ]] || exit 2
  [[ $(realpath -m "$STATUS") != $(realpath -m "$(dirname "$ROOT")/status") ]] || exit 2
fi
REV=$(git -C "$ROOT" rev-parse HEAD)
mkdir -p "$RUN"
exec 9>"$STATUS/.lock"
# The public nightly sets AIRC_LOCK_WAIT (seconds) to wait for a daytime run instead of giving up (2026-11-08).
if [[ -n ${AIRC_LOCK_WAIT:-} ]]; then flock -w "$AIRC_LOCK_WAIT" 9; else flock -n 9; fi || { echo "another run is in progress"; exit 1; }

git -C "$ROOT" rev-parse --short "$REV" > "$RUN/rev.txt"
git -C "$ROOT" log -1 --format='%s' "$REV" > "$RUN/subject.txt"
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
in_head() { git -C "$ROOT" cat-file -e "$REV:$1" 2>/dev/null; }  # build only what is committed
mac() { ssh -o ConnectTimeout=15 "$HOST" "zsh -lc $(printf '%q' "export PATH=\"\$HOME/arcfork/tools/depot_tools/python-bin:\$HOME/arcfork/tools/depot_tools:\$PATH\" AIRC_UI_LOCK_STRICT=1 AIRC_UI_LOCK_PER_LAUNCH=${AIRC_PREPARATION:-0}; $*")"; }

# Preserve the existing remote command while supplying dev flags to the build.
if [[ ${AIRC_DEV_CHANNEL:-0} == 1 ]]; then
  AIRC_UPDATE_FEED=${LOCAL_FEED:-http://127.0.0.1:3483/appcast.xml}
  mac() {
    local command
    printf -v command 'export PATH="$HOME/arcfork/tools/depot_tools/python-bin:$HOME/arcfork/tools/depot_tools:$PATH"; export AIRC_UI_LOCK_STRICT=1 AIRC_DEV_CHANNEL=1 AIRC_UPDATE_CHANNEL=dev AIRC_UPDATE_FEED=%q AIRC_SIGN_IDENTITY=%q AIRC_SIGN_KEYCHAIN=%q AIRC_SIGN_KEYCHAIN_PASSWORD_FILE=%q; export SPARKLE_ROOT="$HOME/arcfork/tools/sparkle"; %s' "$AIRC_UPDATE_FEED" "${AIRC_SIGN_IDENTITY:-}" "${AIRC_SIGN_KEYCHAIN:-}" "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:-}" "$*"
    ssh -o ConnectTimeout=15 "$HOST" "zsh -lc $(printf '%q' "$command")"
  }
fi

finish() {
  # Explicitly unlock before status rendering or starting background workers. No child inherits fd 9.
  flock -u 9; exec 9>&-
  printf '%s ship lock released\n' "$(date -u +%FT%TZ)" >> "$RUN/lock.log"
  if [[ ${AIRC_PREPARATION:-0} == 1 ]]; then
    python3 "$ROOT/infra/dry_ship_result.py" "$RUN/steps.tsv"
    exit $?
  fi
  if ! tmux has-session -t airc-deferred 2>/dev/null; then
    tmux new -d -s airc-deferred "bash '$ROOT/infra/updates/deferred.sh' >> '$STATUS/deferred.log' 2>&1"
  fi
  python3 "$ROOT/infra/status.py" "$STATUS" --live
  exit 0
}

if ! step mac-online mac 'sw_vers -productVersion; pmset -g batt | head -2; df -h / | tail -1'; then
  finish
fi

step export bash -o pipefail -c "ssh -o ConnectTimeout=15 '$HOST' 'rm -rf ~/$REMOTE && mkdir -p ~/$REMOTE' && git -C '$ROOT' archive '$REV' | ssh '$HOST' 'tar -x -C ~/$REMOTE'" \
  || finish

# Avoid compiling/retesting the same HEAD every retry while the owner is away.
# build-app repeats this immediately before UI, and each launch after waiting for the UI lock.
if [[ $SHIP == 1 ]] && in_head infra/ui_gate.py; then
  step ui-preflight mac "cd ~/$REMOTE && mkdir -p build && python3 infra/ui_gate.py preflight build/ui-gate-start.json"
  preflight_rc=$?
  if [[ $preflight_rc != 0 ]]; then
    mac "cat ~/$REMOTE/build/ui-gate-start.json" > "$RUN/ui-gate.json" 2>/dev/null || true
    finish
  fi
fi

# Refuse app builds against an engine older than this exact source export.
if [[ $HOST == buildmac ]]; then
  engine_ready=${AIRC_ENGINE_READY_FILE:-$(dirname "$ROOT")/status/buildmac-engine-ready}
  ready=$(awk 'NR==1 {print $1}' "$engine_ready" 2>/dev/null || true)
  if [[ ! $ready =~ ^[0-9a-f]{40}$ ]] || ! git -C "$ROOT" diff --quiet "$ready" "$REV" -- engine/core engine/patches ':(glob)engine/*.gn' ':(glob)engine/*.gni' ':(glob)engine/BUILD*' CHROMIUM_VERSION; then
    step engine-ready bash -c 'echo "engine owner must reconcile this revision first"; exit 75'
    finish
  fi
  step engine-framework mac 'test -f "$HOME/arcfork/chromium/src/out/AircRelease/Airc Framework.framework/Versions/Current/Airc Framework"' || finish
fi
GREEN=1   # every step so far passed: only a green run is published
for name in $(git -C "$ROOT" ls-tree --name-only "$REV" packages/ | xargs -n1 basename 2>/dev/null); do
  in_head "packages/$name/Package.swift" || continue
  step "test-$name" mac "set -o pipefail; cd ~/$REMOTE && caffeinate -i -s python3 scripts/build-lock.py swift test --package-path packages/$name 2>&1 | python3 infra/xctest_summary.py" || GREEN=0
done

if [[ ${AIRC_PREPARATION:-0} == 1 && $GREEN != 1 ]]; then finish; fi

if in_head scripts/build-app.sh; then
  # --ship gates on Chromium only (with the framework present); WebKit's checks follow the publish below.
  SNAPSHOT_GATE=""
  if [[ $SHIP == 1 && ${AIRC_PREPARATION:-0} != 1 ]] && ssh -o ConnectTimeout=15 "$HOST" 'test -d ~/arcfork/chromium/src/out/AircRelease/"Airc Framework.framework"'; then
    SNAPSHOT_GATE="--snapshot-engines chromium"
  fi
  # Builds Airc.app and runs the scripted scenario, which writes window snapshots.
  # The owner's build uses the DCHECK-off framework (out/AircRelease, like Chrome stable) once it exists;
  # agents test against out/Airc with DCHECKs on.
  # The export has no .git: the bundles record the commit through AIRC_SOURCE_REV.
  step build-app mac "cd ~/$REMOTE && export AIRC_SOURCE_REV=$(cat "$RUN/rev.txt"); R=~/arcfork/chromium/src/out/AircRelease; if [ -d \"\$R/Airc Framework.framework\" ]; then export CHROMIUM_OUT=\$R; echo \"framework: \$R\"; fi; AIRC_SIGN_IDENTITY=- AIRC_SHIP_GATE=$SHIP caffeinate -i -s python3 scripts/build-lock.py scripts/build-app.sh --snapshots build/snapshots $SNAPSHOT_GATE" \
    || GREEN=0
  # Keep the gate evidence before publishing or ending the run. Exit 75 is waiting/ENV,
  # never green; a package/build failure still wins over a locked UI phase.
  mac "cat ~/$REMOTE/build/snapshots/ui-gate.json" > "$RUN/ui-gate.json" 2>/dev/null || true
  # Dev channel: publish only a green run, and only after publish.sh's own fresh launch smoke of the Chromium bundle.
  if [[ ${AIRC_DEV_CHANNEL:-0} == 1 ]] && in_head infra/updates/publish.sh; then
    if [[ ${AIRC_PUBLISH_HOLD:-0} == 1 ]]; then
      step publish-dev bash -c 'echo "publication held by operator; feed unchanged"; exit 3'
    elif [[ $GREEN == 1 ]]; then
      step publish-dev "$ROOT/infra/updates/publish.sh" "$REMOTE"
    else
      step publish-dev bash -c 'echo "not published: a test failed or the UI gate is waiting/ENV (see the steps above)"; exit 3'
    fi
  fi
  if [[ -n $SNAPSHOT_GATE && $SHIP == 0 ]]; then
    # Advice, not a gate: the WebKit dev engine's checks on the same build, after the owner's build is out.
    step snapshots-webkit mac "cd ~/$REMOTE && AIRC_SIGN_IDENTITY=- caffeinate -i -s python3 scripts/build-lock.py scripts/build-app.sh --no-test --engine webkit --snapshots build/snapshots-webkit"
  fi
  # Free report slots after app tests, including failed runs, on both ship and nightly.
  [[ ${AIRC_PREPARATION:-0} == 1 ]] || step crash-hygiene mac "cd ~/$REMOTE && python3 infra/diagnostic_hygiene.py"
  # Persist uploads locally before the next export replaces nightly. APFS clones cost no uplink.
  [[ ${AIRC_PREPARATION:-0} == 1 ]] || step defer-artifacts mac "cd ~/$REMOTE && bash infra/updates/defer-mac.sh $STAMP"
  # Text check results are small and keep the work/status pages current even while images wait.
  timeout 45s rsync -az --include='*/' --include='*.txt' --exclude='*' \
    "$HOST:$REMOTE/build/snapshots/" "$RUN/snapshots/" >> "$RUN/metadata-copy.log" 2>&1 || true
  if [[ $SHIP == 1 ]]; then finish; fi

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
if [[ $ENGINE == 1 && $HOST != buildmac ]] && in_head engine/build.sh; then
  step engine-start mac "
    if screen -ls | grep -q '[.]airc-engine[[:space:]]'; then echo 'engine build already running'; exit 0; fi
    if ! tail -n 1 ~/arcfork/fetch-chromium.log 2>/dev/null | grep -q 'EXIT 0'; then echo 'Chromium checkout not ready'; exit 3; fi
    mkdir -p ~/arcfork/engine-src && rsync -a --delete ~/$REMOTE/ ~/arcfork/engine-src/
    ~/arcfork/engine-src/engine/build.sh --start"
fi

finish
