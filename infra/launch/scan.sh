#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Privacy and secret gate for an exported tree (the fresh public repository, before it is pushed).
#
#   infra/launch/scan.sh <dir>
#
# 1. gitleaks (pinned release, checksum-verified, kept in the tools folder beside the repo) scans
#    <dir> without git history; its report is redacted.
# 2. scan.py greps every file for the operator's private values from $AIRC_PRIVATE_PATTERNS
#    (default: private-patterns.txt beside the repo; make one with make-private-patterns.sh)
#    and for email addresses that are neither reserved nor the public mailbox in
#    apps/marketing/src/lib/site.ts (add more with AIRC_PUBLIC_EMAILS="a@b c@d").
#
# Hits print as `file:line: kind`, never the value. Approved hits live in scan-allowlist.txt
# (path glob, kind, reason). Exit status is non-zero on any unapproved hit.
#
# Env: AIRC_TOOLS_DIR (default: tools/ beside the repo), AIRC_SCAN_ALLOWLIST, AIRC_SCAN_SHOW_ALLOWED=1.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
dir=${1:?Usage: scan.sh <dir>}
[[ $# == 1 && -d "$dir" ]] || { echo "Usage: scan.sh <dir>" >&2; exit 2; }
dir=$(cd "$dir" && pwd)

patterns=${AIRC_PRIVATE_PATTERNS:-$(dirname "$ROOT")/private-patterns.txt}
[[ -s "$patterns" ]] || { echo "No private pattern file; run infra/launch/make-private-patterns.sh first." >&2; exit 2; }
case "$(cd "$(dirname "$patterns")" && pwd)/" in
  "$ROOT"/*|"$dir"/*) echo "The private pattern file must live outside the repository and the scanned tree." >&2; exit 2 ;;
esac
allowlist=${AIRC_SCAN_ALLOWLIST:-$HERE/scan-allowlist.txt}

# --- gitleaks, pinned -------------------------------------------------------------------------
GITLEAKS_VERSION=8.30.1
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  asset=linux_x64;    sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
  Linux-aarch64) asset=linux_arm64;  sha=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
  Darwin-arm64)  asset=darwin_arm64; sha=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
  *) echo "No pinned gitleaks build for this platform." >&2; exit 2 ;;
esac
tools=${AIRC_TOOLS_DIR:-$(dirname "$ROOT")/tools}
gitleaks=$tools/gitleaks-$GITLEAKS_VERSION/gitleaks
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
if [[ ! -x "$gitleaks" ]]; then
  base=https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION
  tarball=gitleaks_${GITLEAKS_VERSION}_$asset.tar.gz
  dl=$(mktemp -d "${TMPDIR:-/tmp}/airc-gitleaks.XXXXXX")
  trap 'rm -rf "$dl"' EXIT
  curl -fsSL --retry 3 -o "$dl/$tarball" "$base/$tarball"
  curl -fsSL --retry 3 -o "$dl/checksums.txt" "$base/gitleaks_${GITLEAKS_VERSION}_checksums.txt"
  # Both must agree: the published checksum file and the hash pinned here.
  published=$(awk -v f="$tarball" '$2 == f {print $1}' "$dl/checksums.txt")
  actual=$(sha256 "$dl/$tarball")
  [[ "$actual" == "$sha" && "$published" == "$sha" ]] || { echo "gitleaks checksum mismatch; not installing." >&2; exit 2; }
  mkdir -p "$(dirname "$gitleaks")"
  tar -xzf "$dl/$tarball" -C "$(dirname "$gitleaks")" gitleaks
  rm -rf "$dl"
  trap - EXIT
fi

report=$(mktemp "${TMPDIR:-/tmp}/airc-gitleaks-report.XXXXXX")
trap 'rm -f "$report"' EXIT
set +e
"$gitleaks" dir --no-banner --no-color --redact=100 --log-level error \
  --report-format json --report-path "$report" "$dir" >/dev/null 2>&1
leaks=$?
set -e
# 0 = clean, 1 = leaks found (listed below); anything else is a gitleaks failure.
[[ $leaks == 0 || $leaks == 1 ]] || { echo "gitleaks failed (exit $leaks)." >&2; exit 2; }
[[ -s "$report" ]] || echo '[]' >"$report"
echo "gitleaks $GITLEAKS_VERSION: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$report") finding(s)"

# --- private values and emails ----------------------------------------------------------------
args=(--patterns "$patterns" --gitleaks-report "$report")
[[ -f "$allowlist" ]] && args+=(--allowlist "$allowlist")
[[ "${AIRC_SCAN_SHOW_ALLOWED:-}" == 1 ]] && args+=(--show-allowed)
for email in ${AIRC_PUBLIC_EMAILS:-}; do args+=(--public-email "$email"); done
python3 "$HERE/scan.py" "$dir" "${args[@]}"
