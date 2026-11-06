#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run after measurements; never overlap regression and performance workloads.
set -euo pipefail
app=$1
prefix=$2
mkdir -p "$prefix"
for scenario in isolation forms autofill memory extension; do
  if [[ $scenario == isolation ]]; then
    node engine/host/acceptance.mjs "$app" "$prefix/$scenario" > "$prefix/$scenario.log" 2>&1
  else
    node engine/host/acceptance.mjs "$app" "$prefix/$scenario" "$scenario" > "$prefix/$scenario.log" 2>&1
  fi
  grep '^PASS' "$prefix/$scenario.log"
done
python3 engine/tests/audit_forms.py "$prefix/autofill"
engine/tests/adapter.sh "$app" "$prefix/adapter" > "$prefix/adapter.log" 2>&1
tail -3 "$prefix/adapter.log"
