#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Refreshes the public suffix list that Boosts key sites by: packages/AircKit/Resources/public_suffix_list.dat
# (MPL-2.0, its README). By default it takes the copy in the Chromium checkout, so the app's sites are the ones the engine
# isolates (Chromium builds the same file in); run it after moving CHROMIUM_VERSION. --upstream takes publicsuffix.org's
# current list instead.
#   scripts/refresh-public-suffix-list.sh [CHROMIUM_SRC]   default: $CHROMIUM_SRC, else ~/arcfork/chromium/src
#   scripts/refresh-public-suffix-list.sh --upstream
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
dest="$ROOT/packages/AircKit/Resources/public_suffix_list.dat"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [[ ${1:-} == --upstream ]]; then
  curl -fsSL https://publicsuffix.org/list/public_suffix_list.dat -o "$tmp"
  from="publicsuffix.org"
else
  src=${1:-${CHROMIUM_SRC:-$HOME/arcfork/chromium/src}}
  cp "$src/net/base/registry_controlled_domains/effective_tld_names.dat" "$tmp"
  from="the Chromium checkout ($(cat "$ROOT/CHROMIUM_VERSION") pinned)"
fi
# It must be the list: its licence header, both sections, and thousands of rules.
if ! grep -q 'Mozilla Public' "$tmp" || ! grep -q '===BEGIN ICANN DOMAINS===' "$tmp" || ! grep -q '===BEGIN PRIVATE DOMAINS===' "$tmp"; then
  echo "refresh-public-suffix-list: not a public suffix list (from $from)" >&2
  exit 1
fi
rules=$(grep -cv -e '^//' -e '^[[:space:]]*$' "$tmp")
if (( rules < 5000 )); then
  echo "refresh-public-suffix-list: only $rules rules (from $from)" >&2
  exit 1
fi
if cmp -s "$tmp" "$dest"; then
  echo "public suffix list: unchanged ($rules rules)"
  exit 0
fi
cp "$tmp" "$dest"
echo "public suffix list: $rules rules from $from"
echo "next: swift test --package-path packages/AircKit --filter 'PublicSuffixListTests|BoostTests', then commit the file"
