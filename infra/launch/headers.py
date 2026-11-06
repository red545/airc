#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Licence header check for an exported tree. Every source file (Swift, Objective-C/C++, C/C++,
shell, Python, JavaScript/TypeScript) must carry, in its first 12 lines, either

  the Airc header:      Copyright 2026 The Airc Authors + SPDX-License-Identifier: Apache-2.0
  the ArdiaCore header: Copyright 2026 Mantra Patel + SPDX-License-Identifier: Apache-2.0
                        + Modified by The Airc Authors

    headers.py <dir> [--list FILE]

Prints a summary per kind and directory; --list writes every miss as `path: <problem>`.
Exit status 1 when anything is missing. Generated and vendored files are skipped.
"""
import argparse
from collections import Counter
from pathlib import Path
import re
import sys

SOURCE = {'.swift', '.m', '.mm', '.h', '.c', '.cc', '.cpp', '.inc', '.sh', '.py', '.js', '.mjs', '.cjs', '.ts'}
SKIP_PARTS = {'.git', 'node_modules', '.build', 'dist', '.astro'}
SPDX = re.compile(r'SPDX-License-Identifier:\s*Apache-2\.0')
AIRC = re.compile(r'Copyright (?:\(c\) )?20\d\d(?:[-–]20\d\d)? The Airc Authors')
ARDIA = re.compile(r'Copyright (?:\(c\) )?20\d\d Mantra Patel')
MODIFIED = re.compile(r'Modified by The Airc Authors')


def check(path):
    try:
        head = '\n'.join(path.read_text(encoding='utf8', errors='replace').splitlines()[:12])
    except OSError:
        return 'unreadable'
    spdx = bool(SPDX.search(head))
    if ARDIA.search(head):
        if not spdx:
            return 'ArdiaCore copyright without the Apache SPDX line'
        if not MODIFIED.search(head):
            return 'ArdiaCore header without "Modified by The Airc Authors"'
        return None
    if AIRC.search(head):
        return None if spdx else 'Airc copyright without the Apache SPDX line'
    if spdx:
        return 'SPDX line without a copyright line'
    return 'no licence header'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--list')
    args = ap.parse_args()
    root = Path(args.dir).resolve()
    files = sorted(p for p in root.rglob('*') if p.is_file() and p.suffix in SOURCE
                   and not SKIP_PARTS & set(p.relative_to(root).parts))
    misses = [(p.relative_to(root).as_posix(), problem) for p in files if (problem := check(p))]
    by_problem = Counter(problem for _, problem in misses)
    by_dir = Counter('/'.join(rel.split('/')[:2]) for rel, _ in misses)
    by_ext = Counter(Path(rel).suffix for rel, _ in misses)
    print(f'{len(files)} source files, {len(files) - len(misses)} with a valid header, {len(misses)} missing')
    for problem, n in by_problem.most_common():
        print(f'  {n:4} {problem}')
    print('by directory:')
    for d, n in sorted(by_dir.items()):
        print(f'  {n:4} {d}')
    print('by extension: ' + ', '.join(f'{e} {n}' for e, n in sorted(by_ext.items())))
    if args.list:
        Path(args.list).write_text(''.join(f'{rel}: {problem}\n' for rel, problem in misses), encoding='utf8')
    return 1 if misses else 0


if __name__ == '__main__':
    sys.exit(main())
