#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Keep every distinct failed XCTest case and the last three diagnostic/summary lines."""
from collections import deque
import re
import sys

FAILED = re.compile(r"Test Case '.+' failed")


def summarize(lines):
    failures = set()
    tail = deque(maxlen=3)
    for line in lines:
        line = line.rstrip('\n')
        if FAILED.search(line):
            if line not in failures:
                failures.add(line)
                yield line
        elif re.search(r'error|failed|Executed [0-9]+ tests', line):
            tail.append(line)
    yield from tail


if __name__ == '__main__':
    for line in summarize(sys.stdin):
        print(line, flush=True)
