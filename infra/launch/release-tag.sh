# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Sourced by `sync-public.sh --release <version>` once the release's tree ($tree, in the public clone's object store)
# matches its private build revision ($src) minus the excludes. Tags it v<version> and publishes a GitHub Release.
# Never moves public main, never moves or forces a tag. Uses: release build src tree parent notes_md excludes
# work PUB REMOTE HERE dry name email (from sync-public.sh).

tag=v$release
gh_repo=$(sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$REMOTE")
[[ $gh_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "can't read the GitHub repository from the public remote"
# Network steps use the machine's credentials (the isolated git config has no credential helper). Nothing echoes them.
pubnet() { env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM git -C "$PUB" "$@"; }
ghnet() { env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM gh "$@"; }
pubgit() { git --git-dir="$PUB/.git" "$@"; }
built="${build:0:4}-${build:4:2}-${build:6:2} ${build:8:2}:${build:10:2} UTC"
changelog="https://aircbrowser.com/changelog#$tag"

# --- the commit and the tag: reuse an existing tag only if it holds exactly this tree ----------------
remote_tags=$(pubnet ls-remote --tags origin)
tagobj=$(awk -v r="refs/tags/$tag" '$2 == r {print $1}' <<<"$remote_tags")
if [[ -n $tagobj ]]; then
  pubnet fetch -q --no-tags origin "+refs/tags/$tag:refs/airc-release-check/$tag"
  have=$(pubgit rev-parse "refs/airc-release-check/$tag^{tree}")
  [[ $have == "$tree" ]] || die "tag $tag already exists on the public repository with another tree (${have:0:8}, want ${tree:0:8}); tags are never moved"
  [[ $(pubgit cat-file -t "$tagobj") == tag ]] || die "tag $tag exists but isn't annotated"
  commit=$(pubgit rev-parse "refs/airc-release-check/$tag^{commit}")
  echo "sync-public: $tag already on the public repository (${commit:0:8}, same tree)"
else
  if [[ $tree == "$(pubgit rev-parse "$parent^{tree}")" ]]; then
    commit=$parent  # public main is exactly the release tree: tag main's commit
    where="public main"
  else
    {
      echo "Airc $release release source (build $build)"
      echo
      echo "The tree Airc $release (build $build) was built from, published with tag $tag. This commit sits beside"
      echo "main (its parent is public main when it was tagged); development continues on main."
    } >"$work/commit-message"
    commit=$(pubgit commit-tree "$tree" -p "$parent" -F "$work/commit-message")
    where="a side commit on ${parent:0:8}"
  fi
  {
    echo "object $commit"
    echo "type commit"
    echo "tag $tag"
    echo "tagger $name <$email> $(date -u +%s) +0000"
    echo
    echo "Airc $release"
    echo
    echo "Build $build, built $built, stable channel."
    echo "Source: development revision $src (the changelog's Source line), minus:"
    for path in "${excludes[@]}"; do echo "  $path"; done
    echo "Notes: $changelog"
  } >"$work/tag"
  tagobj=$(pubgit mktag <"$work/tag")
  echo "sync-public: $tag → ${commit:0:8} ($where), tag object ${tagobj:0:8}"
fi

# --- the GitHub Release notes: the changelog's intro and "New since" section --------------------------
# GitHub shows each newline in a Release body as a line break, so the changelog's hard-wrapped lines are joined.
{
  awk 'NR == 1 && /^# / {next} /^## / {n++} n >= 2 {exit}
       /^$/ || /^#/ || /^- / || /^[0-9]+\. / { if (cur != "" || started) print cur; cur = $0; started = 1; next }
       { sub(/^ +/, ""); cur = (cur == "" ? $0 : cur " " $0) }
       END { print cur }' <<<"$notes_md" | awk 'NF {p = 1} p' | cat -s
  echo
  echo "Full notes, with every earlier release and the known limits: $changelog"
  echo
  echo "**Source.** This tag is the exact source of build $build (built $built): the development revision \`$src\` named in the changelog, minus the paths in \`infra/launch/exclude.txt\`. Download Airc at https://aircbrowser.com."
} >"$work/meta/RELEASE-NOTES.md"

# --- the gate: tree, commit, tag and notes ---------------------------------------------------------
pubgit log -1 --format='%an%n%ae%n%cn%n%ce%n%B' "$commit" >"$work/meta/COMMIT-METADATA"
if [[ -n $(awk -v r="refs/tags/$tag" '$2 == r' <<<"$remote_tags") ]]; then
  pubgit cat-file -p "refs/airc-release-check/$tag" >"$work/meta/TAG-METADATA"
else
  cp "$work/tag" "$work/meta/TAG-METADATA"
fi
site_emails=$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$work/tree/apps/marketing/src/lib/site.ts" 2>/dev/null | tr '\n' ' ')
status=0
"$HERE/scan.sh" "$work/tree" | tee "$work/scan.out" || status=1
AIRC_PUBLIC_EMAILS="${AIRC_PUBLIC_EMAILS:-} $site_emails" "$HERE/scan.sh" "$work/meta" 2>/dev/null | sed 's/^/  /' | tee "$work/meta.out" || status=1
if [[ $status != 0 ]]; then
  summary=$(grep -h '^ *Privacy scan: FAIL' "$work/scan.out" "$work/meta.out" | sed 's/^ *Privacy scan: //' | paste -sd ';' -)
  die "SCAN FAILED for $tag (${src:0:7}): ${summary:-scan error}; nothing published."
fi

if [[ $dry == 1 ]]; then
  echo "sync-public: dry run, $tag not pushed (tree $tree). Tag message and notes:"
  sed -n '/^$/,$p' "$work/meta/TAG-METADATA" | sed 's/^/  | /'
  sed 's/^/  > /' "$work/meta/RELEASE-NOTES.md"
  return 0 2>/dev/null || exit 0
fi

if [[ -z $(awk -v r="refs/tags/$tag" '$2 == r' <<<"$remote_tags") ]]; then
  # A plain push of a new ref: it fails (never overwrites) if someone created the tag meanwhile.
  pubnet push -q origin "$tagobj:refs/tags/$tag"
  echo "sync-public: pushed $tag"
fi
pubnet update-ref -d "refs/airc-release-check/$tag" 2>/dev/null || true

# --- the GitHub Release ------------------------------------------------------------------------------
newest=$(pubnet ls-remote --tags origin 'refs/tags/v*' | sed -nE 's#.*refs/tags/v([0-9.]+)$#\1#p' | sort -V | tail -1)
latest=false; [[ $newest == "$release" ]] && latest=true
if draft=$(ghnet release view "$tag" -R "$gh_repo" --json isDraft --jq .isDraft 2>/dev/null); then
  [[ $draft == false ]] || ghnet release edit "$tag" -R "$gh_repo" --draft=false >/dev/null
  echo "sync-public: GitHub Release $tag already exists"
else
  ghnet release create "$tag" -R "$gh_repo" --verify-tag --title "Airc $release" \
    --notes-file "$work/meta/RELEASE-NOTES.md" --latest="$latest" >/dev/null
  echo "sync-public: created GitHub Release $tag (latest: $latest)"
fi
echo "sync-public: $(ghnet release view "$tag" -R "$gh_repo" --json url --jq .url)"
