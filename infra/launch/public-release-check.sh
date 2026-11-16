#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Release checklist step: is release <version>'s source tagged and released on the public repository?
#
#   infra/launch/public-release-check.sh <version>
#
# Checks, live (git ls-remote and the GitHub API, never a local copy):
#   1. the changelog entry on origin/main names the release's source revision and build,
#   2. tag v<version> exists on the public repository and is annotated, with that build in its message,
#   3. the tagged commit's tree is exactly that revision minus the paths the tag message lists (the excludes),
#      which must include every path in the revision's infra/launch/exclude.txt,
#   4. the GitHub Release for the tag is published (not a draft) and links the changelog.
# Prints one line per check and exits 0 only when all pass. It never pushes; when it fails, run
# `infra/launch/sync-public.sh --release <version>` (docs/release.md, "Public release tag").
#
# Env: AIRC_PUBLIC_REMOTE (default: the public clone's origin, ../public-airc).
set -euo pipefail
version=${1:?Usage: public-release-check.sh <version>}
[[ $version =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "Usage: public-release-check.sh <version>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
BASE=$(dirname "$(dirname "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)")")
remote=${AIRC_PUBLIC_REMOTE:-$(git -C "$BASE/public-airc" remote get-url origin 2>/dev/null || true)}
[[ -n $remote ]] || { echo "FAIL no public remote (set AIRC_PUBLIC_REMOTE)"; exit 1; }
repo=$(sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$remote")
tag=v$version
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
finish() { [[ $fails == 0 ]] && echo "public-release-check: PASS" || { echo "public-release-check: FAIL ($fails)"; exit 1; }; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/airc-release-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# 1. the published record
git -C "$ROOT" fetch -q origin main
record=$(git -C "$ROOT" show "origin/main:apps/marketing/src/content/changelog/$version.md" 2>/dev/null \
  | grep -E '^Source: `[0-9a-f]{40}`\. Build: `[0-9]{12}`' | tail -1 || true)
if [[ -z $record ]]; then
  bad "no 'Source: … Build: …' line in apps/marketing/src/content/changelog/$version.md on origin/main"; finish
fi
src=$(sed -E 's/^Source: `([0-9a-f]{40})`.*/\1/' <<<"$record")
build=$(sed -E 's/.*Build: `([0-9]{12})`.*/\1/' <<<"$record")
ok "changelog: $version is build $build from ${src:0:8}"

# 2. the tag, live
refs=$(git ls-remote --tags "$remote" "refs/tags/$tag" "refs/tags/$tag^{}")
tagobj=$(awk -v r="refs/tags/$tag" '$2 == r {print $1}' <<<"$refs")
commit=$(awk -v r="refs/tags/$tag^{}" '$2 == r {print $1}' <<<"$refs")
if [[ -z $tagobj || -z $commit ]]; then
  bad "no annotated tag $tag on the public repository (git ls-remote --tags)"; finish
fi
message=$(gh api "repos/$repo/git/tags/$tagobj" --jq '.object.type + " " + .object.sha + "\n" + .message' 2>/dev/null || true)
read -r otype osha <<<"$(head -1 <<<"$message")"
if [[ $otype == commit && $osha == "$commit" ]] && grep -q "^Build $build, " <<<"$message" \
    && grep -q "^Source: development revision $src " <<<"$message"; then
  ok "tag $tag (${tagobj:0:8}) → commit ${commit:0:8}, message names build $build and ${src:0:8}"
else
  bad "tag $tag's message doesn't name build $build and source ${src:0:8}, or it isn't on a commit"
fi

# 3. the tree: the release revision minus the excludes the tag lists, rebuilt here from the private objects
mapfile -t listed < <(awk '/^Source: development revision .*minus:$/ {f=1; next} f && /^  / {sub(/^  /, ""); print; next} f {exit}' <<<"$message")
mapfile -t required < <(git -C "$ROOT" show "$src:infra/launch/exclude.txt" 2>/dev/null \
  | sed -E 's/#.*//; s/[[:space:]]+$//' | awk 'NF')
for path in "${required[@]}"; do
  printf '%s\n' "${listed[@]}" | grep -qxF -- "$path" || bad "the tag's excludes miss $path from the revision's exclude.txt"
done
pathspec=(.)
for path in "${listed[@]}"; do pathspec+=(":(exclude,glob)$path"); done
mkdir "$tmp/objects"
export GIT_OBJECT_DIRECTORY=$tmp/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)/objects
GIT_INDEX_FILE=$tmp/src-index git -C "$ROOT" read-tree "$src"
GIT_INDEX_FILE=$tmp/src-index git -C "$ROOT" ls-files -s -- "${pathspec[@]}" \
  | sed -E 's/^([0-7]+) ([0-9a-f]+) [0-9]+\t/\1 \2\t/' | GIT_INDEX_FILE=$tmp/index git -C "$ROOT" update-index --add --index-info
want=$(GIT_INDEX_FILE=$tmp/index git -C "$ROOT" write-tree)
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
have=$(gh api "repos/$repo/git/commits/$commit" --jq .tree.sha 2>/dev/null || true)
[[ -n $have && $have == "$want" ]] && ok "tree ${have:0:8} = ${src:0:8} minus ${#listed[@]} excluded path(s)" \
  || bad "the tag's tree is ${have:0:8}, ${src:0:8} minus the excludes is ${want:0:8}"

# 4. the GitHub Release
rel=$(gh api "repos/$repo/releases/tags/$tag" \
  --jq '[.draft, (.published_at // ""), .html_url, (.body | contains("aircbrowser.com/changelog#'"$tag"'"))] | @tsv' 2>/dev/null || true)
IFS=$'\t' read -r draft published url linked <<<"$rel"
if [[ $draft == false && -n $published && $linked == true ]]; then
  ok "GitHub Release published $published: $url"
else
  bad "no published GitHub Release for $tag that links the changelog (draft=${draft:-none})"
fi
finish
