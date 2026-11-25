#!/bin/bash
# passkeyquit on the test Mac, from a work folder with a test build (build/Airc.app, build/Airc-Chromium.app):
#   scripts/tests/passkeyquit/run-checks.sh <webkit|chromium> [posted|real] [run-name]
# Environment: QUIT=hold|menu|ae (how the app is quit at the end; default hold = ⌘Q; ae = the Dock's quit Apple
# Event), GUARD=off|sso|pass (WebKit arms: off = before the fix, sso = the Apple ID SSO sheet allowed, pass = an
# entitled build's request tracking), REAL=1 (the real appleid.apple.com sign-in page too, signed out, nothing typed).
# One UI-lock hold per launch (scripts/ui-check-lock.py; exit 75 = the lock refused: retry later). real: a dedicated
# session with the UI driver's real keys. The check's last step quits the app with a passkey request (or SSO sheet) open; this
# runner watches our exact PID and adds the assertion "the app exits within 3 s of the quit" to the log. Our app is
# stopped by its exact PID if it is still running past LIMIT (default 300 s). Zero-guard: a run with no PASS line
# fails. Prints PASS/FAIL counts and every FAIL line.
set -uo pipefail
exec </dev/null
engine=$1 mode=${2:-posted} run=${3:-1}
cd "$(dirname "$0")/../../.." || exit 1
root=$PWD
app="$root/build/Airc.app"; [[ $engine == chromium ]] && app="$root/build/Airc-Chromium.app"
base="$root/build/runs/passkeyquit-$engine-$mode-$run"
rm -rf "$base"; mkdir -p "$base/home/Library" "$base/out" "$base/home/Data/Chromium"
log="$base/out/log.txt"

envs="CFFIXED_USER_HOME=$base/home AIRC_PASSKEYQUIT_QUIT=${QUIT:-hold}"
[[ -n ${GUARD:-} ]] && envs="$envs AIRC_TEST_PASSKEY_GUARD=$GUARD"
[[ ${REAL:-0} == 1 ]] && envs="$envs AIRC_PASSKEYQUIT_REAL=1"
[[ $mode == real ]] && envs="$envs AIRC_LA_AS_OWNER=1 AIRC_REAL_KEYS=1 AIRC_REAL_CLICKS=1 AIRC_UI_DEDICATED_SESSION=1"
[[ -n ${EXTRA_ENV:-} ]] && envs="$envs $EXTRA_ENV"
openenv=""; for e in $envs; do openenv="$openenv --env $e"; done

# Our app's PID (exact: its --snapshot folder), then the moment it is gone, at 20 Hz, into $base/exit.txt.
watch_exit() {
  python3 - "$base/out" "$base/exit.txt" "${LIMIT:-300}" <<'PY'
import os, subprocess, sys, time
out, dest, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
start = time.time(); pid = None
while time.time() - start < limit and pid is None:
    ps = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        if ('--snapshot ' + out) in line and 'Contents/MacOS/Airc' in line:
            pid = int(line.split()[0]); break
    if pid is None: time.sleep(0.5)
if pid is None: sys.exit(0)
while time.time() - start < limit:
    try: os.kill(pid, 0)
    except ProcessLookupError:
        open(dest, 'w').write('%.3f %d\n' % (time.time(), pid)); sys.exit(0)
    time.sleep(0.05)
print('watchdog: stopping our app pid %d (past %d s)' % (pid, limit), flush=True)
try:
    os.kill(pid, 15); time.sleep(10); os.kill(pid, 9)
except ProcessLookupError: pass
PY
}

guard='case "$(cat "$HOME/arcfork/.ui-check.lock")" in "pid=$PPID "*) ;; *) echo "NOLOCK: lock not ours, not launching"; exit 75;; esac; exec "$@"'
echo "== passkeyquit $engine $mode run $run (quit ${QUIT:-hold}${GUARD:+, guard $GUARD}${REAL:+, real appleid}): start $(date -u +%H:%M:%S)"
watch_exit & wd=$!
lockvar=""; [[ $mode == real ]] && lockvar="AIRC_UI_DEDICATED_SESSION=1"
env $lockvar python3 scripts/ui-check-lock.py /bin/sh -c "$guard" sh \
  open -g -n -W $openenv "$app" --args --script passkeyquit --engine="$engine" --snapshot "$base/out" \
  --ephemeral --data-dir "$base/home/Data" --disable-features=HttpsUpgrades
rc=$?
wait "$wd" 2>/dev/null
[[ $rc -eq 75 ]] && { echo "lock refused"; exit 75; }

# The quit assertion: from the QUIT-SENT line the app wrote to the moment its PID was gone.
python3 - "$log" "$base/exit.txt" "$engine" <<'PY'
import re, sys
log, exitf, engine = sys.argv[1], sys.argv[2], {'webkit': 'WebKit', 'chromium': 'Chromium'}.get(sys.argv[3], sys.argv[3])
try: text = open(log).read()
except FileNotFoundError: text = ''
m = re.search(r'QUIT-SENT ([0-9.]+) (.*)', text)
try: gone = float(open(exitf).read().split()[0])
except Exception: gone = None
if not m:
    line = 'FAIL passkeyquit %s: the check reached its quit step (no QUIT-SENT line)' % engine
elif gone is None:
    line = 'FAIL passkeyquit %s: the app exits after the quit (%s; the runner never saw it exit)' % (engine, m.group(2))
else:
    dt = gone - float(m.group(1))
    held = 'termination did not finish' in text
    at = re.search(r'SHEET-AT-QUIT (yes|no)', text)
    m2 = '%s; system sheet attached at the quit: %s' % (m.group(2), at.group(1) if at else '?')
    line = '%s passkeyquit %s: the app exits within 3 s of the quit with a passkey request (or SSO sheet) open (%.2f s; %s%s)' % (
        'PASS' if dt <= 3 and not held else 'FAIL', engine, dt, m2, '; quit bound hit' if held else '')
with open(log, 'a') as f: f.write(line + '\n')
print(line)
PY
pass=$(grep -c '^PASS ' "$log" 2>/dev/null); fail=$(grep -c '^FAIL ' "$log" 2>/dev/null)
echo "== passkeyquit $engine $mode run $run: exit $rc; PASS ${pass:-0} FAIL ${fail:-0} FAIL-ENV $(grep -c '^FAIL-ENV ' "$log" 2>/dev/null)"
grep -E '^(FAIL|FAIL-ENV|ENGINE-FAIL|SKIP|SLOW-QUIT) |sheet began|pass arm' "$log" 2>/dev/null | head -40
if [[ ${pass:-0} == 0 ]]; then echo "ZERO-GUARD FAIL: passkeyquit $engine made 0 assertions"; exit 1; fi
[[ ${fail:-0} == 0 ]] || exit 1
exit 0
