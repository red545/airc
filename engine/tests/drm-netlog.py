#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Inspect ONLY isolated DRM NetLogs (include sensitive headers); never owner logs."""
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse
WV = 'oimompecagnajdejgnnjijobebaeigek'
CRL = 'hfnkpimlhhgieaddgfemjhofmfblmnib'
for name in sys.argv[1:]:
    path = Path(name)
    log = json.loads(path.read_text())
    types = {v: k for k, v in log['constants']['logEventTypes'].items()}
    urls = [e.get('params', {}).get('url', '') for e in log['events']
            if types[e['type']] == 'URL_REQUEST_START_JOB']
    urls = [u for u in urls if u]
    ids = set()
    for event in log['events']:
        kind = types[event['type']]
        if kind not in ('HTTP_TRANSACTION_SEND_REQUEST_HEADERS', 'HTTP2_SESSION_SEND_HEADERS', 'HTTP3_HEADERS_SENT'):
            continue
        headers = event.get('params', {}).get('headers', [])
        if isinstance(headers, str): headers = headers.splitlines()
        for header in headers:
            if header.lower().startswith('x-goog-update-appid:'):
                ids.update(re.findall(r'[a-p]{32}', header.split(':', 1)[1]))
    packages = [u for u in urls if '.crx' in urlparse(u).path]
    widevine = [u for u in packages if WV in u]
    print(json.dumps({'file': path.name, 'checkedComponentIDs': sorted(ids),
                      'widevineDownloads': widevine,
                      'componentDownloads': packages}, indent=2))
    assert ids, 'Missing update request headers; keep host alive past first update timer'
    assert all(u.startswith('https://') for u in widevine), 'insecure Widevine payload'
    if path.name.startswith(('off', 'default-on')):
        assert CRL in ids, 'CRLSet was not checked'
    if path.name.startswith('off'):
        assert WV not in ids and not widevine, 'Widevine network request while off'
    else:
        assert WV in ids, 'Widevine was not checked'
