#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Validate a complete fast-gate receipt without implying full-suite qualification."""
import hashlib
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]

def verify(path, revision):
    config_path = ROOT/'infra/release/fast-gate.json'
    config = json.loads(config_path.read_text())
    r = json.loads(Path(path).read_text())
    if r.get('schema') != 1 or r.get('state') != 'PASS' or r.get('revision') != revision:
        raise ValueError('Fast gate failed or covers another cut')
    if not re.fullmatch('[0-9a-f]{40}', revision): raise ValueError('Full frozen source hash required')
    if r.get('config_sha256') != hashlib.sha256(config_path.read_bytes()).hexdigest():
        raise ValueError('Fast gate inventory changed')
    if r.get('crash_reports') != [] or r.get('driver_unchanged') is not True:
        raise ValueError('Crash audit or driver identity failed')
    seconds=r.get('seconds')
    if type(seconds) not in (float,int) or not math.isfinite(seconds) or not 0 < seconds <= config['maximum_seconds']:
        raise ValueError('Fast gate wall time missing or over limit')
    expected={(engine,c['script']): c for engine in config['engines'] for c in config['cases'] if engine in c.get('engines',config['engines'])}
    rows=r.get('cases',[])
    if len(rows)!=len(expected) or {(c.get('engine'),c.get('script')) for c in rows}!=set(expected):
        raise ValueError('Missing, duplicate or unexpected case')
    for c in rows:
        if c.get('state')!='PASS' or c.get('error') or c.get('cleanup')!={} or not c.get('pids'):
            raise ValueError('Case failed or needed termination')
        if not all(type(pid)==int and pid>0 for pid in c['pids']): raise ValueError('Invalid PID evidence')
        if c.get('exit_statuses')!={str(pid):0 for pid in c['pids']}:
            raise ValueError('Missing clean process-exit evidence')
        t=c.get('seconds')
        if type(t) not in (float,int) or not math.isfinite(t) or not 0<t<=expected[c['engine'],c['script']]['timeout_seconds']:
            raise ValueError('Case exceeded its hard timeout')
    return r

if __name__=='__main__':
    r=verify(sys.argv[1],sys.argv[2])
    print(f"PASS fast gate: {len(r['cases'])} launches, {r['seconds']} seconds; full suite separate")
