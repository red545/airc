#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Drawn-window gate. 75 = waiting/ENV (retry, never publish), 1 = real failure.

Each launch is sampled AFTER acquiring the shared UI lock. Preserve raw logs; store
classified failures and UTC lock intervals in ui-gate.json. Lock times are first
observations (a lower bound), not a claim to know when the owner pressed Lock.
Independent assertions in UI scenarios can use `FAIL [independent] ...`; engine
failures, unit failures, crashes and missing scenario logs are always red.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import threading
import time

RETRY = 75
FAILURE = re.compile(r'^(?:\s*\[(?:chromium|webkit|snapshot)\]\s*)?(FAIL(?:-ENV|-INDEPENDENT)?|ENGINE-FAIL) (.*)$')
INDEPENDENT = re.compile(r'^(?:unit|model|serialization):|\[independent\]|\b(?:unit[- ](?:test|level)|XCTAssert|assertion failed|precondition failed|crashed|never started|wrote no log|no log \(crashed)', re.I)
DRAWING = re.compile(r'^click .*: not on screen$|^no sheet to press |^the sheet has no .* button$|^\w[\w-]*: timed out after \d+ s')
LEGACY_LOCK = re.compile(r'\b(?:the screen is locked|screen locked true|screen locked;)')


def utc(t):
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec='milliseconds')


def screen_locked():
    # Do not log IOConsoleUsers: it also contains the owner's identity.
    result = subprocess.run(['ioreg', '-a', '-n', 'Root', '-d1'], capture_output=True, timeout=5, check=True)
    def sessions(value):
        if isinstance(value, dict):
            if 'IOConsoleUsers' in value:
                return value['IOConsoleUsers']
            for child in value.values():
                found = sessions(child)
                if found is not None:
                    return found
        if isinstance(value, list):
            for child in value:
                found = sessions(child)
                if found is not None:
                    return found
        return None
    users = sessions(plistlib.loads(result.stdout))
    if not users:
        raise ValueError('no console session in lock probe')
    return any(user.get('CGSSessionScreenIsLocked') is True for user in users)



class Observation:
    def __init__(self):
        self.intervals = []
        self.errors = []
        self.locked = False

    def sample(self):
        now = time.time()
        try:
            locked = screen_locked()
        except Exception as error:
            self.errors.append(f'{utc(now)}: lock probe unavailable ({type(error).__name__})')
            return None
        if locked:
            if not self.locked:
                self.intervals.append(dict(start=utc(now), end=utc(now), seconds=0, _start=now))
            interval = self.intervals[-1]
            interval.update(end=utc(now), seconds=round(now - interval['_start'], 3))
        self.locked = locked
        return locked

    def evidence(self):
        return [{k: v for k, v in item.items() if k != '_start'} for item in self.intervals]


def classify(text, intervals=(), legacy=False):
    """Only a launch with lock evidence may excuse drawing failures.

    Historic logs have no timestamps: replay only recognized drawn-window errors,
    leaving unknown failures red. Never manufacture timing for those old logs.
    """
    evidence = list(intervals)
    if legacy and LEGACY_LOCK.search(text):
        evidence = [dict(start=None, end=None, seconds=None, source='historic log: timing unavailable')]
    failures = []
    observed = None
    for line in text.splitlines():
        sample = re.fullmatch(r'UI-FAIL-STATE ([0-9.]+) (locked|unlocked)', line)
        if sample:
            observed = dict(time=float(sample[1]), locked=sample[2] == 'locked')
            continue
        match = FAILURE.match(line)
        if not match:
            continue
        kind, message = match.groups()
        independent = kind in ('ENGINE-FAIL', 'FAIL-INDEPENDENT') or INDEPENDENT.search(message)
        # A failure observed before this launch's first lock remains red. The app
        # supplies this marker because scenario logs are otherwise buffered until quit.
        first_lock = min((datetime.fromisoformat(x['start'].replace('Z', '+00:00')).timestamp() for x in evidence if x.get('start')), default=float('inf'))
        unlocked_before_lock = observed and not observed['locked'] and observed['time'] < first_lock
        failure_evidence = evidence
        if observed and observed['locked'] and not evidence:
            failure_evidence = [dict(start=utc(observed['time']), end=utc(observed['time']), seconds=0,
                                     source='SnapshotRunner failure observation')]
        environmental = not independent and (kind == 'FAIL-ENV' or (failure_evidence and not unlocked_before_lock and (not legacy or DRAWING.search(message))))
        failures.append(dict(kind='FAIL-ENV' if environmental else 'FAIL', message=message,
                             locks=failure_evidence if environmental else [], observed=observed))
        observed = None
    # Preserve the existing policy for non-lock FAIL-ENV (e.g. clipboard contention).
    # Only proven lock exposure invalidates an otherwise-green UI gate here.
    locked_failure = any(f['kind'] == 'FAIL-ENV' and LEGACY_LOCK.search(f['message']) for f in failures)
    state = 'FAIL' if any(f['kind'] == 'FAIL' for f in failures) else (
        'ENV' if evidence or locked_failure or any(f['locks'] for f in failures) else 'PASS')
    return dict(state=state, failures=failures, locks=evidence)


def save(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def result_code(data):
    return 1 if data['state'] == 'FAIL' else RETRY if data['state'] in ('ENV', 'WAIT') else 0


def summarize(data):
    states = [launch['state'] for launch in data['launches']]
    data['state'] = 'FAIL' if 'FAIL' in states else 'ENV' if 'ENV' in states else 'PASS'
    return data


def preflight(path):
    observation = Observation()
    locked = observation.sample()
    data = dict(state='WAIT' if locked else 'ENV' if locked is None else 'PASS',
                reason='waiting: screen locked' if locked else 'lock probe unavailable' if locked is None else '',
                locks=observation.evidence(), errors=observation.errors, launches=[])
    save(path, data)
    print(data['reason'] or 'UI gate: screen unlocked', flush=True)
    return result_code(data)


def launch(path, command):
    data = json.loads(path.read_text())
    observation = Observation()
    locked = observation.sample()
    # Check again inside ui-check-lock.py: the screen may lock during its wait.
    if os.environ.get('AIRC_SHIP_GATE') == '1' and locked is not False:
        prior_failure = any(x['state'] == 'FAIL' for x in data['launches'])
        data.update(state='FAIL' if prior_failure else 'ENV' if data['launches'] or locked is None else 'WAIT',
                    reason='waiting: screen locked' if locked else 'lock probe unavailable',
                    locks=data['locks'] + observation.evidence(), errors=observation.errors)
        save(path, data)
        print(data['reason'], flush=True)
        return result_code(data)
    script = command[command.index('--script') + 1]
    out = Path(command[command.index('--snapshot') + 1]) / 'log.txt'
    before = out.read_text(errors='replace') if out.exists() else ''
    stop = threading.Event()
    def monitor():
        while not stop.wait(0.5):
            observation.sample()
    watcher = threading.Thread(target=monitor)
    watcher.start()
    started = utc(time.time())
    try:
        # Retain the UI-lock fd inherited from ui-check-lock.py through open -W.
        rc = subprocess.call(command, close_fds=False)
    finally:
        stop.set()
        watcher.join()
        observation.sample()
    after = out.read_text(errors='replace') if out.exists() else ''
    new = after[len(before):] if after.startswith(before) else after
    if f'[{script}]' not in new:
        new += f'\nFAIL {script}: the app wrote no log (crashed or never started)\n'
    result = classify(new, observation.evidence())
    if rc:
        result['state'] = 'FAIL'
        result['failures'].append(dict(kind='FAIL', message=f'launcher exit {rc}', locks=[]))
    if observation.errors and result['state'] == 'PASS':
        result['state'] = 'ENV'  # Cannot prove this launch was unlocked; never publish it.
    result.update(script=script, start=started, end=utc(time.time()), errors=observation.errors)
    data['launches'].append(result)
    save(path, summarize(data))
    # Finish the suite so independent failures still surface; final gate returns 75/1.
    return rc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('preflight', 'launch', 'finish', 'replay'))
    parser.add_argument('path', type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'preflight':
        return preflight(args.path)
    if args.action == 'launch':
        return launch(args.path, args.command)
    if args.action == 'replay':
        data = classify(args.path.read_text(errors='replace'), legacy=True)
    else:
        data = json.loads(args.path.read_text())
        if not data['launches'] and data['state'] == 'PASS':
            data.update(state='FAIL', reason='no UI scenarios ran')
            save(args.path, data)
    print(json.dumps(data, indent=2))
    return result_code(data)


if __name__ == '__main__':
    sys.exit(main())
