#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Vercel's "Ignored Build Step" for airc-homepage (vercel.json ignoreCommand), run from apps/marketing.
# Exit 0 skips the deployment, anything else builds. It compares the whole push, from the commit Vercel last
# deployed (VERCEL_GIT_PREVIOUS_SHA) to HEAD, against every path the site's build reads, so a push whose last
# commit doesn't touch the site still deploys an earlier commit's site change. When that commit isn't known or
# isn't in the clone (a shallow clone, a first deploy), it builds.
set -u
paths=(. ../../docs/user ../../docs/release-notes-beta.md ../../assets/screenshots ../../CHROMIUM_VERSION)
base=${VERCEL_GIT_PREVIOUS_SHA:-}
if [[ -z "$base" ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo "vercel-ignore: no previous deployment commit in this clone; building"
  exit 1
fi
if git diff --quiet "$base" HEAD -- "${paths[@]}"; then
  echo "vercel-ignore: nothing the site reads changed since ${base:0:7}; skipping"
  exit 0
fi
echo "vercel-ignore: site inputs changed since ${base:0:7}; building"
exit 1
