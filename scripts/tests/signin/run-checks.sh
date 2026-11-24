#!/bin/bash
# signin on the test Mac, from a work folder with a test build (build/Airc.app, build/Airc-Chromium.app):
#   scripts/tests/signin/run-checks.sh <webkit|chromium> [posted|real] [run-name]
# One UI-lock hold per launch (scripts/ui-check-lock.py; exit 75 = the lock refused: retry later). real: a dedicated
# session with the UI driver's real clicks. Our app is stopped by its exact PID if it is still running past LIMIT
# (default 420 s). Zero-guard: a run with no PASS line fails. Prints PASS/FAIL counts and every FAIL line.
set -uo pipefail
exec </dev/null
engine=$1 mode=${2:-posted} run=${3:-1}
cd "$(dirname "$0")/../../.." || exit 1
root=$PWD
app="$root/build/Airc.app"; [[ $engine == chromium ]] && app="$root/build/Airc-Chromium.app"
base="$root/build/runs/signin-$engine-$mode-$run"
rm -rf "$base"; mkdir -p "$base/home/Library" "$base/out" "$base/home/Data/Chromium"

envs=(CFFIXED_USER_HOME="$base/home")
# EXTRA_ENV="A=1 B=2": more environment for the app (diagnostics such as AIRC_QUIT_DIAG=1).
[[ -n ${EXTRA_ENV:-} ]] && for e in $EXTRA_ENV; do envs+=("$e"); done
if [[ $mode == real ]]; then
  envs+=(AIRC_LA_AS_OWNER=1 AIRC_REAL_KEYS=1 AIRC_REAL_CLICKS=1 AIRC_UI_DEDICATED_SESSION=1)
fi
args=(--engine="$engine" --snapshot "$base/out" --data-dir "$base/home/Data" --airc-data-dir="$base/home/Data"
      --disable-features=HttpsUpgrades)

watchdog() {
  local deadline=$((SECONDS + ${LIMIT:-420})) pid=""
  while [[ $SECONDS -lt $deadline ]]; do
    sleep 5
    pid=$(ps -axo pid=,command= | awk -v o="--snapshot $base/out" 'index($0, o) && $0 ~ /Contents\/MacOS\/Airc/ {print $1; exit}')
    [[ -n $pid ]] || { [[ -f $base/out/log.txt ]] && return; continue; }
  done
  pid=$(ps -axo pid=,command= | awk -v o="--snapshot $base/out" 'index($0, o) && $0 ~ /Contents\/MacOS\/Airc/ {print $1; exit}')
  if [[ -n $pid ]]; then echo "watchdog: stopping our app pid $pid (past ${LIMIT:-420} s)"; kill "$pid"; sleep 10; kill -9 "$pid" 2>/dev/null; fi
}

guard='case "$(cat "$HOME/arcfork/.ui-check.lock")" in "pid=$PPID "*) ;; *) echo "NOLOCK: lock not ours, not launching"; exit 75;; esac; exec "$@"'
echo "== signin $engine $mode run $run: start $(date -u +%H:%M:%S)"
watchdog & wd=$!
openenv=(); for e in "${envs[@]}"; do openenv+=(--env "$e"); done
# macOS /bin/bash 3.2 with set -u: an empty array can't be expanded, so no lockenv array at all in posted runs.
lockvar=""; [[ $mode == real ]] && lockvar="AIRC_UI_DEDICATED_SESSION=1"
env $lockvar python3 scripts/ui-check-lock.py /bin/sh -c "$guard" sh \
  open -g -n -W "${openenv[@]}" "$app" --args --script signin "${args[@]}"
rc=$?
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
log="$base/out/log.txt"
pass=$(grep -c '^PASS ' "$log" 2>/dev/null); fail=$(grep -c '^FAIL ' "$log" 2>/dev/null)
echo "== signin $engine $mode run $run: exit $rc; PASS ${pass:-0} FAIL ${fail:-0} FAIL-ENV $(grep -c '^FAIL-ENV ' "$log" 2>/dev/null)"
grep -E '^(FAIL|FAIL-ENV|ENGINE-FAIL|SKIP) ' "$log" 2>/dev/null | head -40
[[ $rc -eq 75 ]] && exit 75
if [[ ${pass:-0} == 0 ]]; then echo "ZERO-GUARD FAIL: signin $engine made 0 assertions"; exit 1; fi
[[ ${fail:-0} == 0 ]] || exit 1
exit $rc
