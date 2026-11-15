"""Observe slow quits without suppressing unrelated gate failures."""
import copy
import json
import os
from pathlib import Path
import re
import time

SLOW = re.compile(r'^SLOW-QUIT \S+: still quitting ([0-9.]+) s after the check finished')


class ShutdownObservation:
    def __init__(self, snapshot, evidence):
        self.log = Path(snapshot) / 'log.txt'
        self.before = self.log.read_text(errors='replace') if self.log.exists() else ''
        self.evidence = Path(evidence)
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.stderr = self.evidence / 'app.stderr'
        self.events = []
        self.seen = set()

    def sample(self):
        before_count = len(self.events)
        for source, path in (('log', self.log), ('stderr', self.stderr)):
            text = path.read_text(errors='replace') if path.exists() else ''
            if source == 'log' and text.startswith(self.before):
                text = text[len(self.before):]
            for i, line in enumerate(text.splitlines()):
                match = SLOW.match(line) if source == 'log' else None
                teardown = source == 'stderr' and 'Teardown watchdog expired' in line
                key = (source, i, line)
                if key in self.seen or not (match or teardown):
                    continue
                self.seen.add(key)
                try:
                    load = os.getloadavg()[0]
                except OSError:
                    load = None
                self.events.append(dict(kind='slow-quit' if match else 'teardown-watchdog',
                    seconds=float(match[1]) if match else None, message=line,
                    observed_at=time.time(), load_1m=load, cores=os.cpu_count(), source=source))
        output = self.evidence / 'shutdown.json'
        if len(self.events) != before_count or not output.exists():
            output.write_text(json.dumps(dict(events=self.events), indent=2) + '\n')


def severe(event):
    return event['kind'] == 'teardown-watchdog' or (event.get('seconds') or 0) >= 9.5


def gate_inputs(receipt, worker_exit, events, engine):
    """Only the proved Chromium teardown exit itself may become a warning.

    Preserve raw logs/receipts, assertions, watchdogs, environment errors and
    unrelated nonzero exits. open -W normally reports zero even for app exit 2.
    """
    if engine != 'chromium' or not any(e['kind'] == 'teardown-watchdog' for e in events):
        return receipt, worker_exit
    receipt = copy.deepcopy(receipt)
    changed = False
    for launch in receipt.get('launches', []):
        failures = launch.get('failures', [])
        retained = [f for f in failures if f.get('message') != 'launcher exit 2']
        if len(retained) != len(failures):
            changed = True
            launch['failures'] = retained
            if not retained and launch.get('state') == 'FAIL' and not launch.get('watchdog'):
                launch['state'] = 'ENV' if launch.get('errors') else 'PASS'
    states = [x.get('state') for x in receipt.get('launches', [])]
    if changed and states and receipt.get('state') == 'FAIL':
        receipt['state'] = ('FAIL' if 'FAIL' in states else
                            'ENV' if receipt.get('errors') or any(s != 'PASS' for s in states) else 'PASS')
    return receipt, 0 if changed and worker_exit == 2 else worker_exit


def apply_policy(result):
    """Count severe quits once per case, including across checkpoint resumes."""
    cases = result['cases']
    occurrences = sum(any(severe(e) for e in c.get('shutdown_events', [])) for c in cases)
    warnings = []
    for case in cases:
        events = case.get('shutdown_events', [])
        reasons = []
        for event in events:
            reason = None
            if severe(event):
                if event.get('load_1m') is None or not event.get('cores'):
                    reason = 'load evidence unavailable'
                elif event['load_1m'] < event['cores']:
                    reason = '1-minute load below core count'
                elif occurrences >= 3:
                    reason = '3 or more severe quits in this full run'
            if reason:
                reasons.append(reason)
            warnings.append(dict(event, case=case['id'], engine=case['engine'],
                                 severity='RED' if reason else 'WARNING', reason=reason))
        if events:
            case.setdefault('gate_state', case['state'])
            case.setdefault('gate_critical', case.get('critical', False))
            case['state'] = 'FAIL' if reasons else case['gate_state']
            case['critical'] = bool(reasons) or case['gate_critical']
            case['shutdown_red_reasons'] = sorted(set(reasons))
    result['shutdown_warnings'] = warnings
    result['severe_quit_occurrences'] = occurrences
