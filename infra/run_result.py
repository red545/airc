#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Shared run state for status and retry policy; independent failures take precedence."""
import json
from pathlib import Path
import sys


def state(run):
    run = Path(run)
    steps = {}
    if (run / 'steps.tsv').exists():
        steps = dict(line.split('\t')[:2] for line in (run / 'steps.tsv').read_text().splitlines())
    if any((name.startswith('test-') and rc != '0') or
           (rc not in ('0', '3') and not (rc == '75' and name in ('ui-preflight', 'build-app')))
           for name, rc in steps.items()):
        return 'FAIL'
    if any(steps.get(k) == '75' for k in ('ui-preflight', 'build-app')):
        try:
            gate = json.loads((run / 'ui-gate.json').read_text())
        except (OSError, ValueError):
            return 'FAIL'  # Exit 75 alone is not lock evidence.
        return gate['state'] if gate.get('state') in ('WAIT', 'ENV') else 'FAIL'
    return 'PASS' if steps.get('build-app') == '0' else 'RUNNING'


LABELS = {'WAIT': 'waiting: screen locked', 'ENV': 'ENV: UI run needs retry', 'FAIL': 'checks failed'}

if __name__ == '__main__':
    result = state(sys.argv[1])
    print(LABELS.get(result, result))
    sys.exit(0 if result in ('WAIT', 'ENV') else 1)
