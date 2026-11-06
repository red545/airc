#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Self-test for scan.sh: plants fake private values into a temporary copy of the committed tree
# and proves the scan finds each one, at the right place, without printing any of them.
#
#   infra/launch/test_scan.sh
#
# Every planted value is built at runtime, so this file itself stays clean under the scan.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/airc-test-scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
tree=$work/tree
mkdir "$tree"
git -C "$ROOT" archive HEAD | tar -x -C "$tree"

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# Fake values. None of them occurs literally in this file.
d=.
host="zz-fake-box${d}tail0000${d}ts${d}net"
ip="100${d}99${d}88${d}77"
user="qqfake""user"
home="/Users/$user"
email="planted${d}person@airc-selftest-$RANDOM${d}com"
token=$(python3 -c 'import secrets, string; print("ghp_" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36)))')
space="Qqfake ""Secret Space"

patterns=$work/patterns.txt
{
  printf 'tailnet-host\tliteral:%s\n' "$host"
  printf 'tailnet-ip\tliteral:%s\n' "$ip"
  printf 'username\tliteral:%s\n' "$user"
  printf 'home-path\tliteral:%s\n' "$home"
  printf 'space-name\tliteral:%s\n' "$space"
  # The generator's regexes (private IP ranges, tailnet domain, other home paths), as shipped.
  grep -P '^[a-z-]+\tregex:' "$HERE/make-private-patterns.sh"
} >"$patterns"

# Plant them.
printf 'let peer = "https://%s/feed"\n' "$host" >>"$tree/README.md"                 # README.md:N+1
readme_line=$(wc -l <"$tree/README.md")
mkdir -p "$tree/planted"
printf 'one\nlog: built in %s/arcfork\n' "$home" >"$tree/planted/build.log"          # line 2
printf '{"server": "%s", "space": "%s"}\n' "$ip" "${space,,}" >"$tree/planted/conf.json"   # line 1, lowercase
printf '\n\ncontact %s\n' "$email" >"$tree/planted/contact.md"                       # line 3
printf 'export GITHUB_TOKEN=%s\n' "$token" >"$tree/planted/env.sh"                   # line 1
printf 'reserved: someone@example.com, a@b.invalid, icon@2x.png\n' >"$tree/planted/ok.md"
python3 - "$tree/planted/shot.png" "$home" <<'EOF'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 0, 0, 0, 0))
png += chunk(b'tEXt', b'Source\0' + sys.argv[2].encode() + b'/Desktop/shot.png')
png += chunk(b'IDAT', zlib.compress(b'\0\0')) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
EOF
touch "$tree/planted/notes-$user.txt"
ln -s /etc/hosts "$tree/planted/outside"

run() { AIRC_PRIVATE_PATTERNS=$patterns AIRC_SCAN_ALLOWLIST=${allow:-/dev/null} "$HERE/scan.sh" "$1" >"$work/out" 2>&1; }

allow=$work/none.txt; : >"$allow"
if run "$tree"; then fail "scan exits non-zero on planted values"; else pass "scan exits non-zero on planted values"; fi

expect() { # needle description
  if grep -qF -- "$1" "$work/out"; then pass "$2"; else fail "$2 (expected '$1')"; fi
}
expect "README.md:$readme_line: tailnet-host"          "tailnet host in text, with file:line"
expect "README.md:$readme_line: tailnet-domain"        "generic tailnet domain regex"
expect "planted/build.log:2: home-path"                "home path"
expect "planted/build.log:2: username"                 "username inside a path"
expect "planted/conf.json:1: tailnet-ip"               "tailnet IP literal"
expect "planted/conf.json:1: private-ip"               "private IP range regex"
expect "planted/conf.json:1: space-name"               "hand-added value, case-insensitive"
expect "planted/contact.md:3: email"                   "non-reserved email"
expect "planted/env.sh:1: gitleaks:"                   "gitleaks finds a planted token"
expect "planted/shot.png:-: home-path"                 "home path in PNG metadata"
expect "path:username"                                 "private value in a file name"
expect "planted/outside:-: external-symlink"           "symlink leaving the tree"
if grep -q 'planted/ok.md' "$work/out"; then fail "reserved addresses are not flagged"; else pass "reserved addresses are not flagged"; fi
if grep -qF "notes-" "$work/out"; then fail "file name with a private value is redacted"; else pass "file name with a private value is redacted"; fi

leaked=0
for value in "$host" "$ip" "$user" "$email" "$token" "$space" "${space,,}"; do
  grep -qiF -- "$value" "$work/out" && leaked=1
done
# Partial leaks too: the distinctive parts of the planted values.
for part in tail0000 zz-fake-box airc-selftest "${token:4:12}" "Secret Space"; do
  grep -qiF -- "$part" "$work/out" && leaked=1
done
if [[ $leaked == 0 ]]; then pass "no planted value appears in the output"; else fail "a planted value appears in the output"; fi

# The allowlist approves a file:kind pair and nothing else.
allow=$work/allow.txt
printf 'planted/contact.md\temail\tSelf-test: approved planted address.\n' >"$allow"
run "$tree" || true
if grep -qF "planted/contact.md:3: email" "$work/out"; then fail "allowlisted pair is approved"; else pass "allowlisted pair is approved"; fi
expect "planted/conf.json:1: tailnet-ip" "other hits stay unapproved"
printf 'planted/contact.md\temail\n' >"$allow"
if run "$tree"; then fail "allowlist entry without a reason is rejected"
else expect "allowlist line 1" "allowlist entry without a reason is rejected"; fi

# The clean committed tree passes once the planted files are gone (with the real allowlist).
rm -rf "$tree/planted"
git -C "$ROOT" show HEAD:README.md >"$tree/README.md"
allow=$HERE/scan-allowlist.txt
if run "$tree"; then pass "unplanted copy passes"; else fail "unplanted copy passes"; sed -n '1,20p' "$work/out"; fi

# Refusals.
inside=$tree/patterns.txt; cp "$patterns" "$inside"
if AIRC_PRIVATE_PATTERNS=$inside "$HERE/scan.sh" "$tree" >/dev/null 2>&1; then fail "pattern file inside the tree is refused"
else pass "pattern file inside the tree is refused"; fi
if AIRC_PRIVATE_PATTERNS=$work/missing.txt "$HERE/scan.sh" "$tree" >/dev/null 2>&1; then fail "missing pattern file is refused"
else pass "missing pattern file is refused"; fi

echo
if [[ $fails != 0 ]]; then echo "test_scan: $fails failed"; exit 1; fi
echo "test_scan: all passed"
