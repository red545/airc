#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Regenerate the private crate graph in a new, disposable source overlay.

Usage: generate-gn.py CHROMIUM_SOURCE GNRT_BINARY NEW_WORK_DIRECTORY
Only NEW_WORK_DIRECTORY is written. Review generated BUILD.gn files before
copying them to this crate's third_party directory. Never run gnrt gen directly
in Chromium's source root for Airc's graph.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('chromium', type=Path)
p.add_argument('gnrt', type=Path)
p.add_argument('work', type=Path)
a = p.parse_args()
chromium, gnrt, work = a.chromium.resolve(), a.gnrt.resolve(), a.work.absolute()
crate = Path(__file__).resolve().parent
if work.exists(): raise SystemExit('Work directory exists; choose a new owned directory.')
if not (chromium / 'build/rust/cargo_crate.gni').is_file() or not gnrt.is_file():
    raise SystemExit('Chromium source and a built Chromium gnrt binary are required.')
work.mkdir(parents=True)
root = work / 'src'; root.mkdir()
for entry in chromium.iterdir():
    if entry.name in ('third_party', 'airc', 'out', '.git', '.rustfmt.toml'): continue
    (root / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
if (chromium / '.rustfmt.toml').exists(): shutil.copy2(chromium / '.rustfmt.toml', root / '.rustfmt.toml')
(root / 'third_party').mkdir()
for entry in (chromium / 'third_party').iterdir():
    if entry.name != 'rust':
        (root / 'third_party' / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
third = root / 'third_party/rust'; third.mkdir()
shutil.copytree(crate / 'third_party/chromium_crates_io', third / 'chromium_crates_io')
env = dict(os.environ, CARGO_HOME=str(work / 'cargo-home'), CARGO_NET_OFFLINE='true',
           RUSTC=str(chromium / 'third_party/rust-toolchain/bin/rustc'))
env['PATH'] = str(chromium / 'third_party/rust-toolchain/bin') + os.pathsep + env.get('PATH', '')
subprocess.run([str(gnrt), 'gen'], cwd=root, env=env, check=True)
output = work / 'generated'; output.mkdir()
for source in sorted(third.glob('*/*/BUILD.gn')):
    text = source.read_text().replace('//third_party/rust/', '//airc/core/blocking-rust/third_party/')
    text = text.replace('//airc/core/blocking-rust:*', '//airc/core/blocking-rust/*')
    text = text.replace('cargo_crate("lib")', 'cargo_crate("airc_lib")').replace(':lib"', ':airc_lib"')
    text = re.sub(r'(  cargo_pkg_version = "[^"]+"\n)',
                  r'\1  rustc_metadata = "airc-blocking-${crate_name}-${cargo_pkg_version}"\n', text)
    target = output / source.relative_to(third)
    target.parent.mkdir(parents=True, exist_ok=True); target.write_text(text)
print('Generated private BUILD.gn files in', output)
print('Review the graph and copy only generated BUILD.gn files; crate bytes and notices remain unchanged.')
