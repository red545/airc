#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Read only the installed build number and local appcast; cache SSH attempts for ten minutes."""
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

REMOTE = r'''
import json, pathlib, subprocess, xml.etree.ElementTree as ET
home = pathlib.Path.home()
values = {}
try:
    r = subprocess.run(['plutil', '-extract', 'CFBundleVersion', 'raw', '-o', '-', str(home/'arcfork/try/Airc-Chromium.app/Contents/Info.plist')], capture_output=True, text=True, check=True)
    value = r.stdout.strip()
    if value.isdigit(): values['installed'] = value
except Exception: pass
try:
    root = ET.parse(home/'arcfork/updates-local/appcast.xml')
    versions = [x.text for x in root.findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}version') if x.text and x.text.isdigit()]
    if versions: values['latest'] = max(versions, key=int)
except Exception: pass
print(json.dumps(values))
'''


def owner_versions(status):
    status.mkdir(parents=True, exist_ok=True)
    cache = status / 'owner-versions.json'
    with (status / '.owner-versions.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = json.loads(cache.read_text())
        except (OSError, ValueError):
            data = {}
        now = time.time()
        if now - data.get('attempted', 0) < 600:
            return data
        data['attempted'] = now
        # Persist failed attempts too: offline Macs must not get polled every cron tick.
        cache.write_text(json.dumps(data))
        # Owner installation telemetry must never silently query the build host.
        host = os.environ.get('AIRC_OWNER_MAC_HOST')
        if not host:
            return data
        try:
            result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                                     host,
                                     'python3 -c ' + shlex.quote(REMOTE)],
                                    capture_output=True, text=True, timeout=20, check=True)
            values = json.loads(result.stdout)
            data = dict(attempted=now, checked=now,
                        **{k: v for k, v in values.items() if k in ('installed', 'latest')
                           and isinstance(v, str) and v.isdigit()})
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        cache.write_text(json.dumps(data))
        return data
