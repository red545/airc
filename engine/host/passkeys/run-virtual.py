#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Run the ad-hoc passkey host on loopback TLS under the shared UI lock.
Usage: run-virtual.py APP NEW_OUTPUT. Build with AIRC_HOST_SOURCE=.../main.mm.
"""
import base64
import hashlib
import json
import os
import pathlib
import ssl
import subprocess
import sys
import threading
import http.server
from functools import partial
app = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
out.mkdir()  # Refuse reuse of profiles/results.
(out / 'data' / 'Chromium').mkdir(parents=True)
cert, key = out / 'cert.pem', out / 'key.pem'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
               '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
               '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
pub = subprocess.run(['openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'], check=True, capture_output=True).stdout
der = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=pub, check=True, capture_output=True).stdout
spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
server = http.server.HTTPServer(('127.0.0.1', 0), partial(http.server.SimpleHTTPRequestHandler,
    directory=str(pathlib.Path(__file__).parent)))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
repo = pathlib.Path(__file__).resolve().parents[3]
command = [sys.executable, str(repo/'scripts/ui-check-lock.py'), 'open', '-g', '-n', '-W',
    '--stdout', str(out/'app.log'), '--stderr', str(out/'app.log'), str(app), '--args',
    f'--user-data-dir={out}/data/Chromium', f'--airc-data-dir={out}/data',
    '--use-mock-keychain', '--airc-test=passkeys',
    f'--url=https://localhost:{server.server_port}/fixture.html',
    f'--ignore-certificate-errors-spki-list={spki}', f'--report={out}/result.json', f'--pid={out}/pid']
try:
    # Never inherit the ship suite's permission to proceed without the UI lock.
    env = {k: v for k, v in os.environ.items()
           if k not in ('AIRC_UI_LOCK_PROCEED', 'AIRC_UI_LOCK_BUDGET_FILE')}
    proc = subprocess.run(command, timeout=375, env=env)
    if proc.returncode:
        raise RuntimeError(f'UI launcher refused or failed: {proc.returncode}')
    result = json.loads((out/'result.json').read_text())
    print(json.dumps(result, indent=2))
    if not result['passed']:
        raise RuntimeError('virtual passkey check failed')
finally:
    server.shutdown()
    # Kill only this fixture's recorded executable if it outlived the check.
    if (out/'pid').exists():
        pid = int((out/'pid').read_text())
        executable = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
        if executable == str(app/'Contents/MacOS/AircHost'):
            subprocess.run(['kill', '-TERM', str(pid)], check=False)
    key.unlink(missing_ok=True)
