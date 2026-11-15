#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Build and run webkit-probe.swift (ad-hoc signed, its own bundle ID) on a loopback page under the UI lock.
Usage: run-webkit.py NEW_OUTPUT. Prints the probe's JSON report.
"""
import http.server
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import threading
from functools import partial

here = pathlib.Path(__file__).resolve().parent
repo = here.parents[2]
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir()  # Refuse reuse.
app = out / 'AircWebKitPasskeyProbe.app'
(app / 'Contents/MacOS').mkdir(parents=True)
subprocess.run(['xcrun', 'swiftc', '-O', str(here / 'webkit-probe.swift'), '-o',
                str(app / 'Contents/MacOS/AircWebKitPasskeyProbe')], check=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'AircWebKitPasskeyProbe', 'CFBundleIdentifier': 'org.airc.test.passkeys-webkit',
    'CFBundleName': 'AircWebKitPasskeyProbe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSPrincipalClass': 'NSApplication'}))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
server = http.server.HTTPServer(('127.0.0.1', 0), partial(http.server.SimpleHTTPRequestHandler, directory=str(here)))
threading.Thread(target=server.serve_forever, daemon=True).start()
report = out / 'result.json'
env = {k: v for k, v in os.environ.items() if k not in ('AIRC_UI_LOCK_PROCEED', 'AIRC_UI_LOCK_BUDGET_FILE')}
try:
    proc = subprocess.run([sys.executable, str(repo / 'scripts/ui-check-lock.py'), 'open', '-n', '-W', str(app),
                           '--args', f'http://localhost:{server.server_port}/fixture.html', str(report)],
                          timeout=400, env=env)
    if proc.returncode and not report.exists():
        raise SystemExit(f'UI launcher refused or failed: {proc.returncode}')
    result = json.loads(report.read_text())
    print(json.dumps(result, indent=2, sort_keys=True))
finally:
    server.shutdown()
    if report.exists():
        pid = json.loads(report.read_text()).get('pid')
        exe = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
        if pid and exe.endswith('AircWebKitPasskeyProbe'):
            subprocess.run(['kill', '-TERM', str(pid)], check=False)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/'
                    'lsregister', '-u', str(app)], check=False, capture_output=True)
