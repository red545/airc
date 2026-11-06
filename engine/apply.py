#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Apply byte-pinned integration patches. Check mode never writes to the tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

HERE = Path(__file__).resolve().parent

def digest(data):
    return hashlib.sha256(data).hexdigest()

def patches():
    for name in (HERE / 'patches/series').read_text().splitlines():
        if name.strip() and not name.startswith('#'):
            yield HERE / 'patches' / name

def apply_diff(data, lines):
    source = data.decode().splitlines(keepends=True)
    result, pos, i = [], 0, 0
    while i < len(lines):
        match = re.match(r'@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@', lines[i])
        if not match:
            i += 1
            continue
        start = int(match[1]) - 1
        if start < pos:
            raise ValueError('overlapping hunks')
        result.extend(source[pos:start]); pos = start; i += 1
        while i < len(lines) and lines[i][:1] in (' ', '+', '-'):
            kind, line = lines[i][0], lines[i][1:]
            if kind in (' ', '-'):
                if pos >= len(source) or source[pos] != line:
                    raise ValueError('patch context mismatch (no offsets or fuzz accepted)')
                pos += 1
            if kind in (' ', '+'):
                result.append(line)
            i += 1
    result.extend(source[pos:])
    return ''.join(result).encode()

def reverse_diff(lines):
    """Reverse exact hunks for a pinned, retired hook; never invoke patch fuzz."""
    result = []
    for line in lines:
        match = re.match(r'@@ -(\d+(?:,\d+)?) \+(\d+(?:,\d+)?) @@(.*)', line)
        if match:
            result.append(f'@@ -{match[2]} +{match[1]} @@{match[3]}\n')
        elif line.startswith(('+', '-')):
            result.append(('-' if line[0] == '+' else '+') + line[1:])
        else:
            result.append(line)
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--src', type=Path, default=Path(os.environ.get('CHROMIUM_SRC', str(Path.home() / 'arcfork/chromium/src'))))
    args = parser.parse_args()
    root = args.src.resolve()
    version = dict(line.split('=', 1) for line in (root / 'chrome/VERSION').read_text().splitlines())
    actual = '.'.join(version[key] for key in ('MAJOR', 'MINOR', 'BUILD', 'PATCH'))
    expected = (HERE.parent / 'CHROMIUM_VERSION').read_text().strip()
    if actual != expected:
        raise ValueError(f'Chromium {actual}, expected {expected}')
    manifest = json.loads((HERE / 'patches/manifest.json').read_text())
    current, staged, already = {}, {}, set()
    retired = json.loads((HERE / 'patches/retired.json').read_text())
    migrations = {}
    for name, hashes in retired.items():
        if name in manifest or Path(name).is_absolute() or '..' in Path(name).parts:
            raise ValueError('unsafe or active retired path')
        data = (root / name).read_bytes()
        sha = digest(data)
        if sha == hashes['before']:
            continue
        if sha != hashes['after']:
            raise ValueError(f'{name}: retired hook has unknown bytes; refusing to overwrite')
        if args.check:
            raise ValueError(f'{name}: retired hook still applied; rerun apply.sh to restore upstream')
        patch = Path(hashes['patch'])
        if patch.is_absolute() or '..' in patch.parts:
            raise ValueError('unsafe retired patch path')
        restored = apply_diff(data, reverse_diff((HERE / 'patches' / patch).read_text().splitlines(keepends=True)))
        if digest(restored) != hashes['before']:
            raise ValueError(f'{name}: retired hook reversal disagrees with pinned upstream')
        migrations[name] = restored
    for name, hashes in manifest.items():
        if Path(name).is_absolute() or '..' in Path(name).parts:
            raise ValueError('unsafe manifest path')
        data = (root / name).read_bytes(); current[name] = data
        sha = digest(data)
        if sha == hashes['after']:
            already.add(name)
        elif sha != hashes['before']:
            raise ValueError(f'{name}: neither pinned upstream nor pinned patched bytes; refusing to overwrite')
        staged[name] = data
    for patch in patches():
        lines = patch.read_text().splitlines(keepends=True)
        starts = [i for i, line in enumerate(lines) if line.startswith('--- a/')]
        if not starts:
            raise ValueError(f'{patch.name}: no file diff')
        for start, end in zip(starts, [*starts[1:], len(lines)]):
            section = lines[start:end]
            file = section[0][6:].strip()
            if file not in manifest or section[1].strip() != f'+++ b/{file}':
                raise ValueError(f'{patch.name}: unpinned or renamed file: {file}')
            if file not in already:
                staged[file] = apply_diff(staged[file], section)
    for name, data in staged.items():
        if digest(data) != manifest[name]['after']:
            raise ValueError(f'{name}: resulting bytes disagree with manifest')
    target = root / 'airc/core'
    own = {str(p.relative_to(HERE / 'core')): p.read_bytes() for p in (HERE / 'core').rglob('*') if p.is_file()}
    if args.check:
        if already and target.exists():
            copied = {str(p.relative_to(target)): p.read_bytes() for p in target.rglob('*') if p.is_file()}
            if copied != own:
                raise ValueError('copied //airc/core differs; rerun apply.sh to sync it')
        elif already:
            raise ValueError('hooks are applied but //airc/core is missing')
        print(f'PASS: {len(manifest)} touched files, {len(list(patches()))} strict patches; '
              f'{len(already)} files already applied. Tree unchanged.')
        return
    # All inputs were validated before the first mutation. A partial interrupted apply is resumable.
    target.mkdir(parents=True, exist_ok=True)
    for p in target.rglob('*'):
        if p.is_file() and str(p.relative_to(target)) not in own:
            p.unlink()
    for name, data in own.items():
        path = target / name; path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_bytes() != data:
            temp = path.with_name(path.name + '.airc-tmp'); temp.write_bytes(data); temp.replace(path)
    for name, data in {**staged, **migrations}.items():
        if data != current.get(name):
            path = root / name; temp = path.with_name(path.name + '.airc-tmp')
            temp.write_bytes(data); shutil.copymode(path, temp); temp.replace(path)
    print(f'Applied {len(list(patches()))} patches and synced //airc/core ({len(own)} files).')

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration) as error:
        sys.exit(f'apply: {error}')
