#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Check that every active upstream path has a rationale and seam assessment."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent
manifest = json.loads((root / 'manifest.json').read_text())
series = (root / 'series').read_text()
for name in manifest:
    assert f'# FILE {name} | ' in series, f'Missing per-file audit: {name}'
for line in series.splitlines():
    if line.startswith('# FILE '):
        name, reason, seam = line[7:].split(' | ')
        assert name in manifest and reason and seam.startswith('Seam:'), line
print(f'PASS {len(manifest)} active upstream paths have a reason and seam assessment')
