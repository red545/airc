#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Accept a green run only for identical app/package/engine/build inputs at HEAD."""
import subprocess
import sys
from pathlib import Path
root, location, rev = sys.argv[1:4]
def check(p):
    try:
        old = (p/'rev.txt').read_text().strip()
        steps = dict((line.split('\t')[0], line.split('\t')[1]) for line in (p/'steps.tsv').read_text().splitlines())
        if any(steps.get(k) != '0' for k in ('test-AircKit', 'test-AircImport', 'test-AircDesign', 'build-app')):
            return False
        if 'snapshots-webkit' in steps and steps['snapshots-webkit'] != '0': return False
        # Release tooling/docs may change after the suite. Application inputs may not.
        return subprocess.run(['git', '-C', root, 'diff', '--quiet', old, rev, '--',
                               'apps/browser', 'packages', 'engine', 'scripts/build-app.sh', 'CHROMIUM_VERSION']).returncode == 0
    except (OSError, ValueError, IndexError): return False
p=Path(location)
if '--check' in sys.argv:
    sys.exit(0 if check(p) else 'Green evidence is missing, red, or covers different source')
for candidate in sorted(p.glob('*'), reverse=True):
    if check(candidate): print(candidate); break
else: sys.exit(1)
