#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Bundle source and converted CC BY-SA lists; no downloads during app builds."""
import hashlib, json, pathlib, shutil, subprocess, sys, zlib
root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1])
source = root / 'apps/browser/Resources/BlockingLists'
work = root / 'build/blocking'
dest = app / 'Contents/Resources/BlockingLists'
dest.mkdir(parents=True, exist_ok=True)
# Generated distributable artifacts are published in the signed app itself, and
# retained under build/blocking/published for release assets. Never commit them.
published = work / 'published'; published.mkdir(exist_ok=True)
inputs = b'\n'.join((source / name).read_bytes() for name in ('easylist.txt', 'easyprivacy.txt'))
converter = work / 'export-rules'
converter_digest = hashlib.sha256(converter.read_bytes()).hexdigest()
digest = hashlib.sha256(inputs + b'\0airc-v2\0' + converter_digest.encode()).hexdigest()
stamp = work / 'converted-digest'
artifacts = ('webkit.json.deflate', 'native.bin.deflate', 'conversion-report.json')
if not stamp.exists() or stamp.read_text() != digest or any(not (published / name).is_file() for name in artifacts):
    subprocess.run([str(work / 'export-rules'), str(source), str(work / 'webkit.json'),
                    str(work / 'native.bin'), str(work / 'diagnostics.json')], check=True)
    diagnostics = json.loads((work / 'diagnostics.json').read_text())
    diagnostics.pop('rules', None)
    (published / 'conversion-report.json').write_text(json.dumps(diagnostics, indent=2) + '\n')
    for name in ('webkit.json', 'native.bin'):
        (published / (name + '.deflate')).write_bytes(zlib.compress((work / name).read_bytes(), 9))
    stamp.write_text(digest)
for file in source.iterdir():
    if file.is_file(): shutil.copy2(file, published / file.name)
for file in published.iterdir():
    if file.is_file() and file.name != 'manifest.json': shutil.copy2(file, dest / file.name)
manifest = {'schema': 1, 'converter': 'adblock-rust-0.13.5/airc-v2',
            'converter_sha256': converter_digest,
            'attribution': 'The EasyList authors', 'license': 'CC-BY-SA-3.0-or-later',
            'compression': 'zlib (Python zlib.decompress)',
            'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(dest.iterdir()) if p.name != 'manifest.json'}}
for folder in (dest, published):
    (folder / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
licenses = app / 'Contents/Resources/Licenses/Blocking'
licenses.mkdir(parents=True, exist_ok=True)
crate = root / 'engine/core/blocking-rust'
shutil.copy2(crate / 'THIRD-PARTY-NOTICES.md', licenses / 'THIRD-PARTY-NOTICES.md')
shutil.copytree(crate / 'licenses', licenses / 'licenses', dirs_exist_ok=True)
