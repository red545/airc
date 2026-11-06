#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Exercise the production delta helper against the two completed fixture bundles.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
fixture=${1:?Pass the completed test-updater output directory}
work="$fixture/production-delta"
[[ ! -e "$work" ]] || { echo 'Refusing to overwrite proof output' >&2; exit 1; }
mkdir -p "$work/cache/202611060001" "$work/output"
ditto "$fixture/v1/UpdaterProof.app" "$work/cache/202611060001/Airc.app"
ditto "$fixture/v2/UpdaterProof.app" "$work/Airc.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 202611060001' "$work/cache/202611060001/Airc.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 202611060002' "$work/Airc.app/Contents/Info.plist"
python3 "$ROOT/scripts/release/sign.py" "$work/cache/202611060001/Airc.app" "$AIRC_SIGN_IDENTITY"
python3 "$ROOT/scripts/release/sign.py" "$work/Airc.app" "$AIRC_SIGN_IDENTITY"
touch "$work/cache/202611060001/published"
ditto -c -k --keepParent "$work/Airc.app" "$work/output/update.zip"
python3 "$ROOT/scripts/release/deltas.py" "$work/Airc.app" "$work/output" "$work/cache"
"${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}/bin/BinaryDelta" apply \
 "$work/cache/202611060001/Airc.app" "$work/reconstructed.app" "$work/output/Airc-202611060002-202611060001.delta"
codesign --verify --deep --strict "$work/reconstructed.app"
python3 - "$work/Airc.app" "$work/reconstructed.app" <<'PYCOMPARE'
import hashlib,os,pathlib,stat,sys
def inventory(root):
 root=pathlib.Path(root); result={}
 for folder, dirs, files in os.walk(root, followlinks=False):
  for name in dirs+files:
   p=pathlib.Path(folder)/name; relative=str(p.relative_to(root))
   if p.is_symlink(): result[relative]=('link',os.readlink(p))
   elif p.is_file(): result[relative]=('file',hashlib.sha256(p.read_bytes()).hexdigest(),stat.S_IMODE(p.stat().st_mode))
 return result
assert inventory(sys.argv[1])==inventory(sys.argv[2]), 'Reconstructed bundle differs'
PYCOMPARE
echo 'PASS production delta reconstructs the exact signed app'
