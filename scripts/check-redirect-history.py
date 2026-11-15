#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""After the redirects scenario quits, verify Chromium's actual persisted server-redirect chains.

Navigation Timing intentionally hides some cross-site hops. Read only this synthetic
scenario's scratch profile; never search a user's browser directories.
"""
import json
from pathlib import Path
import sqlite3
import sys
from urllib.parse import urlsplit

data, evidence = map(Path, sys.argv[1:3])
output = Path(sys.argv[3]) if len(sys.argv) > 3 else evidence.with_name('redirect-history.json')
cases = json.loads(evidence.read_text())
databases = list((data / 'Chromium').rglob('History'))
assert len(databases) == 1, f'expected one synthetic Chromium History, got {len(databases)}'
db = sqlite3.connect('file:' + str(databases[0].resolve()) + '?mode=ro', uri=True)
assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
passed = True
results = []
for case in cases:
    expected = case.get('expectedHistory', [])
    if not expected:
        continue
    latest = db.execute('SELECT v.id FROM visits v JOIN urls u ON u.id=v.url WHERE u.url=? ORDER BY v.visit_time DESC LIMIT 1', (case['final'],)).fetchone()
    chain = []
    transitions = []
    visit = latest[0] if latest else None
    seen = set()
    while visit is not None and visit not in seen and len(chain) < 30:
        seen.add(visit)
        row = db.execute('SELECT u.url,v.from_visit,v.transition FROM visits v JOIN urls u ON u.id=v.url WHERE v.id=?', (visit,)).fetchone()
        if row is None:
            break
        url, previous, transition = row
        chain.insert(0, url)
        transitions.insert(0, transition & 0xffffffff)
        if transition & 0x10000000:  # PAGE_TRANSITION_CHAIN_START
            break
        visit = previous
    details = {}
    if case['name'].endswith(' POST303'):
        # Chromium deliberately omits the submitted POST URL from History. Its
        # real redirect is proved by the page timing and server method trace;
        # History must contain only one final GET and no submitted URL at all.
        send_url, final_url = expected
        send_path, final_path = urlsplit(send_url).path, urlsplit(final_url).path
        expected_requests = [dict(method='POST', path=send_path, target=send_path),
                             dict(method='GET', path=final_path, target=final_path)]
        final_visits = db.execute('SELECT count(*) FROM visits v JOIN urls u ON u.id=v.url WHERE u.url=?', (final_url,)).fetchone()[0]
        send_entries = db.execute('SELECT count(*) FROM urls WHERE url=?', (send_url,)).fetchone()[0]
        mode = case['name'].split()[0]
        browser_assertion = f'PASS redirects: {mode} 303 changes POST to GET and lands exactly once'
        log_lines = evidence.with_name('log.txt').read_text().splitlines()
        details = dict(serverTrace=case.get('requests') == expected_requests,
                       browserCount=case.get('navigationRedirectCount'),
                       browserFinalAsserted=log_lines.count(browser_assertion) == 1,
                       nativeFinalVisits=final_visits, nativeSendEntries=send_entries)
        good = (details['serverTrace'] and details['browserCount'] == 1 and
                details['browserFinalAsserted'] and case['final'] == final_url and
                final_path.endswith('/post/final') and chain == [final_url] and
                final_visits == 1 and send_entries == 0)
        message = 'POST→GET exactly once, one browser redirect, one native final GET and no POST URL'
    else:
        good = chain == expected
        message = f'exactly {len(expected)-1} native redirect(s)'
    passed &= good
    result = {'name': case['name'], 'expected': expected, 'actual': chain, 'transitions': transitions, 'checks': details, 'passed': good}
    results.append(result)
    print(('PASS' if good else 'FAIL') + ' redirects native History: ' + case['name'] + ': ' + message + '; actual=' + json.dumps(chain))
assert len(results) == 6, 'missing ON/OFF chain, cross-site or POST303 evidence'
output.write_text(json.dumps({'passed': passed, 'cases': results}, indent=2) + '\n')
raise SystemExit(0 if passed else 1)
