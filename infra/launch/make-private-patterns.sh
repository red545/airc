#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Writes the operator's private values, read from this machine's environment, to a pattern file
# for scan.sh. The file is never committed and this script never prints a value, only counts.
#
#   infra/launch/make-private-patterns.sh [out-file]   (default: $AIRC_PRIVATE_PATTERNS,
#                                                        else private-patterns.txt beside the repo)
#
# Sources: this box's tailnet names and IPs (tailscale status --self --json, including peers, so
# the build Mac is covered), local and SSH usernames, home-directory prefixes, the hosts in
# ~/.ssh/config, the git and GitHub identities configured here, and the private IP ranges.
# Add more lines by hand afterwards (for example real Space or tab names); a rerun keeps them.
#
# Format, one per line:  <kind><TAB>literal:<text>   or   <kind><TAB>regex:<python regex>
# Literals match case-insensitively and only at alphanumeric boundaries.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-${AIRC_PRIVATE_PATTERNS:-$(dirname "$ROOT")/private-patterns.txt}}
case "$out" in "$ROOT"/*) echo "Refusing to write private patterns inside the repository." >&2; exit 2 ;; esac

tmp=$(mktemp "${TMPDIR:-/tmp}/airc-patterns.XXXXXX")
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"

add() { # kind value
  local kind=$1 value=${2%.}
  value=${value//$'\t'/ }
  [[ -n "$value" ]] || return 0
  # Too short or a stock device name (phones report "localhost"): would match ordinary text.
  if [[ ${#value} -lt 4 || " $GENERIC " == *" ${value,,} "* ]]; then skipped=$((skipped + 1)); return 0; fi
  printf '%s\tliteral:%s\n' "$kind" "$value" >>"$tmp"
}
skipped=0
GENERIC="localhost iphone ipad android macbook macbook-pro macbook-air imac mac-mini desktop laptop ubuntu debian raspberrypi"

# Tailnet: this machine, its peers and the tailnet itself.
if command -v tailscale >/dev/null && json=$(tailscale status --self --json 2>/dev/null); then
  while IFS=$'\t' read -r kind value; do add "$kind" "$value"; done < <(jq -r '
      ([.Self] + ((.Peer // {}) | to_entries | map(.value)))[] as $n
      | (["tailnet-host", $n.DNSName], ["tailnet-host", $n.HostName],
         (($n.TailscaleIPs // [])[] | ["tailnet-ip", .])),
      ["tailnet-host", .MagicDNSSuffix], ["tailnet-host", (.CurrentTailnet.Name // "")]
      | select(.[1] != null and .[1] != "") | @tsv' <<<"$json")
else
  echo "warning: tailscale status unavailable; tailnet values not added" >&2
fi
add machine-host "$(hostname 2>/dev/null || true)"
add machine-host "$(hostname -f 2>/dev/null || true)"

# Local user and home.
add username "$(id -un)"
add home-path "$HOME"
add home-path "/home/$(id -un)"
add home-path "/Users/$(id -un)"

# SSH config: host aliases (no wildcards), HostNames and Users (the build Mac's username).
if [[ -r "$HOME/.ssh/config" ]]; then
  while read -r key rest; do
    case "${key,,}" in
      host) for alias in $rest; do [[ "$alias" == *[\*\?!]* ]] || add ssh-host "$alias"; done ;;
      hostname) add ssh-host "$rest" ;;
      user) add username "$rest"; add home-path "/Users/$rest"; add home-path "/home/$rest" ;;
    esac
  done < <(sed -e 's/#.*//' -e 's/=/ /' "$HOME/.ssh/config")
fi

# Git and GitHub identities configured on this machine.
for scope in --global --system; do
  add identity "$(git config "$scope" user.name 2>/dev/null || true)"
  add identity "$(git config "$scope" user.email 2>/dev/null || true)"
done
add identity "$(git -C "$ROOT" config user.name 2>/dev/null || true)"
add identity "$(git -C "$ROOT" config user.email 2>/dev/null || true)"
if command -v gh >/dev/null; then add identity "$(gh api user --jq .login 2>/dev/null || true)"; fi

# Deployment accounts: Vercel org/project IDs from the repo's (ignored) .vercel links, and the
# signed-in Vercel user and team slugs and names. The public project name is not included.
while IFS= read -r link; do
  while IFS= read -r value; do add deploy-account "$value"; done < <(jq -r '.orgId // empty, .projectId // empty' "$link")
done < <(find "$ROOT" -path '*/node_modules' -prune -o -path '*/.vercel/project.json' -print 2>/dev/null)
if command -v vercel >/dev/null; then
  add deploy-account "$(timeout 30 vercel whoami 2>/dev/null || true)"
  while IFS= read -r value; do add deploy-account "$value"; done < <(
    timeout 30 vercel teams ls --format json 2>/dev/null | jq -r '.teams[]? | .slug, .name, .id' 2>/dev/null || true)
fi

# Operator-local agent workspaces (their folder names quote private prompts).
if [[ -d "$HOME/.t3" ]]; then
  printf 'operator-path\tregex:\\.t3/(?:scratch|userdata|worktrees)\\b\n' >>"$tmp"
fi

# Private ranges: RFC 1918, CGNAT (tailnets), link-local, Tailscale/ULA and link-local IPv6.
cat >>"$tmp" <<'EOF'
private-ip	regex:(?<![\w.])(?:10\.(?:\d{1,3}\.){2}\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}|169\.254\.\d{1,3}\.\d{1,3})(?![\w.])
private-ip	regex:(?i)(?<![\w:])(?:f[cd][0-9a-f]{2}|fe[89ab][0-9a-f]):[0-9a-f]{0,4}:[0-9a-f:]*
tailnet-domain	regex:(?i)\b[a-z0-9-]+\.ts\.net\b
home-path-other	regex:(?<![\w~])/(?:Users|home)/(?!(?:user|username|you|me|runner|shared|example|name|someone|test|USER)\b)[A-Za-z][\w.-]*
EOF

# Keep hand-added lines from an earlier file (anything below the marker).
marker='# --- hand-added (kept on rerun) ---'
{
  echo "# Airc private patterns. Generated by infra/launch/make-private-patterns.sh. Never commit."
  sort -u "$tmp"
  echo "$marker"
  if [[ -f "$out" ]]; then sed -n "/^$marker\$/,\$p" "$out" | tail -n +2; fi
} >"$out.new"
chmod 600 "$out.new"
mv "$out.new" "$out"

echo "Wrote $(grep -cv '^#' "$out") patterns:"
grep -v '^#' "$out" | cut -f1 | sort | uniq -c
[[ $skipped == 0 ]] || echo "Skipped $skipped value(s) shorter than 4 characters or generic device names (too generic to match safely)."
