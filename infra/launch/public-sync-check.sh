#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Release checklist step: is the public repository synced to (at least) a release cut?
#
#   infra/launch/public-sync-check.sh [<commit>]     (default: origin/main)
#
# Reads $AIRC_STATUS_DIR/public-sync.state (written by sync-public.sh) and checks that
#   1. the last sync was OK,
#   2. the last published private revision contains <commit>, and
#   3. the public repository's main on GitHub is the public commit that sync recorded.
# Prints one line per check and exits 0 only when all pass. It never syncs or pushes; when it fails, run
# sync-public.sh as cron does (docs/launch/public-repo.md), or fix the scan finding it reports.
#
# Env: AIRC_STATUS_DIR (default ../status beside the checkout), AIRC_PUBLIC_REMOTE (default: the public
# clone's origin, ../public-airc).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
# Beside the main checkout, also when this runs from a linked worktree.
BASE=$(dirname "$(dirname "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)")")
STATUS=${AIRC_STATUS_DIR:-$BASE/status}
state=$STATUS/public-sync.state
want=${1:-origin/main}
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
get() { sed -n "s/^$1=//p" "$state"; }

[[ -f "$state" ]] || { echo "FAIL no $state: sync-public.sh has not run since it learned to write it"; exit 1; }
status=$(get status) checked=$(get checked) published=$(get published) public=$(get public) detail=$(get detail)
[[ $status == OK ]] && ok "last sync OK at $checked ($detail)" || bad "last sync $status at $checked: $detail"

cut=$(git -C "$ROOT" rev-parse --verify "$want^{commit}")
if [[ -n $published ]] && git -C "$ROOT" merge-base --is-ancestor "$cut" "$published" 2>/dev/null; then
  ok "published ${published:0:8} contains the cut ${cut:0:8}"
else
  bad "published ${published:0:8} does not contain the cut ${cut:0:8}: run sync-public.sh after the cut is on origin/main"
fi

remote=${AIRC_PUBLIC_REMOTE:-$(git -C "$BASE/public-airc" remote get-url origin 2>/dev/null || true)}
if [[ -z $remote ]]; then
  bad "no public remote (set AIRC_PUBLIC_REMOTE)"
else
  live=$(git ls-remote "$remote" refs/heads/main | cut -f1)
  [[ -n $live && $live == "$public" ]] && ok "public main is ${live:0:8}, as recorded" \
    || bad "public main is ${live:0:8}, the state says ${public:0:8}"
fi
[[ $fails == 0 ]] && echo "public-sync-check: PASS" || { echo "public-sync-check: FAIL ($fails)"; exit 1; }
