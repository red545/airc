#!/bin/zsh
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Time Profiler trace of one timed action of `--script frames` (FrameScenario.swift), on the build Mac:
#   infra/perf/trace.sh OUT [webkit|chromium] [cbnew|cbkey|cburl|newspace|switch|sidebar] [runs]
# Launches the built app in the background (open -g, isolated data), attaches xctrace, waits for the scenario to quit,
# then summarises the main thread's samples inside the action's signposted frames (tpsum.py). Display asleep: the
# frames end at the Core Animation commit.
set -u
ROOT=${0:A:h:h:h}
OUT=${1:?out}; e=${2:-chromium}; ONLY=${3:-cbnew}; RUNS=${4:-60}
app=$ROOT/build/Airc.app; [[ $e == chromium ]] && app=$ROOT/build/Airc-Chromium.app
home=$OUT/home
rm -rf "$OUT"; mkdir -p "$home/Library"
open -g -n --env CFFIXED_USER_HOME=$home --env AIRC_FRAMES_RUNS=$RUNS --env AIRC_FRAMES_ONLY=$ONLY "$app" \
  --args --engine=$e --snapshot "$OUT/snap" --script frames --ephemeral --data-dir "$home/Airc"
pid=""
for i in {1..50}; do pid=$(pgrep -nf "$app/Contents/MacOS/Airc"); [[ -n $pid ]] && break; sleep 0.1; done
[[ -n $pid ]] || { echo "no app process" >&2; exit 1; }
xcrun xctrace record --quiet --template 'Time Profiler' --output "$OUT/t.trace" --attach $pid --time-limit 200s >/dev/null 2>&1 &
XT=$!
while kill -0 $pid 2>/dev/null; do sleep 0.5; done
sleep 1; kill -INT $XT 2>/dev/null; wait $XT 2>/dev/null
grep "^\[snapshot\] frames:\|^frames:" "$OUT/snap/log.txt" | cut -c1-400
xcrun xctrace export --input "$OUT/t.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$OUT/tp.xml" 2>/dev/null
xcrun xctrace export --input "$OUT/t.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > "$OUT/si.xml" 2>/dev/null
python3 "$ROOT/infra/perf/tpsum.py" "$OUT/tp.xml" --name frame --intervals "$OUT/si.xml"
