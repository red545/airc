#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
before=$1
after=$2
prefix=$3
for n in 1 2 3; do
  python3 engine/perf/measure.py "$before" "${prefix}-before-$n" engine/perf/launch.json --settle=0 --seconds=1 --launch-only
  python3 engine/perf/measure.py "$after" "${prefix}-after-$n" engine/perf/launch.json --settle=0 --seconds=1 --launch-only
  python3 engine/perf/measure.py '/Applications/Google Chrome.app' "${prefix}-chrome-$n" engine/perf/launch.json --chrome --settle=0 --seconds=1 --launch-only
done
# Entire feature-policy rollback on the same binary, fresh profiles.
python3 engine/perf/measure.py "$after" "${prefix}-rollback" engine/perf/launch.json --settle=6 --seconds=1 --launch-only \
  --flag=--airc-switches=quietModels=off,quietHistory=off,quietCommerce=off,quietTranslateDownloads=off,quietTelemetry=off,quietVariations=off,quietSync=off

for group in quietModels quietHistory quietCommerce quietTranslateDownloads quietTelemetry quietVariations quietSync; do
  python3 engine/perf/measure.py "$after" "${prefix}-rollback-$group" engine/perf/launch.json --settle=6 --seconds=1 --launch-only \
    --flag="--airc-switches=$group=off"
done
