#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Isolated, hook-free checkout and drift report. Exit 2 means patch drift."""
import argparse
import difflib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from watch import ROOT, HERE, version
URL = 'https://chromium.googlesource.com/chromium/src.git'


def run(*args, cwd=None, capture=False):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def blob(src, rev, name):
    result = subprocess.run(['git', '-C', str(src), 'show', f'{rev}:{name}'], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def report(snapshot, src, old, new, out):
    spec = importlib.util.spec_from_file_location('strict_apply', snapshot / 'engine/apply.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = json.loads((snapshot / 'engine/patches/manifest.json').read_text())
    lines = []
    staged = {}
    failed = set()
    for patch in module.patches():
        diff = patch.read_text().splitlines(keepends=True)
        name = next(line[6:].strip() for line in diff if line.startswith('--- a/'))
        data = staged.get(name, blob(src, new, name))
        if data is None or name in failed:
            lines.append(f'{patch.name}: DRIFT (missing file or earlier patch failed): {name}')
            failed.add(name)
            continue
        try:
            staged[name] = module.apply_diff(data, diff)
            pinned = manifest.get(name, {}).get('before')
            state = 'context exact' if hashlib.sha256(blob(src, new, name)).hexdigest() == pinned else 'context exact; manifest/base review required'
            lines.append(f'{patch.name}: {state}: {name}')
        except ValueError as error:
            lines.append(f'{patch.name}: DRIFT: {name}: {error}')
            failed.add(name)
    (out / 'patches.txt').write_text('\n'.join(lines) + '\n')
    import re
    includes = set()
    for p in (snapshot / 'engine/core').rglob('*'):
        if p.is_file():
            includes.update(re.findall(r'^\s*#\s*(?:include|import)\s*["<]([^">]+)[">]', p.read_text(errors='replace'), re.M))
    headers = []
    for name in sorted(includes):
        a, b = blob(src, old, name), blob(src, new, name)
        if a is None and b is None:
            headers.append(f'UNRESOLVED (local, generated, SDK or dependency header): {name}\n')
        elif a != b:
            headers.extend(difflib.unified_diff((a or b'').decode(errors='replace').splitlines(True),
                           (b or b'').decode(errors='replace').splitlines(True),
                           fromfile=f'{old}/{name}', tofile=f'{new}/{name}'))
    (out / 'headers.diff').write_text(''.join(headers) or 'No directly included upstream headers changed.\n')
    print('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    args = parser.parse_args()
    version(args.version)
    old = (ROOT / 'CHROMIUM_VERSION').read_text().strip()
    version(old)
    if version(args.version) < version(old):
        raise SystemExit('Refusing downgrade')
    base = Path(os.environ.get('AIRC_CHROMIUM_NEXT', str(Path.home() / 'arcfork/chromium-next'))).resolve()
    mirror = Path(os.environ.get('CHROMIUM_SRC', str(Path.home() / 'arcfork/chromium/src'))).resolve()
    if base == mirror or base in mirror.parents or mirror in base.parents:
        raise SystemExit('Candidate must be separate from the source mirror')
    base.parent.mkdir(parents=True, exist_ok=True)
    with (base.parent / '.airc-chromium-update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        free = shutil.disk_usage(base.parent).free // (1024 ** 3)
        print(f'Free disk: {free} GiB; require 120 GiB; no build output will be created.', flush=True)
        if free < 120:
            raise SystemExit('Insufficient disk; do not fall back to modifying the mirror')
        marker = base / '.airc-candidate'
        if base.exists() and (not marker.exists() or marker.read_text().strip() != args.version):
            raise SystemExit('Existing candidate is not owned by this target. Preserve it; use a fresh AIRC_CHROMIUM_NEXT.')
        base.mkdir(exist_ok=True)
        marker.write_text(args.version + '\n')
        src = base / 'src'
        if src.exists():
            raise SystemExit('Candidate already has a source tree; preserve it and use a fresh AIRC_CHROMIUM_NEXT. This also protects dependency edits.')
        else:
            run('git', 'init', str(src))
            run('git', '-C', str(src), 'remote', 'add', 'origin', URL)
        for tag in dict.fromkeys([old, args.version]):
            run('git', '-C', str(src), 'fetch', '--depth=1', URL, f'refs/tags/{tag}:refs/tags/{tag}')
        run('git', '-C', str(src), 'checkout', '--detach', f'refs/tags/{args.version}')
        (base / '.gclient').write_text('solutions = ' + repr([{'name': 'src', 'url': URL, 'managed': False,
            'custom_deps': {}, 'custom_vars': {'checkout_pgo_profiles': False}}]) + '\ntarget_os = ["mac"]\n')
        run('gclient', 'sync', '--no-history', '--nohooks', '--revision', f'src@refs/tags/{args.version}', cwd=base)
        out = HERE / 'reports' / args.version
        out.mkdir(parents=True, exist_ok=True)
        # Snapshot avoids changing the pin or borrowing mutable engine files during checking.
        with tempfile.TemporaryDirectory(prefix='airc-check-', dir=base) as temp:
            snapshot = Path(temp)
            shutil.copytree(ROOT / 'engine', snapshot / 'engine')
            (snapshot / 'CHROMIUM_VERSION').write_text(args.version + '\n')
            report(snapshot, src, old, args.version, out)
            result = subprocess.run(['bash', str(snapshot / 'engine/apply.sh'), '--check', '--src', str(src)], capture_output=True, text=True)
            (out / 'apply-check.log').write_text(result.stdout + result.stderr)
            print(result.stdout + result.stderr)
        print(f'Reports: {out}')
        print('After fixing drift and following docs/rebase.md Mac sync/ownership gates, run ON THE BUILD MAC:')
        print('cd "$HOME/arcfork/airc"\nexport CHROMIUM_SRC="$HOME/arcfork/chromium/src"\nengine/apply.sh --check --src "$CHROMIUM_SRC"\nengine/build.sh --start')
        print('After successful build: engine/host/build.sh build\nnode engine/host/acceptance.mjs build/AircHost.app "$HOME/arcfork/acceptance-' + args.version + '-$(date +%s)"\nscripts/build-app.sh\nscripts/perf.sh --app build/Airc.app')
        return 2 if result.returncode else 0


if __name__ == '__main__':
    raise SystemExit(main())
