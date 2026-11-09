#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Publishes the private repository's reviewed main (origin/main) to the public repository as ONE new commit
# whose tree is that revision minus exclude.txt, after the same privacy scan as fresh-repo.sh. The public
# history is its own: no private commit, branch or tag ever reaches it (docs/launch/public-repo.md).
#
#   AIRC_PUBLIC_AUTHOR='Airc <hello@aircbrowser.com>' infra/launch/sync-public.sh [--dry-run]
#
# Env: AIRC_PUBLIC_DIR (the public clone; default ../public-airc beside the checkout), AIRC_PUBLIC_REMOTE (required:
# the public repository's URL, checked against the clone's origin), AIRC_STATUS_DIR (default ../status, holds the
# last published private revision in public-sync.rev). Cron runs it hourly; it does nothing when main hasn't moved.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
PUB=${AIRC_PUBLIC_DIR:-$(dirname "$ROOT")/public-airc}
REMOTE=${AIRC_PUBLIC_REMOTE:?Set AIRC_PUBLIC_REMOTE to the public repository URL (the clone origin must match)}
STATUS=${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}
die() { echo "sync-public: $*" >&2; exit 2; }
dry=0; [[ ${1:-} == --dry-run ]] && dry=1

author=${AIRC_PUBLIC_AUTHOR:-}
re='^([^<>]*[^<> ])[ ]+<([^<>@ ]+@[^<> ]+\.[^<> ]+)>$'
[[ "$author" =~ $re ]] || die "AIRC_PUBLIC_AUTHOR must look like \"Name <user@domain>\"."
name=${BASH_REMATCH[1]} email=${BASH_REMATCH[2]}

exec 9>"$STATUS/.public-sync.lock"
flock -n 9 || { echo "sync-public: another sync is running"; exit 0; }

# --- what to publish: the reviewed main, never the working tree or unpushed commits -------------
git -C "$ROOT" fetch -q origin main
src=$(git -C "$ROOT" rev-parse --verify 'origin/main^{commit}')
last=$(cat "$STATUS/public-sync.rev" 2>/dev/null || true)
[[ "$src" != "$last" ]] || { echo "sync-public: up to date at ${src:0:7}"; exit 0; }

# --- the public clone: its own history only -----------------------------------------------------
[[ -d "$PUB/.git" ]] || die "no public clone at $PUB"
[[ "$(git -C "$PUB" remote get-url origin)" == "$REMOTE" ]] || die "the public clone's origin isn't $REMOTE"
[[ "$(git -C "$ROOT" remote get-url origin)" != "$REMOTE" ]] || die "the private checkout points at the public repository"
git -C "$PUB" fetch -q origin main
parent=$(git -C "$PUB" rev-parse --verify 'origin/main^{commit}')
git -C "$PUB" cat-file -e "$src^{commit}" 2>/dev/null && die "a private commit is in the public clone"
[[ -n "$last" ]] && git -C "$PUB" cat-file -e "$last^{commit}" 2>/dev/null && die "a private commit is in the public clone"

excludes=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  path=${line%%#*}; path=${path%"${path##*[![:space:]]}"}
  excludes+=("$path")
done <"$HERE/exclude.txt"
pathspec=(.)
for path in "${excludes[@]}"; do pathspec+=(":(exclude,glob)$path"); done

work=$(mktemp -d "${TMPDIR:-/tmp}/airc-sync.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/tree" "$work/meta"
git -C "$ROOT" archive --format=tar "$src" -- "${pathspec[@]}" | tar -x -C "$work/tree"

# --- the new commit: the exported tree on top of the public main --------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
export GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email
pub() { GIT_INDEX_FILE=$work/index GIT_WORK_TREE=$work/tree git --git-dir="$PUB/.git" "$@"; }
cd "$work/tree"
pub read-tree --empty
pub add -A -f .
tree=$(pub write-tree)
if [[ "$tree" == "$(git -C "$PUB" rev-parse "$parent^{tree}")" ]]; then
  echo "sync-public: no file changes since the last public commit"
  [[ $dry == 1 ]] || echo "$src" >"$STATUS/public-sync.rev"
  exit 0
fi
# Same blobs, modes and paths as the private revision minus the excludes.
GIT_INDEX_FILE=$work/src-index git -C "$ROOT" read-tree "$src"
diff <(GIT_INDEX_FILE=$work/src-index git -C "$ROOT" ls-files -s -- "${pathspec[@]}") <(pub ls-files -s) >/dev/null \
  || die "exported tree differs from origin/main minus exclude.txt"

{
  echo "Sync with development ($(date -u +%Y-%m-%d\ %H:%M) UTC)"
  echo
  if [[ -n "$last" ]] && git -C "$ROOT" cat-file -e "$last^{commit}" 2>/dev/null; then
    git -C "$ROOT" log --reverse --no-merges --format='- %s' "$last..$src" -- "${pathspec[@]}" | awk 'NR <= 60'
  fi
} >"$work/message"
commit=$(git --git-dir="$PUB/.git" commit-tree "$tree" -p "$parent" -F "$work/message")

# --- the gate: the tree and the commit metadata ---------------------------------------------------
git --git-dir="$PUB/.git" log -1 --format='%an%n%ae%n%cn%n%ce%n%B' "$commit" >"$work/meta/COMMIT-METADATA"
site_emails=$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$work/tree/apps/marketing/src/lib/site.ts" 2>/dev/null | tr '\n' ' ')
status=0
"$HERE/scan.sh" "$work/tree" || status=1
AIRC_PUBLIC_EMAILS="${AIRC_PUBLIC_EMAILS:-} $site_emails" "$HERE/scan.sh" "$work/meta" 2>/dev/null | sed 's/^/  /' || status=1
[[ $status == 0 ]] || die "SCAN FAILED for ${src:0:7}: nothing published. Fix it in the private repo and push."

echo "sync-public: ${src:0:7} → public commit ${commit:0:7} on ${parent:0:7}"
if [[ $dry == 1 ]]; then echo "sync-public: dry run, not pushed"; exit 0; fi
# The push uses the machine's credentials again (the isolated config above has no credential helper).
env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM git -C "$PUB" push -q origin "$commit:refs/heads/main"
env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM git -C "$PUB" fetch -q origin main
git -C "$PUB" reset -q --hard origin/main
echo "$src" >"$STATUS/public-sync.rev"
echo "sync-public: pushed"
