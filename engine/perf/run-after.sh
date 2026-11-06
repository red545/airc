#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run from the repo on the build Mac, after the sole engine build has completed.
# Fresh output directories only. No benchmark/build overlap.
set -euo pipefail
app=$1
prefix=$2
python3 engine/perf/check-counters.py
python3 engine/perf/measure.py "$app" "${prefix}-eight" infra/perf/workload.json
python3 engine/perf/measure.py "$app" "${prefix}-two" engine/perf/two-profile.json
python3 engine/perf/measure.py "$app" "${prefix}-no-spare" infra/perf/workload.json --flag=--disable-features=SpareRendererForSitePerProcess
python3 engine/perf/measure.py "$app" "${prefix}-limit" infra/perf/workload.json --flag=--renderer-process-limit=8
python3 engine/perf/measure.py "$app" "${prefix}-all" infra/perf/workload.json --all
