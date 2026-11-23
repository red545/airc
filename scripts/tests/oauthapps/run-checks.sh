#!/bin/bash
# oauthapps on the test Mac, from a work folder with a test build (build/Airc.app, build/Airc-Chromium.app):
#   scripts/tests/oauthapps/run-checks.sh <webkit|chromium> <warm|cold> [posted|real] [run-name] [before]
# warm: `--script oauthapps` (the check launches the fake app itself). cold: the fake app's sign-in launches Airc
# (`--script oauthapps-cold`), as when Airc isn't running. Each launch is one UI-lock hold (scripts/ui-check-lock.py,
# exit 75 = the lock refused: retry later). real: a dedicated session with the UI driver's real clicks. before: the
# before arm (AIRC_EXTERNAL_APPS_BEFORE=1). Our app is stopped by its exact PID if it is still running past LIMIT
# (default 300 s). Zero-guard: a run with no PASS line fails. Prints PASS/FAIL counts and every FAIL line.
set -uo pipefail
exec </dev/null
engine=$1 kind=$2 mode=${3:-posted} run=${4:-1} arm=${5:-}
cd "$(dirname "$0")/../../.." || exit 1
root=$PWD
app="$root/build/Airc.app"; [[ $engine == chromium ]] && app="$root/build/Airc-Chromium.app"
port=${AIRC_OAUTHAPPS_PORT:-47811}
base="$root/build/runs/oauthapps-$engine-$kind-$mode$arm-$run"
rm -rf "$base"; mkdir -p "$base/home/Library" "$base/out" "$base/home/Data/Chromium"
fake="$root/build/oauthapps/Fake Desktop App.app"
[[ -x "$fake/Contents/MacOS/FakeDesktopApp" ]] || bash scripts/tests/oauthapps/build-fake-app.sh "$root/build/oauthapps" >/dev/null || exit 1
oalog="$base/fake-app.log"
# A fake app left from an earlier run holds the port: stop it by its exact PID.
for pid in $(pgrep -f "$fake/Contents/MacOS/FakeDesktopApp" 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 0.5

hosts="--host-resolver-rules=MAP *.example 127.0.0.1"
secure="--unsafely-treat-insecure-origin-as-secure=http://app.example:$port"
envs=(CFFIXED_USER_HOME="$base/home" AIRC_OAUTHAPPS_PORT="$port" AIRC_OAUTHAPPS_LOG="$oalog"
      AIRC_OAUTHAPPS_FAKE_APP="$fake" AIRC_TEST_WEBKIT_PROXY="$port:accounts.example,app.example")
lockenv=()
if [[ $mode == real ]]; then
  envs+=(AIRC_LA_AS_OWNER=1 AIRC_REAL_KEYS=1 AIRC_REAL_CLICKS=1 AIRC_UI_DEDICATED_SESSION=1)
  lockenv=(AIRC_UI_DEDICATED_SESSION=1)
fi
[[ $arm == before ]] && envs+=(AIRC_EXTERNAL_APPS_BEFORE=1)
args=(--engine="$engine" --snapshot "$base/out" --data-dir "$base/home/Data" --airc-data-dir="$base/home/Data"
      "$hosts" --disable-features=HttpsUpgrades "$secure")

watchdog() {
  local deadline=$((SECONDS + ${LIMIT:-300})) pid=""
  while [[ $SECONDS -lt $deadline ]]; do
    sleep 5
    pid=$(ps -axo pid=,command= | awk -v o="--snapshot $base/out" 'index($0, o) && $0 ~ /Contents\/MacOS\/Airc/ {print $1; exit}')
    [[ -n $pid ]] || { [[ -f $base/out/log.txt ]] && return; continue; }
  done
  pid=$(ps -axo pid=,command= | awk -v o="--snapshot $base/out" 'index($0, o) && $0 ~ /Contents\/MacOS\/Airc/ {print $1; exit}')
  if [[ -n $pid ]]; then echo "watchdog: stopping our app pid $pid (past ${LIMIT:-300} s)"; kill "$pid"; sleep 10; kill -9 "$pid" 2>/dev/null; fi
}

guard='case "$(cat "$HOME/arcfork/.ui-check.lock")" in "pid=$PPID "*) ;; *) echo "NOLOCK: lock not ours, not launching"; exit 75;; esac; exec "$@"'
echo "== oauthapps $engine $kind $mode$arm run $run: start $(date -u +%H:%M:%S)"
watchdog & wd=$!
if [[ $kind == warm ]]; then
  openenv=(); for e in "${envs[@]}"; do openenv+=(--env "$e"); done
  env ${lockenv[@]+"${lockenv[@]}"} python3 scripts/ui-check-lock.py /bin/sh -c "$guard" sh \
    open -g -n -W "${openenv[@]}" "$app" --args --script oauthapps "${args[@]}"
  rc=$?
else
  # The fake app launches Airc through Launch Services with the sign-in link (cold start), and quits when Airc quits.
  fa=(--port "$port" --log "$oalog" --airc "$app" --start scheme)
  [[ $mode == real ]] && fa+=(--activate)
  for a in --script oauthapps-cold "${args[@]}"; do fa+=(--airc-arg "$a"); done
  for e in "${envs[@]}"; do fa+=(--airc-env "$e"); done
  env ${lockenv[@]+"${lockenv[@]}"} python3 scripts/ui-check-lock.py /bin/sh -c "$guard" sh \
    "$fake/Contents/MacOS/FakeDesktopApp" "${fa[@]}"
  rc=$?
fi
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
for pid in $(pgrep -f "$fake/Contents/MacOS/FakeDesktopApp" 2>/dev/null); do kill "$pid" 2>/dev/null; done
log="$base/out/log.txt"
pass=$(grep -c '^PASS ' "$log" 2>/dev/null); fail=$(grep -c '^FAIL ' "$log" 2>/dev/null)
echo "== oauthapps $engine $kind $mode$arm run $run: exit $rc; PASS ${pass:-0} FAIL ${fail:-0} FAIL-ENV $(grep -c '^FAIL-ENV ' "$log" 2>/dev/null)"
grep -E '^(FAIL|FAIL-ENV|ENGINE-FAIL|SKIP) ' "$log" 2>/dev/null | head -40
[[ $rc -eq 75 ]] && exit 75
if [[ ${pass:-0} == 0 ]]; then echo "ZERO-GUARD FAIL: oauthapps $engine $kind made 0 assertions"; exit 1; fi
[[ ${fail:-0} == 0 ]] || exit 1
exit $rc
