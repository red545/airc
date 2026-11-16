#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Publishes the private repository's reviewed main (origin/main) to the public repository as ONE new commit
# whose tree is that revision minus exclude.txt, after the same privacy scan as fresh-repo.sh. The public
# history is its own: no private commit, branch or tag ever reaches it (docs/launch/public-repo.md).
#
#   AIRC_PUBLIC_AUTHOR='Airc <hello@aircbrowser.com>' infra/launch/sync-public.sh [--dry-run]
#   infra/launch/sync-public.sh [--dry-run] --release <version> [<private revision>]
#
# --release publishes one release's source instead of main: a snapshot commit of the release's build revision
# (default: the "Source:" line of apps/marketing/src/content/changelog/<version>.md on origin/main, which it must
# match) minus exclude.txt, on a side line whose parent is the current public main (main itself never moves),
# or main's own commit when main's tree is that tree. It gets the annotated tag v<version> (build number, date,
# source revision, excluded paths) and a GitHub Release with the changelog's notes. Same scan, run on the tree,
# the commit, the tag and the notes. The gate is origin/main's (current rules on an older tree). Re-running it is
# safe: an existing tag must point at the same tree (never moved or forced); a missing Release is created.
# AIRC_PUBLIC_REMOTE and AIRC_PUBLIC_AUTHOR default to the public clone's origin and public main's author.
# infra/launch/public-release-check.sh <version> verifies the result. docs/release.md, "Public release tag".
#
# The gate (this script, scan.sh, scan.py, the allowlists and exclude.txt) always runs as committed in the
# revision being published: the copy cron starts only fetches, then re-runs infra/launch from origin/main.
# So a fix to the scan rules lands with a normal push, whatever the checkout cron points at.
#
# Every real run writes $AIRC_STATUS_DIR/public-sync.state (key=value lines: status OK|FAIL, checked, src,
# published, public, detail) for the lead's tick and the release checklist. When a run fails and the
# failure is new (or its detail changed), it also appends an alert to $AIRC_SYNC_ALERT_FILE if set.
#
# Env: AIRC_PUBLIC_DIR (the public clone; default public-airc beside the main checkout), AIRC_PUBLIC_REMOTE (required:
# the public repository's URL, checked against the clone's origin), AIRC_STATUS_DIR (default ../status, holds the
# last published private revision in public-sync.rev), AIRC_SYNC_ALERT_FILE (optional), AIRC_SYNC_GATE=local
# (test this checkout's gate instead of origin/main's; with --dry-run only). Cron runs it hourly; it does
# nothing when main hasn't moved.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${AIRC_PRIVATE_ROOT:-$(git -C "$HERE" rev-parse --show-toplevel)}
# The folder beside the MAIN checkout, also when this runs from a linked worktree (cron's runner).
BASE=$(dirname "$(dirname "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)")")
PUB=${AIRC_PUBLIC_DIR:-$BASE/public-airc}
REMOTE=${AIRC_PUBLIC_REMOTE:-}
STATUS=${AIRC_STATUS_DIR:-$BASE/status}
# scan.sh finds these beside the repository; the re-run gate lives in a temporary folder instead.
export AIRC_PRIVATE_PATTERNS=${AIRC_PRIVATE_PATTERNS:-$BASE/private-patterns.txt}
export AIRC_TOOLS_DIR=${AIRC_TOOLS_DIR:-$BASE/tools}
dry=0 release=; args=("$@")
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry=1; shift ;;
    --release) release=${2:?--release needs a version}; shift 2
      [[ ${1:-} =~ ^[0-9a-f]{7,40}$ ]] && { AIRC_SYNC_SRC=${AIRC_SYNC_SRC:-$1}; shift; } ;;
    *) echo "Usage: sync-public.sh [--dry-run] [--release <version> [<private revision>]]" >&2; exit 2 ;;
  esac
done
if [[ -n $release ]]; then
  [[ $release =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "sync-public: bad version $release" >&2; exit 2; }
  REMOTE=${AIRC_PUBLIC_REMOTE:-$(git -C "$PUB" remote get-url origin 2>/dev/null || true)}
  [[ -n $REMOTE ]] || { echo "sync-public: no public clone at $PUB" >&2; exit 2; }
  export AIRC_PUBLIC_REMOTE=$REMOTE
  [[ -n ${AIRC_PUBLIC_AUTHOR:-} ]] || export AIRC_PUBLIC_AUTHOR="$(git -C "$PUB" log -1 --format='%an <%ae>' origin/main)"
fi
src=${AIRC_SYNC_SRC:-}
state_file=$STATUS/public-sync.state
[[ -n $REMOTE ]] || { echo "sync-public: Set AIRC_PUBLIC_REMOTE to the public repository URL (the clone origin must match)" >&2; exit 2; }

# key=value state for the lead's hourly tick and the release checklist. Dry runs never write it.
write_state() { # status detail [public commit]
  [[ $dry == 0 && -z $release ]] || { state_written=1; return 0; }
  local published public prev_status prev_detail
  published=$(cat "$STATUS/public-sync.rev" 2>/dev/null || true)
  public=${3:-$(git -C "$PUB" rev-parse -q --verify 'origin/main^{commit}' 2>/dev/null || true)}
  prev_status=$(sed -n 's/^status=//p' "$state_file" 2>/dev/null || true)
  prev_detail=$(sed -n 's/^detail=//p' "$state_file" 2>/dev/null || true)
  {
    echo "status=$1"
    echo "checked=$(date -u +%Y-%m-%dT%H:%MZ)"
    echo "src=$src"
    echo "published=$published"
    echo "public=$public"
    echo "detail=$2"
  } >"$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
  if [[ $1 == FAIL && -n ${AIRC_SYNC_ALERT_FILE:-} && ( $prev_status != FAIL || $prev_detail != "$2" ) ]]; then
    printf '\n## public-sync %s: FAIL, public repo NOT synced\n- %s (origin/main %s; last published %s). Fix it in the private repo (docs/launch/public-repo.md) and push; state: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%MZ)" "$2" "${src:0:8}" "${published:0:8}" "$state_file" >>"$AIRC_SYNC_ALERT_FILE"
  fi
  state_written=1
}
state_written=0
die() { echo "sync-public: $*" >&2; write_state FAIL "$*"; exit 2; }
# Any other failure (network, git) is a FAIL too.
cleanup=()
trap 'rc=$?; rm -rf "${cleanup[@]}"; [[ $rc == 0 || $state_written == 1 ]] || write_state FAIL "sync-public exited $rc (see public-sync.log)"' EXIT

author=${AIRC_PUBLIC_AUTHOR:-}
re='^([^<>]*[^<> ])[ ]+<([^<>@ ]+@[^<> ]+\.[^<> ]+)>$'
[[ "$author" =~ $re ]] || die "AIRC_PUBLIC_AUTHOR must look like \"Name <user@domain>\"."
name=${BASH_REMATCH[1]} email=${BASH_REMATCH[2]}

if [[ -z ${AIRC_SYNC_LOCKED:-} ]]; then
  exec 9>"$STATUS/.public-sync.lock"
  if [[ -n $release ]]; then  # a release waits for the hourly sync (about 5 minutes) instead of skipping
    flock -w 1200 9 || { echo "sync-public: the sync lock stayed busy for 20 minutes" >&2; exit 2; }
  else
    flock -n 9 || { echo "sync-public: another sync is running"; state_written=1; exit 0; }
  fi
fi

# --- what to publish: the reviewed main, never the working tree or unpushed commits -------------
[[ -n ${AIRC_SYNC_GATE:-} ]] || git -C "$ROOT" fetch -q origin main
gate_rev=$(git -C "$ROOT" rev-parse --verify 'origin/main^{commit}')
if [[ -n $release ]]; then
  # The published record of the release: its changelog entry on reviewed main names the build and its source.
  notes_md=$(git -C "$ROOT" show "$gate_rev:apps/marketing/src/content/changelog/$release.md" 2>/dev/null) \
    || die "no changelog entry apps/marketing/src/content/changelog/$release.md on origin/main"
  record=$(grep -E '^Source: `[0-9a-f]{40}`\. Build: `[0-9]{12}`' <<<"$notes_md" | tail -1)
  [[ -n $record ]] || die "the $release changelog has no 'Source: ... Build: ...' line (record the release build identity first)"
  rec_src=$(sed -E 's/^Source: `([0-9a-f]{40})`.*/\1/' <<<"$record")
  build=$(sed -E 's/.*Build: `([0-9]{12})`.*/\1/' <<<"$record")
  if [[ -n $src ]]; then
    src=$(git -C "$ROOT" rev-parse --verify "$src^{commit}") || die "unknown revision $src"
    [[ $src == "$rec_src" ]] || die "$release was built from ${rec_src:0:8} (changelog), not ${src:0:8}"
  fi
  src=$rec_src
  git -C "$ROOT" cat-file -e "$src^{commit}" 2>/dev/null || die "the release revision ${src:0:8} isn't in the private repository"
  # Release builds come from a cut branch (release/<version>-cut) that is later rebased onto main, so the
  # build revision needn't be on main; it must be a kept commit, not a dangling one.
  [[ -n $(git -C "$ROOT" for-each-ref --count=1 --contains "$src") ]] \
    || die "the release revision ${src:0:8} isn't on any branch or tag of the private repository"
fi
[[ -n $src ]] || src=$gate_rev
last=$(cat "$STATUS/public-sync.rev" 2>/dev/null || true)
if [[ -z $release && "$src" == "$last" ]]; then
  echo "sync-public: up to date at ${src:0:7}"
  write_state OK "up to date"
  exit 0
fi

# --- the gate as committed in $src (see the header); the lock (fd 9) stays held across exec -------
if [[ -z ${AIRC_SYNC_GATE:-} ]]; then
  gate=$(mktemp -d "${TMPDIR:-/tmp}/airc-sync-gate.XXXXXX")
  git -C "$ROOT" archive --format=tar "$gate_rev" -- infra/launch | tar -x -C "$gate"
  state_written=1  # the re-run copy owns the state from here
  AIRC_SYNC_GATE=$gate AIRC_SYNC_GATE_TMP=1 AIRC_SYNC_LOCKED=1 AIRC_SYNC_SRC=$src AIRC_PRIVATE_ROOT=$ROOT \
    AIRC_PUBLIC_DIR=$PUB AIRC_STATUS_DIR=$STATUS exec bash "$gate/infra/launch/sync-public.sh" "${args[@]}"
fi
[[ -z ${AIRC_SYNC_GATE_TMP:-} ]] || cleanup+=("$AIRC_SYNC_GATE")
[[ $AIRC_SYNC_GATE != local || $dry == 1 ]] || die "AIRC_SYNC_GATE=local is for --dry-run only"

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
done < <(cat "$HERE/exclude.txt"; [[ -z $release ]] || git -C "$ROOT" show "$src:infra/launch/exclude.txt" 2>/dev/null || true)
mapfile -t excludes < <(printf '%s\n' "${excludes[@]}" | awk 'NF && !seen[$0]++')
pathspec=(.)
for path in "${excludes[@]}"; do pathspec+=(":(exclude,glob)$path"); done

work=$(mktemp -d "${TMPDIR:-/tmp}/airc-sync.XXXXXX")
cleanup+=("$work")
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
if [[ -n $release ]]; then
  # Same blobs, modes and paths as the release revision minus the excludes.
  GIT_INDEX_FILE=$work/src-index git -C "$ROOT" read-tree "$src"
  diff <(GIT_INDEX_FILE=$work/src-index git -C "$ROOT" ls-files -s -- "${pathspec[@]}") <(pub ls-files -s) >/dev/null \
    || die "exported tree differs from ${src:0:8} minus exclude.txt"
  source "$HERE/release-tag.sh"
  exit 0
fi
if [[ "$tree" == "$(git -C "$PUB" rev-parse "$parent^{tree}")" ]]; then
  echo "sync-public: no file changes since the last public commit"
  [[ $dry == 1 ]] || echo "$src" >"$STATUS/public-sync.rev"
  write_state OK "no file changes" "$parent"
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
"$HERE/scan.sh" "$work/tree" | tee "$work/scan.out" || status=1
AIRC_PUBLIC_EMAILS="${AIRC_PUBLIC_EMAILS:-} $site_emails" "$HERE/scan.sh" "$work/meta" 2>/dev/null | sed 's/^/  /' | tee "$work/meta.out" || status=1
if [[ $status != 0 ]]; then
  summary=$(grep -h '^ *Privacy scan: FAIL' "$work/scan.out" "$work/meta.out" | sed 's/^ *Privacy scan: //' | paste -sd ';' -)
  die "SCAN FAILED for ${src:0:7}: ${summary:-scan error}; nothing published. Fix it in the private repo and push."
fi

echo "sync-public: ${src:0:7} → public commit ${commit:0:7} on ${parent:0:7}"
if [[ $dry == 1 ]]; then echo "sync-public: dry run, not pushed (tree $tree)"; exit 0; fi
# The push uses the machine's credentials again (the isolated config above has no credential helper).
env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM git -C "$PUB" push -q origin "$commit:refs/heads/main"
env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM git -C "$PUB" fetch -q origin main
git -C "$PUB" reset -q --hard origin/main
echo "$src" >"$STATUS/public-sync.rev"
write_state OK "published ${src:0:8} as ${commit:0:8}" "$commit"
echo "sync-public: pushed"
