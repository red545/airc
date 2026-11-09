#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Accept a green run only for identical app/package/engine/build inputs at HEAD.

A release also needs the UI cases to have run: a run whose cases were mostly FAIL-ENV (the owner using the Mac, our
window off the active Space or covered) passes the dev gate but is not release evidence. 0.1.2 shipped with 24 and 0.1.3
with 1; 2026-11-09's 6b1cd22 run had 225 (shortcuts 62, pipreturn 59, parityp16a 53). AIRC_RELEASE_MAX_FAIL_ENV
(default 10) is the most a release run may have.
"""
import os
import re
import subprocess
import sys
from pathlib import Path
root, location, rev = sys.argv[1:4]
FAIL_ENV = re.compile(r'^\s*\[(?:chromium|webkit)\] FAIL-ENV ', re.M)
def check(p):
    try:
        old = (p/'rev.txt').read_text().strip()
        steps = dict((line.split('\t')[0], line.split('\t')[1]) for line in (p/'steps.tsv').read_text().splitlines())
        if any(steps.get(k) != '0' for k in ('test-AircKit', 'test-AircImport', 'test-AircDesign', 'build-app')):
            return False
        if 'snapshots-webkit' in steps and steps['snapshots-webkit'] != '0': return False
        env_fails = len(FAIL_ENV.findall((p/'build-app.log').read_text(errors='replace')))
        if env_fails > int(os.environ.get('AIRC_RELEASE_MAX_FAIL_ENV', '10')):
            print(f'{p.name}: {env_fails} FAIL-ENV cases (the UI cases did not run); not release evidence', file=sys.stderr)
            return False
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
