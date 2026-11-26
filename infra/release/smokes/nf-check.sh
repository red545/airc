#!/bin/bash
# One release smoke launch on the build Mac, from a work folder with a test build (build/Airc.app,
# build/Airc-Chromium.app). Ported from release074's nf-check.sh (devtools' mac-check.sh + idlecpu's one.sh).
#   infra/release/smokes/nf-check.sh <engine> <script> <mode> <limit> <out-name>
# mode: bg (open -g) | real (front, dedicated session, UI driver clicks + keys) | front (no driver input, occlusion
# kept) | perf (front, no driver input) | fg (front, no driver input) | fp (front + driver keys) | tfg (open -g,
# dedicated, driver keys) | pfg (open -g, dedicated, driver keys + clicks) | gate (engine test gate) | dgate (gate +
# modalDialogs). NF_ENV="K=V …" adds --env pairs. One launch under the strict UI lock (exit 75 = refused: retry later);
# our app is stopped by its exact executable path after <limit> s, with a sample in hang.txt.
set -u
exec < /dev/null
cd "$(dirname "$0")/../../.." || exit 1
root=$PWD
engine=$1; script=$2; mode=$3; limit=${4:-330}; name=$5
app="$root/build/Airc.app"; [[ $engine == chromium ]] && app="$root/build/Airc-Chromium.app"
exe="$app/Contents/MacOS/Airc"
out="$root/build/runs/smoke/$name"; home="$root/build/runs/smoke-home/$name"
rm -rf "$out" "$home"; mkdir -p "$out" "$home/Library" "$home/data/Chromium"
OPEN="open -g -n -W"; FGENV=""; ARGS="--ephemeral --data-dir $home/data"
case $mode in
  real) OPEN="open -n -W"; FGENV="--env AIRC_REAL_CLICKS=1 --env AIRC_REAL_KEYS=1 --env AIRC_LA_AS_OWNER=1";;
  front) OPEN="open -n -W"; FGENV="--env AIRC_LA_AS_OWNER=1 --env AIRC_KEEP_OCCLUSION=1";;
  fp) OPEN="open -n -W"; FGENV="--env AIRC_LA_AS_OWNER=1 --env AIRC_REAL_KEYS=1";;
  perf|fg) OPEN="open -n -W"; FGENV="--env AIRC_LA_AS_OWNER=1";;
  tfg) FGENV="--env AIRC_LA_AS_OWNER=1 --env AIRC_REAL_KEYS=1";;
  pfg) FGENV="--env AIRC_LA_AS_OWNER=1 --env AIRC_REAL_KEYS=1 --env AIRC_REAL_CLICKS=1";;
  gate) ARGS="--data-dir $home/data --airc-data-dir=$home/data"
        [[ $engine == chromium ]] && ARGS="$ARGS --deny-permission-prompts --airc-test=unpackedExtension";;
  dgate) ARGS="--data-dir $home/data --airc-data-dir=$home/data --airc-test=modalDialogs";;
  bg) ;;
  *) echo "nf-check: unknown mode $mode"; exit 2;;
esac
for kv in ${NF_ENV:-}; do FGENV="$FGENV --env $kv"; done
# As fpbridge and ganalytics ran them: Chromium gets --deny-permission-prompts for the media/network checks.
case $script in fairplaybridge|fairplayvideo|fairplayua|spotifyprobe|ganalytics)
  [[ $engine == chromium ]] && ARGS="$ARGS --deny-permission-prompts";; esac
# ganalytics' fixture hosts: Chromium maps them to loopback and drops HTTPS upgrades.
if [[ $engine == chromium && $script == ganalytics ]]; then
  ARGS="$ARGS --host-resolver-rules=MAP\ sentrymagic.com\ 127.0.0.1,\ MAP\ clarity.ms\ 127.0.0.1,\ MAP\ abilityscale.com\ 127.0.0.1,\ MAP\ abjectattempt.com\ 127.0.0.1,\ MAP\ aboutcorgis.com\ 127.0.0.1,\ MAP\ allsportsflix.co.uk\ 127.0.0.1 --disable-features=HttpsUpgrades"
fi
if [[ $engine == chromium && $script == devtools* ]]; then
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  ARGS="$ARGS --remote-debugging-port=$port --remote-allow-origins=*"
fi
echo "load-at-start $(sysctl -n vm.loadavg)" > "$out/runner.txt"
# As release074: every mode in a dedicated session (the lock's preflight), strict lock (refuse on timeout).
AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py bash -c '
  '"$OPEN"' --env "CFFIXED_USER_HOME='"$home"'" --env AIRC_UI_DEDICATED_SESSION=1 '"$FGENV"' --env AIRC_MEDIA_PROMPT_CHECKS=0 --env AIRC_TELEMETRY_ENABLED=0 \
    "'"$app"'" --args --engine='"$engine"' --snapshot "'"$out"'" --script '"$script"' '"$ARGS"' &
  opener=$!
  for i in $(seq 1 '"$limit"'); do kill -0 $opener 2>/dev/null || exit 0; sleep 1; done
  echo "runner: still running after '"$limit"' s, stopping by exact path" >> "'"$out"'/runner.txt"
  for pid in $(ps -axo pid=,comm= | awk -v e="'"$exe"'" "\$2==e {print \$1}"); do sample $pid 2 -file "'"$out"'/hang.txt" >/dev/null 2>&1; kill -TERM $pid; done
  sleep 3
  for pid in $(ps -axo pid=,comm= | awk -v e="'"$exe"'" "\$2==e {print \$1}"); do kill -KILL $pid; done
  kill $opener 2>/dev/null; exit 0'
rc=$?
echo "load-at-end $(sysctl -n vm.loadavg)" >> "$out/runner.txt"
rm -rf "$home"
[[ $rc == 75 ]] && { echo "LOCK-REFUSED"; exit 75; }
echo "== $engine $script $mode rc $rc $(head -1 "$out/runner.txt")"
grep -E "^(FAIL|FAIL-ENV|SKIP|ENGINE-FAIL)" "$out/log.txt" 2>/dev/null | sed 's/^/  /' | cut -c1-500
exit $rc
