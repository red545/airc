#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Archive positively identified test crashes; unknown and owner reports stay put."""
import argparse
from datetime import date
import json
from pathlib import Path
import shutil
import uuid

OWNERS = {'org.airc.Airc.dev', 'com.aircbrowser.Airc'}
SCRATCH = ('org.airc.crashvis', 'org.airc.fscrash', 'org.airc.fsexit', 'org.airc.scratch')


def test_report(header, body, work):
    ids = {header.get('bundleID', ''), body.get('bundleInfo', {}).get('CFBundleIdentifier', '')}
    if ids & OWNERS:
        return False
    if any(i == prefix or i.startswith(prefix + '.')
           for i in ids for prefix in ('org.airc.Airc.test', *SCRATCH)):
        return True
    name = header.get('app_name', '')
    path = body.get('procPath', '')
    # A redacted/unknown path is not evidence of a scratch copy.
    return (name.startswith('Airc') and name != 'Airc'
            and path.startswith(str(work) + '/')
            and '/Contents/MacOS/' in path)


def archive(source, destination, work):
    counts = dict(moved=0, kept=0, unreadable=0)
    for path in sorted(source.glob('*.ips')):
        if path.is_symlink():
            counts['kept'] += 1
            continue
        try:
            with path.open() as stream:
                header = json.loads(stream.readline())
                body = json.load(stream)
            if not test_report(header, body, work):
                counts['kept'] += 1
                continue
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / path.name
            if target.exists():
                target = destination / (path.stem + '-' + uuid.uuid4().hex + '.ips')
            shutil.move(str(path), str(target))
            counts['moved'] += 1
        except (OSError, ValueError, TypeError, AttributeError):
            counts['unreadable'] += 1
    return counts


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path.home()/'Library/Logs/DiagnosticReports')
    parser.add_argument('--archive', type=Path, default=Path.home()/'arcfork/diag-archive'/date.today().isoformat())
    parser.add_argument('--work', type=Path, default=Path.home()/'arcfork/work')
    args = parser.parse_args()
    counts = archive(args.source, args.archive, args.work)
    print('Crash hygiene: ' + ', '.join(f'{key}={value}' for key, value in counts.items()))
