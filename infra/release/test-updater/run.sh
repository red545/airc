#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SPARKLE_ROOT=${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}
export SPARKLE_ROOT
channel=${AIRC_PROOF_CHANNEL:-stable}
[[ $channel == stable || $channel == nightly || $channel == dev ]] || exit 2
# Set FROM=- TO=<Developer ID> for the migration, then FROM=TO for continuity.
# Each run has a throwaway identity and install folder, never the owner's app.
work=${AIRC_PROOF_DIR:-$ROOT/build/updater-proof}
from_identity=${AIRC_PROOF_FROM_IDENTITY:--}
to_identity=${AIRC_PROOF_TO_IDENTITY:--}
[[ ! -e "$work" ]] || { echo 'Remove/archive build/updater-proof before rerunning.' >&2; exit 1; }
mkdir -p "$work"/{releases,installed,home/Library}
# Reserve an ephemeral loopback port and serve until the test ends.
python3 -u - "$work" <<'PY' &
import http.server, pathlib, sys, os
p=pathlib.Path(sys.argv[1]); os.chdir(p/'releases')
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler)
(p/'port').write_text(str(s.server_port)); s.serve_forever()
PY
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for ((i=0;i<30;i++)); do [[ ! -f "$work/port" ]] || break; sleep .1; done
port=$(cat "$work/port")
clang -fobjc-arc -Wno-incompatible-pointer-types -framework Cocoa -F "$SPARKLE_ROOT" -framework Sparkle \
 -Wl,-rpath,@executable_path/../Frameworks "$ROOT/infra/release/test-updater/main.m" -o "$work/UpdaterProof"
for version in 1 2; do
 app="$work/v$version/UpdaterProof.app"
 mkdir -p "$app/Contents/"{MacOS,Frameworks}
 cp "$work/UpdaterProof" "$app/Contents/MacOS/UpdaterProof"
 ditto "$SPARKLE_ROOT/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
 python3 - "$app" "$version" "$port" "$ROOT" "$work" "$channel" <<'PY'
import sys,pathlib,plistlib
app,v,port,root,work,channel=sys.argv[1:]
p={'ProofChannel':channel,'CFBundleIdentifier':'org.airc.release.UpdaterProof.'+pathlib.Path(work).name,'CFBundleName':'UpdaterProof','CFBundleExecutable':'UpdaterProof','CFBundlePackageType':'APPL','CFBundleVersion':v,'CFBundleShortVersionString':'0.0.'+v,'LSMinimumSystemVersion':'14.0','LSUIElement':True,'SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml','SUPublicEDKey':(pathlib.Path(root)/'infra/release/sparkle-public-key.txt').read_text().strip(),'SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True},'ProofLog':work+'/result.log'}
(pathlib.Path(app)/'Contents/Info.plist').write_bytes(plistlib.dumps(p))
PY
 identity=$from_identity
 [[ $version == 1 ]] || identity=$to_identity
 python3 "$ROOT/scripts/release/sign.py" "$app" "$identity"
 ditto -c -k --keepParent "$app" "$work/releases/UpdaterProof-0.0.$version.zip"
done
echo '# Test update 0.0.2' > "$work/notes.md"
"$ROOT/scripts/release/appcast.sh" stable "$work/releases" UpdaterProof-0.0.2.zip "$work/notes.md" "http://127.0.0.1:$port/"
# Feed signing is off: reclassifying the isolated fixture does not change archive EdDSA signatures.
python3 - "$work/releases/appcast.xml" "$channel" <<'PYCHANNEL'
import sys,xml.etree.ElementTree as ET
p=sys.argv[1];tree=ET.parse(p)
for node in tree.findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}channel'): node.text=sys.argv[2]
tree.write(p,encoding='utf-8',xml_declaration=True)
PYCHANNEL
# The dev channel publishes full ZIPs. Optionally omit deltas to prove that path too.
if [[ ${AIRC_PROOF_FULL:-0} == 1 ]]; then
 python3 - "$work/releases/appcast.xml" <<'PYXML'
import sys, xml.etree.ElementTree as ET
p = sys.argv[1]
tree = ET.parse(p)
for item in tree.findall('.//item'):
    for child in list(item):
        if child.tag.endswith('}deltas'):
            item.remove(child)
tree.write(p, encoding='utf-8', xml_declaration=True)
PYXML
fi
ditto "$work/v1/UpdaterProof.app" "$work/installed/UpdaterProof.app"
open -g -n --env "CFFIXED_USER_HOME=$work/home" --env AIRC_TELEMETRY_ENABLED=0 "$work/installed/UpdaterProof.app"
for ((i=0;i<150;i++)); do
 if [[ -f "$work/result.log" ]] && grep -q 'PASS installed and relaunched 0.0.2' "$work/result.log"; then
  cat "$work/result.log"
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$work/installed/UpdaterProof.app/Contents/Info.plist") == 2 ]]
  codesign --verify --deep --strict "$work/installed/UpdaterProof.app"
  if [[ "$to_identity" != - ]]; then
    codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$work/installed/UpdaterProof.app"
    echo 'PASS installed Developer ID signature'
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$work/installed/UpdaterProof.app" 2>/dev/null || true
  exit 0
 fi
 sleep 1
done
cat "$work/result.log" >&2; exit 1
