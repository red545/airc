#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Summarize two private feature reports without copying paths or URLs into the repo."""
import json
import math
import statistics
import sys

result = {}
for label, path in zip(('dev', 'release'), sys.argv[1:], strict=True):
    report = json.load(open(path))
    assert report['ok'], report['error']
    evidence = report['profiles']
    frames = sorted(evidence['resizeFrameCPUms'])
    result[label] = {
        'resizeFrames': len(frames),
        'resizeCPUms': {
            'median': round(statistics.median(frames), 3),
            'p95': round(frames[math.ceil(len(frames) * .95) - 1], 3),
            'max': round(max(frames), 3),
        },
        'resizeObserverNotifications': [evidence[f'pane{i}Resize']['count'] for i in range(4)],
        'peekOpenCPUms': round(evidence['peekOpenCPUms'], 3),
        'moveCPUms': round(evidence['moveCPUms'], 3),
        'videoTimeBeforeMove': evidence['mediaBeforeMove'],
        'videoTimeAfterMove': evidence['promotedState']['time'],
        'scrollBeforeMove': evidence['scrollBeforeMove'],
        'scrollAfterMove': evidence['promotedState']['scroll'],
        'locked': evidence['screenLocked'],
    }
print(json.dumps(result, indent=2))
