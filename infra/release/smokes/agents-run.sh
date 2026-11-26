#!/bin/bash
# A scripted check in a fresh process and scratch home, under the build Mac's UI-check lock, with the bundled helper
# (Contents/Helpers/airc-mcp). Ported from release074's agents-run-script.sh (agentview's tools/mac/run-script.sh).
#   infra/release/smokes/agents-run.sh <engine> <posted|real> <script> <out-name> [extra app args…]
# real = FG=1: a dedicated foreground session (window key, app active) with the UI driver's real keys.
# OPEN_ENV / OPEN_ENV2 add one --env each; DATA=<dir> keeps a data folder between runs (write/relaunch pairs).
# Never launches on the lock's refusal (exit 75: retry later). Our app is stopped by its exact PID if it is still
# running LIMIT s after launch (default 300).
cd "$(dirname "$0")/../../.." || exit 1
root=$PWD
engine=$1 run=$2 script=$3 name=$4; shift 4
app="$root/build/Airc.app"; [ "$engine" = chromium ] && app="$root/build/Airc-Chromium.app"
base="$root/build/runs/smoke/$name"
rm -rf "$base"; mkdir -p "$base/home/Library" "$base/out"
OPENFLAGS="-g"; LOCKENV=""
[ "$run" = real ] && { OPENFLAGS="-g --env AIRC_LA_AS_OWNER=1 --env AIRC_REAL_KEYS=1"; LOCKENV="AIRC_UI_DEDICATED_SESSION=1"; }
H="$base/home"; [ -n "${DATA:-}" ] && { H="$DATA-home"; mkdir -p "$H/Library" "$DATA"; }
[ -x "$app/Contents/Helpers/airc-mcp" ] || { echo "no bundled helper in $app"; exit 1; }
watchdog() {
  local deadline=$((SECONDS + ${LIMIT:-300})) pid=""
  while [ $SECONDS -lt $deadline ]; do
    sleep 5
    pid=$(ps -axo pid=,command= | awk -v o="--snapshot $base/out" 'index($0, o) && $0 ~ /Contents\/MacOS\/Airc/ {print $1; exit}')
    [ -n "$pid" ] || { [ -f "$base/out/log.txt" ] && return; continue; }
  done
  pid=$(ps -axo pid=,command= | awk -v o="--snapshot $base/out" 'index($0, o) && $0 ~ /Contents\/MacOS\/Airc/ {print $1; exit}')
  if [ -n "$pid" ]; then
    echo "watchdog: stopping our app pid $pid (past ${LIMIT:-300} s)" | tee -a "$base/out/runner.txt"
    sample "$pid" 2 -file "$base/out/hang.txt" >/dev/null 2>&1
    kill "$pid"; sleep 10; kill -9 "$pid" 2>/dev/null
  fi
}
watchdog & wd=$!
env $LOCKENV AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py /bin/sh -c \
  'case "$(cat "$HOME/arcfork/.ui-check.lock")" in "pid=$PPID "*) ;; *) echo "NOLOCK: lock not ours, not launching"; exit 75;; esac; exec "$@"' \
  sh open $OPENFLAGS -n -W --env "CFFIXED_USER_HOME=$H" ${OPEN_ENV:+--env "$OPEN_ENV"} ${OPEN_ENV2:+--env "$OPEN_ENV2"} \
  "$app" --args --engine="$engine" --snapshot "$base/out" --script "$script" \
  $( [ -n "${DATA:-}" ] && echo "--data-dir $DATA" || echo "--ephemeral --data-dir $base/home/Data" ) "$@" </dev/null
rc=$?
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
[ $rc -eq 75 ] && { echo "LOCK-REFUSED"; exit 75; }
log="$base/out/log.txt"
echo "== $script $engine $run: exit $rc; PASS $(grep -c '^PASS ' "$log" 2>/dev/null) FAIL $(grep -c '^FAIL ' "$log" 2>/dev/null) FAIL-ENV $(grep -c '^FAIL-ENV ' "$log" 2>/dev/null)"
grep -E '^(FAIL|FAIL-ENV|ENGINE-FAIL) ' "$log" 2>/dev/null | head -40
exit $rc
