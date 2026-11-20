#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# The one definition of "the engine inputs": what the buildmac framework (status/buildmac-engine-ready) is built from.
# Sourced by infra/nightly.sh, infra/reconcile-engine.sh and tools/social/mac-frames.sh. Docs (engine/*.md) and test
# hosts (engine/host/**) are not inputs, and neither is where a commit sits in history: a marker commit on a release
# branch is as good as main's if the inputs are byte-identical.

ENGINE_INPUT_PATHS=(engine/core engine/patches engine/args ':(glob)engine/*.gn' ':(glob)engine/*.gni' ':(glob)engine/BUILD*' CHROMIUM_VERSION)

# engine_inputs_diff <repo> <marker-commit> <rev>
# Prints the paths whose engine inputs differ between the two commits, one per line. Returns 0 when there are none
# (inputs identical), 1 when some differ, 2 when a commit isn't in the repo (then it prints why).
engine_inputs_diff() {
  local repo=$1 marker=$2 rev=$3 out
  [[ $marker =~ ^[0-9a-f]{7,40}$ ]] || { echo "engine marker is not a commit id: '$marker'"; return 2; }
  git -C "$repo" rev-parse --verify --quiet "$marker^{commit}" >/dev/null || { echo "engine marker commit $marker is not in this repo"; return 2; }
  git -C "$repo" rev-parse --verify --quiet "$rev^{commit}" >/dev/null || { echo "revision $rev is not in this repo"; return 2; }
  out=$(git -C "$repo" diff --name-only "$marker" "$rev" -- "${ENGINE_INPUT_PATHS[@]}") || return 2
  [[ -z $out ]] && return 0
  printf '%s\n' "$out"
  return 1
}
