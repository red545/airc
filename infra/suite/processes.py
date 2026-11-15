"""Track exact descendant PIDs, including subprocesses that create new sessions."""
import os
import signal
import subprocess
import time


def snapshot():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat=,lstart='], text=True, timeout=5)
    found = {}
    for row in rows.splitlines():
        fields = row.split()
        if len(fields) == 8:
            found[int(fields[0])] = (int(fields[1]), fields[2], tuple(fields[3:]))
    return found


class Descendants:
    def __init__(self, root):
        self.root = root
        self.identities = {}
        self.sampled = False
        self.sample()

    def sample(self):
        rows = snapshot()
        # Never adopt a reused PID. Birth identity persists across exec and reparenting.
        live = {pid for pid, birth in self.identities.items()
                if pid in rows and rows[pid][2] == birth and not rows[pid][1].startswith('Z')}
        if not self.sampled and self.root in rows:
            live.add(self.root)
        self.sampled = True
        while True:
            children = {pid for pid, (parent, state, birth) in rows.items()
                        if parent in live and not state.startswith('Z')
                        and (pid not in self.identities or self.identities[pid] == birth)}
            if children <= live:
                break
            live |= children
        for pid in live:
            self.identities[pid] = rows[pid][2]
        return live

    def send(self, signum):
        for pid in sorted(self.sample(), reverse=True):
            # Revalidate immediately before each exact-PID signal.
            row = snapshot().get(pid)
            if row and row[2] == self.identities[pid] and not row[1].startswith('Z'):
                try:
                    os.kill(pid, signum)
                except ProcessLookupError:
                    pass

    def stop(self):
        self.send(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while self.sample() and time.monotonic() < deadline:
            time.sleep(.1)
        if self.sample():
            self.send(signal.SIGKILL)
        deadline = time.monotonic() + 5
        while self.sample() and time.monotonic() < deadline:
            time.sleep(.1)
        remaining = self.sample()
        if remaining:
            raise RuntimeError('owned descendants remain: ' + str(sorted(remaining)))
