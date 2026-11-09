#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Validate scratch dev-publish storage and prove the service serves that root."""
from pathlib import Path
import re
import sys
import time
from urllib.parse import urljoin
from urllib.request import urlopen
import uuid


def storage_root(value, home=None):
    home = Path.home() if home is None else home
    root = Path(value)
    parent = home / 'arcfork/setup/automation'
    if (not root.is_absolute() or '..' in root.parts or root.parent != parent
            or not re.fullmatch(r'feed-[A-Za-z0-9_-]+', root.name)
            or root.resolve() != root):
        raise ValueError('scratch publication requires an absolute, non-symlink setup/automation/feed-NAME root')
    return root


def probe(feed, url, attempts=10):
    token = uuid.uuid4().hex
    marker = feed / ('.health-' + token)
    marker.write_text(token)
    try:
        for attempt in range(attempts):
            try:
                with urlopen(urljoin(url, marker.name), timeout=2) as response:
                    if response.read().decode() == token:
                        return
            except OSError:
                pass
            if attempt + 1 < attempts:
                time.sleep(.5)
        raise ValueError('scratch feed URL does not serve the selected scratch directory')
    finally:
        marker.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--probe':
            feed = Path(sys.argv[2])
            root = storage_root(str(feed.parent))
            if feed != root / 'feed':
                raise ValueError('unexpected scratch feed path')
            probe(feed, sys.argv[3])
        elif len(sys.argv) == 2:
            print(storage_root(sys.argv[1]))
        else:
            raise ValueError('expected ROOT, or --probe FEED URL')
    except (OSError, ValueError) as error:
        sys.exit(str(error))
