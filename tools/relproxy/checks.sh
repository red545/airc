#!/bin/bash
# relproxy one-off checks against a preview deployment with the /releases/* rewrite:
# sha256 of the 0.1.17 delta, ZIP and DMG (proxy vs published), Range (206 + bytes equal to Blob),
# curl resume (-C -), HEAD, the notes.html redirect and /download's target.
# Usage: checks.sh <preview-url> <bypass-file>   (the bypass value is never printed)
set -u
P=${1%/}; S=$(cat "$2"); H="x-vercel-protection-bypass: $S"
B=https://hpqylr02za4pig6a.public.blob.vercel-storage.com
R=/releases/0.1.17/202611151025
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
hdr() { tr -d '\r' < "$1" | grep -i -E "^HTTP/|$2" | tr '\n' ' '; }
# This LAN refuses some TCP connects to every host (see REPORT); retry those, never mid-body failures.
curl() { local i rc; for i in 1 2 3 4 5 6; do command curl "$@"; rc=$?; [ $rc -ne 7 ] && return $rc; echo "(local connect refusal, retry $i)" >&2; sleep 1; done; return $rc; }
echo "preview: $P   (bypass sent as a header; value not shown)"
echo "== sha256 of whole files (identity, and Accept-Encoding: br decoded by curl --compressed)"
for f in Airc-202611151025-202611150343.delta Airc-0.1.17.zip Airc-0.1.17.dmg; do
  for mode in identity br; do
    extra=(); [ $mode = br ] && extra=(--compressed -H "Accept-Encoding: gzip, deflate, br")
    curl -sS -H "$H" "${extra[@]}" -D "$W/h" -o "$W/b" -w '%{http_code} %{remote_ip} %{time_total}s' "$P$R/$f" > "$W/w"
    echo "$f [$mode] $(cat "$W/w") $(stat -c %s "$W/b") B sha256 $(sha256sum "$W/b" | cut -c1-64) | $(hdr "$W/h" '^(content-encoding|content-length|etag):')"
  done
done
echo "published (latest.json / appcast): delta 1142ddae9d84675adafb54b97601fc0bc7edd6d62a8bab1adbaa9d2ca0495165 2908106 B; zip a0e2a8e7f89dcba4c134c33d86e39c67d8755bf1b77941c722d14513acd8787b 212349576 B; dmg $(curl -sS https://aircbrowser.com/latest.json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["sha256"],d["size"],"B")')"
echo "== Range"
for f in Airc-202611151025-202611150343.delta Airc-0.1.17.zip Airc-0.1.17.dmg; do
  for r in 0-0 1000-1999 100000000-100000999 -500; do
    curl -sS -H "$H" -r "$r" -D "$W/h" -o "$W/p" "$P$R/$f"
    curl -sS -r "$r" -o "$W/q" "$B$R/$f"
    same=$(cmp -s "$W/p" "$W/q" && echo bytes-equal-to-blob || echo DIFFERENT)
    echo "$f r=$r $(hdr "$W/h" '^(content-range|content-length|accept-ranges):') $(stat -c %s "$W/p") B $same"
  done
done
echo "== Range with Accept-Encoding: br (browsers/URLSession resume)"
curl -sS -H "$H" -H "Accept-Encoding: gzip, deflate, br" -r 1000-1999 -D "$W/h" -o "$W/p" "$P$R/Airc-0.1.17.zip"
echo "zip r=1000-1999 $(hdr "$W/h" '^(content-range|content-length|content-encoding):') $(stat -c %s "$W/p") B"
echo "== If-Range with the strong ETag (resume validator)"
E=$(curl -sS -I "$B$R/Airc-0.1.17.dmg" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
curl -sS -H "$H" -H "If-Range: $E" -r 5000-5999 -D "$W/h" -o "$W/p" "$P$R/Airc-0.1.17.dmg"
echo "dmg If-Range strong r=5000-5999 $(hdr "$W/h" '^(content-range|content-length):')"
echo "== curl resume (-C -) of the DMG after a 20 MB partial"
curl -sS -H "$H" -r 0-20971519 -o "$W/dmg" "$P$R/Airc-0.1.17.dmg"
curl -sS -H "$H" -C - -o "$W/dmg" -w 'resume %{http_code} %{size_download} B\n' "$P$R/Airc-0.1.17.dmg"
echo "resumed dmg $(stat -c %s "$W/dmg") B sha256 $(sha256sum "$W/dmg" | cut -c1-64)"
echo "== HEAD"
curl -sS -I -H "$H" "$P$R/Airc-0.1.17.zip" > "$W/h"; echo "zip HEAD $(hdr "$W/h" '^(content-length|accept-ranges|etag|content-encoding):')"
echo "== redirects that must stay"
curl -sS -o /dev/null -D "$W/h" -H "$H" "$P$R/notes.html"; echo "notes.html $(hdr "$W/h" '^location:')"
curl -sS -I -o /dev/null -D "$W/h" -H "$H" "$P/download"; echo "/download HEAD $(hdr "$W/h" '^(location|cache-control):')"
curl -sS -o /dev/null -w '%{http_code}' -H "$H" "$P/releases/0.1.17/202611151025/nope.zip"; echo " missing file"
curl -sS -o /dev/null -w '%{http_code} %{size_download} B' -H "$H" "$P/appcast.xml"; echo " appcast.xml (unchanged rewrite)"
