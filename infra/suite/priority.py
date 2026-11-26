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


PATIENCE = int(os.environ.get('AIRC_SUITE_PATIENCE', 20 * 60))      # yield to queued peers this long
GIVE_UP = int(os.environ.get('AIRC_SUITE_GIVE_UP', 4 * 3600))         # then stop the attempt (resumable)
POLL = 2.0


def admit(lock, tick=lambda: None, patience=None, give_up=None, clock=time.monotonic, sleep=time.sleep):
    """Lowest priority with bounded starvation (fastgate2, 26 Nov).

    Before: any queued peer aborted the whole attempt at once, and agents queue for the build and UI locks almost
    all the time, so no run finished after 13 Nov (379 restarts on 26 Nov alone). Now the suite waits in place,
    calling tick() every POLL seconds (the coordinator lease and hold markers; it raises to stop). It never takes
    the lock while a peer is queued, for up to `patience` seconds. After that it takes the lock as soon as it is
    free, like any other waiter. It never blocks in the kernel queue, so tick keeps running. It gives up only
    after `give_up`. The run then resumes from its checkpoint."""
    patience = PATIENCE if patience is None else patience
    give_up = GIVE_UP if give_up is None else give_up
    start = clock()
    while True:
        tick()
        waited = clock() - start
        starved = waited >= patience
        if starved or not contenders(lock.name):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                try:
                    # a peer that queued while we acquired still goes first, until we are starved
                    if starved or not contenders(lock.name):
                        return waited
                except BaseException:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    raise
                fcntl.flock(lock, fcntl.LOCK_UN)
        if waited >= give_up:
            raise InterruptedError(f'lock not free for {int(waited)} s: ' + str(lock.name))
        sleep(POLL)


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
