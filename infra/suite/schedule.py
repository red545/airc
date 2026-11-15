#!/usr/bin/env python3
"""Bootstrap then full qualification, executing only a dedicated origin checkout."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import signal
import sys
import time
from checkout import command
from priority import night_hold, deferred
from checkpoint import Checkpoints
from run import HOLD, Preempted, order_ready, save, stop


def wait_ready(status, queue, sleep=time.sleep):
    """Wait without any Mac/build/UI lock; expose holds even before an attempt."""
    while True:
        Checkpoints(status / 'suite').expire()
        reasons = [name for name in HOLD if (status / name).exists()]
        if reasons:
            deferred(status, ', '.join(reasons))
        if night_hold(status):
            reasons.append('starved-six-hours: waiting for 00:00–06:00 UTC')
        try:
            if not order_ready(queue):
                reasons.append('post-release-order')
        except (ValueError, OSError):
            reasons.append('post-release-order')
        if not (status / 'buildmac-engine-ready').exists():
            reasons.append('buildmac-engine-ready')
        save(status / 'suite/scheduler.json', dict(
            state='waiting' if reasons else 'starting', waiting_on=reasons, updated_at=time.time()))
        if not reasons:
            return
        print('Suite held: ' + ', '.join(reasons), flush=True)
        sleep(60)


def invoke(args):
    child = subprocess.Popen(args, stdin=subprocess.DEVNULL)
    try:
        return child.wait()
    except (Preempted, InterruptedError):
        child.terminate()
        try:
            child.wait(timeout=75)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        raise


def main():
    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True, help='exclusively owned run checkout')
    parser.add_argument('--remote', required=True)
    parser.add_argument('--status', type=Path, required=True)
    parser.add_argument('--queue', type=Path, required=True)
    a = parser.parse_args()
    a.status.mkdir(parents=True, exist_ok=True)
    with (a.status / '.bgsuite-scheduler.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 75
        proof = a.status / 'suite/bootstrap.json'
        args = ['--status', str(a.status), '--queue', str(a.queue)]
        wait_ready(a.status, a.queue)
        if not proof.exists():
            rc = invoke(command(a.repo, a.remote, [*args, '--dry-run']))
            latest = a.status / 'suite/latest.json'
            if rc or not latest.exists():
                return rc or 75
            receipt = json.loads(latest.read_text())
            if receipt['state'] != 'complete' or not receipt['dry_run'] or len(receipt['cases']) != 6:
                return 75
            # A bootstrap is orchestration evidence only, never qualification.
            proof.write_text(json.dumps(receipt, indent=2) + '\n')
            wait_ready(a.status, a.queue)
        rc = invoke(command(a.repo, a.remote, args))
        save(a.status / 'suite/scheduler.json', dict(
            state='finished' if rc == 0 else 'retrying', exit_code=rc,
            retry_after_seconds=60 if rc else None, updated_at=time.time()))
        latest = a.status / 'suite/latest.json'
        if latest.exists():
            receipt = json.loads(latest.read_text())
            report = a.status.parent / 'artifacts/bgsuite/REPORT.md'
            if report.exists():
                with report.open('a') as out:
                    out.write('\n## Scheduler result\n\n' + json.dumps({k: receipt.get(k) for k in
                        ('revision', 'state', 'dry_run', 'counts', 'critical', 'qualified', 'reason', 'logs')}, indent=2) + '\n')
        return rc

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Preempted, InterruptedError):
        sys.exit(75)
