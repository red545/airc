#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Crash visibility (docs/user/telemetry.md, "Crash reports"), on the build Mac: crashes a scratch build on purpose and
# checks that the next launch sends exactly one `$exception` for it, to the app's own mock PostHog on loopback (never
# to PostHog).
#
#   scripts/tests/crash-visibility.sh [--engine webkit|chromium] [--kinds "segv segv-ips abort trap segv-thread"]
#                                     [--renderer] [--app APP] OUT
#
# Without --app it builds one: its own identity (org.airc.crashvis, never the owner's), a loopback telemetry host and
# key, test code compiled in (`--test-crash` exists in AIRC_TESTING builds only). It runs a copy whose executable is
# AircCrashvis: macOS saves at most 25 crash reports per process name, and a Mac where Airc crashed that often (the
# build Mac) gets no new Airc .ips at all. Per kind, in OUT/<kind>:
#   1. a launch with --test-crash=<kind> crashes a second after its launch look, leaving CrashRecords/record;
#   2. a launch with --script crashvis checks that the crash is one `$exception` (the crash site found by name, this
#      binary's UUID, no path or user name) and that the mock got exactly one:
#      - segv: from the signal record, through the launch's own look (a fresh record waits a minute for macOS's report);
#      - segv-ips: macOS's report of the crash (an .ips of this scratch bundle in the real DiagnosticReports folder) is
#        copied into the scratch home's first, and the one event is the .ips (the record adds nothing a minute later);
#      - abort, trap, segv-thread: from the signal record, looked at at once;
#   3. segv only: macOS's report of that crash is copied in afterwards, and a third launch must send nothing more.
# --renderer (Chromium): the segv relaunch also ends a tab's renderer (chrome://kill) and expects one process.gone.
# Each launch has a scratch home (CFFIXED_USER_HOME) and data folder in OUT; -g: never takes focus; no device access.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=webkit
KINDS="segv segv-ips abort trap segv-thread"
APP=""
RENDERER=0
while [[ $# -gt 1 ]]; do
  case "$1" in
    --engine) ENGINE=$2; shift 2 ;;
    --kinds) KINDS=$2; shift 2 ;;
    --app) APP=$2; shift 2 ;;
    --renderer) RENDERER=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
OUT=${1:?Usage: crash-visibility.sh [--engine E] [--kinds K] [--app APP] OUT}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
PORT=18574

if [[ -z $APP ]]; then
  echo "== building a scratch $ENGINE build with a loopback telemetry host"
  engine_args=(--engine webkit)
  [[ $ENGINE == chromium ]] && engine_args=()
  AIRC_TELEMETRY_HOST=http://127.0.0.1:$PORT AIRC_TELEMETRY_KEY=phc_mock AIRC_BUNDLE_ID=org.airc.crashvis \
    "$ROOT/scripts/build-app.sh" --no-test ${engine_args[@]+"${engine_args[@]}"} > "$OUT/build.log" 2>&1 \
    || { tail -30 "$OUT/build.log"; exit 1; }
  APP="$ROOT/build/Airc.app"
  [[ $ENGINE == chromium ]] && APP="$ROOT/build/Airc-Chromium.app"
fi
copy="$OUT/AircCrashvis.app"
rm -rf "$copy"
ditto "$APP" "$copy"
mv "$copy/Contents/MacOS/Airc" "$copy/Contents/MacOS/AircCrashvis"
plutil -replace CFBundleExecutable -string AircCrashvis "$copy/Contents/Info.plist"
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$copy" 2>&1 | grep -v "replacing existing signature" || true
APP=$(cd "$copy" && pwd -P)
echo "== app: $APP ($ENGINE)"

FAILED=0
launch() {   # launch DIR ENV... -- ARGS...
  local d=$1; shift
  local env=(--env "CFFIXED_USER_HOME=$d/home")
  while [[ $1 != -- ]]; do env+=(--env "$1"); shift; done
  shift
  open -g -n -W "${env[@]}" "$APP" --args --engine="$ENGINE" --data-dir "$d/data" "$@" || true
}
signal_of() { case $1 in segv*) echo SIGSEGV ;; abort) echo SIGABRT ;; trap) echo SIGTRAP ;; esac; }
find_ips() {   # find_ips DIR: macOS's report of this kind's crash, waiting up to a minute
  local found=""
  for _ in $(seq 1 30); do
    # Only AircCrashvis*.ips files written since this kind started, and only the one of the crashed process (macOS
    # redacts paths under the home folder, so the record's process ID tells it).
    found=$(python3 - "$HOME/Library/Logs/DiagnosticReports" "$1/started" "$(sed -n 's/^pid //p' "$1/record.txt")" <<'EOF'
import glob, json, os, sys
folder, started, pid = sys.argv[1], os.path.getmtime(sys.argv[2]), int(sys.argv[3])
for path in sorted(glob.glob(os.path.join(folder, 'AircCrashvis*.ips'))):
    if os.path.getmtime(path) < started:
        continue
    try:
        body = json.loads(open(path, 'rb').read().split(b'\n', 1)[1])
    except Exception:
        continue
    if body.get('pid') == pid and body.get('procName') == 'AircCrashvis':
        print(path)
        break
EOF
)
    [[ -n $found ]] && break
    sleep 2
  done
  echo "$found"
}
put_ips() {   # put_ips DIR FILE: into the scratch home's DiagnosticReports, as macOS would have
  mkdir -p "$1/home/Library/Logs/DiagnosticReports"
  cp -p "$2" "$1/home/Library/Logs/DiagnosticReports/"
  cp -p "$2" "$1/macos-report.ips"
  echo "  [$kind] macOS wrote $(basename "$2")"
}
report() {   # report DIR NAME
  if grep -qx "\[crashvis\]" "$1/$2/log.txt" 2>/dev/null; then
    grep -E "^(PASS|FAIL|crashvis:)" "$1/$2/log.txt" | sed "s/^/  [$kind] /"
    grep -q "^FAIL" "$1/$2/log.txt" && FAILED=1 || true
  else
    echo "  [$kind] FAIL $2: no log (the app crashed or never started)"; FAILED=1
  fi
}

for kind in $KINDS; do
  d="$OUT/$kind"
  rm -rf "$d"; mkdir -p "$d/home/Library" "$d/check" "$d/dedupe"
  touch "$d/started"
  echo "== $kind: 1. the crash"
  launch "$d" -- --automated --skip-onboarding --test-crash="$kind"
  if [[ -s "$d/data/CrashRecords/record" ]]; then
    echo "  [$kind] the crashed run left a $(wc -c < "$d/data/CrashRecords/record" | tr -d ' ')-byte record"
  else
    echo "  [$kind] FAIL no signal record after the crash"; FAILED=1; continue
  fi
  cp "$d/data/CrashRecords/record" "$d/record.txt"
  extra=(AIRC_CRASHVIS_NOW=1)
  case $kind in
    segv) extra=(AIRC_CRASHVIS_NOW=0 "AIRC_CRASHVIS_RENDERER=$RENDERER") ;;
    segv-ips)
      ips=$(find_ips "$d")
      if [[ -z $ips ]]; then
        echo "  [$kind] FAIL macOS wrote no .ips for the crash within a minute"; FAILED=1; continue
      fi
      put_ips "$d" "$ips"
      extra=(AIRC_CRASHVIS_NOW=0 AIRC_CRASHVIS_SOURCE=ips) ;;
  esac
  echo "== $kind: 2. the relaunch"
  launch "$d" "AIRC_CRASHVIS_SIGNAL=$(signal_of "$kind")" "${extra[@]}" -- --snapshot "$d/check" --script crashvis
  report "$d" check
  [[ $kind == segv ]] || continue
  echo "== $kind: 3. macOS's .ips of the same crash, after the record was sent"
  ips=$(find_ips "$d")
  if [[ -z $ips ]]; then
    # Chromium's browser process is often too big for ReportCrash (the owner's crashes): segv-ips covers dedupe.
    echo "  [$kind] SKIP macOS wrote no .ips for the crash within a minute"; continue
  fi
  put_ips "$d" "$ips"
  launch "$d" "AIRC_CRASHVIS_SIGNAL=$(signal_of "$kind")" AIRC_CRASHVIS_EXPECT=none -- --snapshot "$d/dedupe" --script crashvis
  report "$d" dedupe
done
[[ $FAILED == 0 ]] && echo "crash visibility: PASS" || { echo "crash visibility: FAIL"; exit 1; }
