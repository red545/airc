#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Mac-only, signed deltas from up to three acknowledged published apps. No publication."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

app, out, cache = map(Path, sys.argv[1:4])
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
build = str(info['CFBundleVersion'])
if not re.fullmatch(r'\d{12}', build):
    sys.exit('Invalid build')
sparkle = Path(os.environ.get('SPARKLE_ROOT', str(Path.home()/'arcfork/tools/sparkle')))
key = Path(os.environ.get('AIRC_SPARKLE_KEY_FILE', str(Path.home()/'arcfork/secrets/sparkle_ed25519_private')))
root = Path(__file__).resolve().parents[2]
if key.is_symlink() or not key.is_file() or key.stat().st_mode & 0o777 != 0o600 or key.stat().st_uid != os.getuid():
    sys.exit('Expected owned mode-600 Sparkle key on the build Mac')
public = subprocess.check_output(['swift', str(root/'infra/release/key-public.swift'), str(key)], text=True).strip()
if public != (root/'infra/release/sparkle-public-key.txt').read_text().strip():
    sys.exit('Sparkle key mismatch')
def signature(path):
    result = subprocess.check_output([str(sparkle/'bin/sign_update'), '--ed-key-file', str(key), str(path)], text=True)
    match = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/=]+)"\s+length="(\d+)"\s*', result)
    if not match or int(match[2]) != path.stat().st_size:
        raise ValueError('Invalid Sparkle signature metadata')
    return {'signature': match[1], 'size': int(match[2])}
# Migrate the dev cache once; all cached apps stay invisible to Spotlight.
legacy = Path.home()/'arcfork/updates-cache/dev'
if cache == Path.home()/'arcfork/updates-cache.noindex/dev' and legacy.exists() and not cache.exists():
    cache.parent.mkdir(parents=True, exist_ok=True)
    legacy.rename(cache)
cache.mkdir(parents=True, exist_ok=True)
# Refuse to grow the cache on a full build Mac. The app and a delta need scratch space.
free = shutil.disk_usage(cache).free
if free < 3_000_000_000:
    sys.exit('Insufficient disk for the update cache (need 3 GB headroom)')
prior = sorted((p for p in cache.iterdir() if re.fullmatch(r'\d{12}', p.name) and (p/'published').is_file()), reverse=True)
records = []
for old in prior[:3]:
    if int(old.name) >= int(build):
        sys.exit('Build is not greater than the published cache')
    before = old/'Airc.app'
    old_info = plistlib.loads((before/'Contents/Info.plist').read_bytes())
    if old_info['CFBundleIdentifier'] != info['CFBundleIdentifier']:
        continue
    path = out/f'Airc-{build}-{old.name}.delta'
    subprocess.run([str(sparkle/'bin/BinaryDelta'), 'create', str(before), str(app), str(path)], check=True)
    records.append({'from': old.name, 'file': path.name, **signature(path)})
(out/'deltas.json').write_text(json.dumps(records, indent=2)+'\n')
archive = next(out.glob('*.zip'))
(out/'signature.json').write_text(json.dumps(signature(archive), indent=2)+'\n')
# Only explicit upload acknowledgement promotes this copy to a delta source.
pending = cache/build
if pending.exists():
    if (pending/'published').exists():
        sys.exit('Refusing to replace a published cache build')
    shutil.rmtree(pending)
pending.mkdir()
subprocess.run(['ditto', str(app), str(pending/'Airc.app')], check=True)
# A cached copy shares the published bundle ID and has the newest build number, so Launch Services would pick it
# for links over the owner's copy: keep every cached app unregistered.
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
def unregister(bundle):
    if bundle.exists() and Path(LSREGISTER).exists():
        subprocess.run([LSREGISTER, '-u', str(bundle)], check=False, capture_output=True)
for kept in cache.iterdir():
    unregister(kept/'Airc.app')
# Bound disk use to 3 published apps plus this pending candidate; never delete other work.
for old in prior[3:]:
    shutil.rmtree(old)
for old in cache.iterdir():
    if re.fullmatch(r'\d{12}', old.name) and old != pending and not (old/'published').exists():
        shutil.rmtree(old)
print(f'Deltas: {len(records)}; bytes: '+', '.join(str(x['size']) for x in records))
