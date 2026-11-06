#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Builds the fresh public repository: the committed tree at HEAD, minus exclude.txt, as exactly
# one root commit in a new git repository. No history, no remotes, no push. Then runs scan.sh
# and fails if the scan does.
#
#   AIRC_PUBLIC_AUTHOR='Name <email>' infra/launch/fresh-repo.sh <out-dir>
#
# Env:
#   AIRC_PUBLIC_AUTHOR   required: author and committer of the root commit, "Name <email>".
#   AIRC_PUBLIC_DATE     optional: author and committer date (any git date format, e.g.
#                        2026-11-20T18:00:00Z); default now. Always recorded in UTC.
#   AIRC_PUBLIC_MESSAGE  optional: commit message (default "Airc: first public release").
#   AIRC_PUBLIC_BRANCH   optional: branch name (default main).
#   plus scan.sh's AIRC_PRIVATE_PATTERNS, AIRC_SCAN_ALLOWLIST, AIRC_PUBLIC_EMAILS, AIRC_TOOLS_DIR.
#
# The same HEAD, author, date and message always give the same commit hash.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
die() { echo "fresh-repo: $*" >&2; exit 2; }

[[ $# == 1 ]] || die "usage: AIRC_PUBLIC_AUTHOR='Name <email>' fresh-repo.sh <out-dir>"
out=$1

# --- identity and date ------------------------------------------------------------------------
author=${AIRC_PUBLIC_AUTHOR:-}
[[ -n "${author// /}" ]] || die "AIRC_PUBLIC_AUTHOR is required (\"Name <email>\"); there is no default."
re='^([^<>]*[^<> ])[ ]+<([^<>@ ]+@[^<> ]+\.[^<> ]+)>$'
[[ "$author" =~ $re ]] || die "AIRC_PUBLIC_AUTHOR must look like \"Name <user@domain>\"."
name=${BASH_REMATCH[1]} email=${BASH_REMATCH[2]}
date=${AIRC_PUBLIC_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
message=${AIRC_PUBLIC_MESSAGE:-Airc: first public release}
branch=${AIRC_PUBLIC_BRANCH:-main}

# --- out-dir: new, empty, outside the repository ----------------------------------------------
abs() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
out=$(abs "$out")
root_real=$(abs "$ROOT")
case "$out/" in "$root_real"/*) die "refusing an out-dir inside the repository" ;; esac
case "$root_real/" in "$out"/*) die "refusing an out-dir that contains the repository" ;; esac
[[ "$out" != / && "$out" != "$(abs "$HOME")" ]] || die "refusing out-dir $out"
if [[ -e "$out" ]]; then
  [[ -d "$out" && -z "$(ls -A "$out")" ]] || die "out-dir exists and is not empty"
fi

# --- what goes in -----------------------------------------------------------------------------
src=$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}')
excludes=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  path=${line%%#*}; path=${path%"${path##*[![:space:]]}"}
  reason=${line#*#}
  [[ "$line" == *"#"* && -n "${reason// /}" && -n "$path" ]] || die "exclude.txt: every entry needs '<path>  # <reason>'"
  excludes+=("$path")
done <"$HERE/exclude.txt"

# A throwaway index of HEAD, because ls-tree has no glob or exclude pathspecs.
work=$(mktemp -d "${TMPDIR:-/tmp}/airc-fresh.XXXXXX")
trap 'rm -rf "$work"' EXIT
GIT_INDEX_FILE=$work/index git -C "$ROOT" read-tree "$src"
head_files() { GIT_INDEX_FILE=$work/index git -C "$ROOT" ls-files "$@"; }

pathspec=(.)
for path in "${excludes[@]}"; do
  if [[ -z "$(head_files -- ":(glob)$path")" ]]; then
    echo "warning: exclude.txt entry '$path' matches nothing at HEAD" >&2
  fi
  pathspec+=(":(exclude,glob)$path")
done

dirty=$(git -C "$ROOT" status --porcelain --untracked-files=normal | wc -l | tr -d ' ')
[[ $dirty == 0 ]] || echo "note: $dirty uncommitted or untracked path(s) in the working tree are NOT exported (HEAD only)." >&2

# --- export and commit ------------------------------------------------------------------------
mkdir -p "$out"
git -C "$ROOT" archive --format=tar "$src" -- "${pathspec[@]}" | tar -x -C "$out"

# An isolated git: no global or system config (hooks, signing keys, templates, identities),
# no template directory, UTC dates.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
export GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email
export GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date
g() { git -C "$out" "$@"; }
git init -q --template= -b "$branch" "$out"
g config core.hooksPath /dev/null
g add -A -f .
g commit -q --no-verify --no-gpg-sign -m "$message"

# --- verify -----------------------------------------------------------------------------------
fail() { echo "fresh-repo: verification failed: $*" >&2; exit 1; }
[[ "$(g rev-list --count HEAD)" == 1 ]] || fail "not exactly one commit"
[[ "$(g rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" == 1 ]] || fail "root commit has parents"
[[ -z "$(g remote)" ]] || fail "remotes present"
[[ "$(g for-each-ref --format='%(refname)')" == "refs/heads/$branch" ]] || fail "unexpected refs"
# Same blobs, modes and paths as HEAD minus the excludes: proves nothing came from the working tree.
diff <(head_files -s -- "${pathspec[@]}") <(g ls-files -s) >/dev/null \
  || fail "exported tree differs from HEAD minus exclude.txt"
for path in "${excludes[@]}"; do
  [[ -z "$(g ls-files -- ":(glob)$path")" ]] || fail "excluded path present: $path"
done
[[ "$(g log -1 --format='%an <%ae>|%cn <%ce>')" == "$name <$email>|$name <$email>" ]] || fail "identity"

# Kept files that still mention an excluded file (dangling references in the public tree).
for path in "${excludes[@]}"; do
  [[ "$path" == *[\*\?\[]* ]] && continue
  refs=$(g grep -l -F -- "$(basename "$path")" HEAD 2>/dev/null | sed 's/^HEAD://' | tr '\n' ' ' || true)
  [[ -z "$refs" ]] || echo "note: $(basename "$path") is excluded but mentioned in: $refs" >&2
done

echo "Fresh repository: $out"
echo "  source HEAD:  $src"
echo "  root commit:  $(g rev-parse HEAD)  tree $(g rev-parse 'HEAD^{tree}')"
echo "  files:        $(g ls-files | wc -l | tr -d ' ') (excluded ${#excludes[@]} entr$( [[ ${#excludes[@]} == 1 ]] && echo y || echo ies))"
echo "  date:         $(g log -1 --format=%aI)"
echo "  remotes:      none; nothing pushed"
echo

# --- scan: the tree, then the commit metadata ---------------------------------------------------
meta=$work/meta
mkdir "$meta"
g log -1 --format='%an%n%ae%n%cn%n%ce%n%B' >"$meta/COMMIT-METADATA"
g config --list --local >"$meta/GIT-CONFIG"
status=0
"$HERE/scan.sh" "$out" || status=1
echo "Commit metadata:"
# The metadata has no site.ts beside it: pass the tree's public mailboxes (an approved author address is one).
site_emails=$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$out/apps/marketing/src/lib/site.ts" 2>/dev/null | tr '\n' ' ')
AIRC_PUBLIC_EMAILS="${AIRC_PUBLIC_EMAILS:-} $site_emails" \
AIRC_SCAN_ALLOWLIST=${AIRC_SCAN_ALLOWLIST:-$HERE/scan-allowlist.txt} "$HERE/scan.sh" "$meta" 2>/dev/null | sed 's/^/  /' || status=1
if [[ $status != 0 ]]; then
  echo "fresh-repo: SCAN FAILED. Do not publish $out." >&2
  exit 1
fi
echo "fresh-repo: OK. Review, then follow docs/launch/public-repo.md to publish."
