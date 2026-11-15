"""Lowest-priority lock admission and persistent overnight fallback."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def contenders(path):
    """Mac has no lslocks: conservatively count any other open lock descriptor."""
    if sys.platform == 'darwin':
        p = subprocess.run(['/usr/sbin/lsof', '-t', str(path)], capture_output=True, text=True, timeout=10)
        if p.returncode not in (0, 1) or (p.returncode == 1 and p.stderr.strip()):
            raise RuntimeError('cannot inspect Mac lock contenders: ' + p.stderr)
        return [int(pid) for pid in p.stdout.split() if int(pid) != os.getpid()]
    p = subprocess.run(['lslocks', '--json', '-o', 'PID,MODE,PATH'], capture_output=True,
                       text=True, check=True, timeout=10)
    return [row['pid'] for row in json.loads(p.stdout).get('locks', [])
            if row.get('path') == str(Path(path).resolve()) and row['pid'] != os.getpid()
            and row.get('mode', '').endswith('*')]


def admit(lock):
    # Never join the blocking queue. Check both sides of acquisition to avoid
    # overtaking an already queued peer when its holder releases the lock.
    if contenders(lock.name):
        raise InterruptedError('peer lock waiter: ' + str(lock.name))
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise InterruptedError('peer lock holder: ' + str(lock.name)) from None
    try:
        if contenders(lock.name):
            raise InterruptedError('peer lock waiter after acquisition: ' + str(lock.name))
    except BaseException:
        fcntl.flock(lock, fcntl.LOCK_UN)
        raise


def deferred(status, reason, now=None):
    path = status / 'suite/low-priority.json'
    now = time.time() if now is None else now
    data = json.loads(path.read_text()) if path.exists() else {'since': now}
    data.update(reason=reason, updated_at=now)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data) + '\n'); temp.replace(path)


def progressed(status):
    (status / 'suite/low-priority.json').unlink(missing_ok=True)


def night_hold(status, now=None):
    path = status / 'suite/low-priority.json'
    if not path.exists():
        return False
    now = time.time() if now is None else now
    age = now - json.loads(path.read_text())['since']
    hour = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).hour
    return age >= 6 * 3600 and hour >= 6
