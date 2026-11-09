#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Serialize Mac UI checks, including manual open -g -n -W launches.
Usage: scripts/ui-check-lock.py COMMAND [ARG...]
The lock file is permanent: unlinking a flock file lets two holders coexist.
"""
import fcntl
import os
import signal
from pathlib import Path
import subprocess
import sys
import time


def main():
    path = Path.home() / "arcfork" / ".ui-check.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    # Each launch waits at most five minutes; ship callers may also share a total budget.
    limit = min(300, max(0, float(os.environ.get("AIRC_UI_LOCK_TIMEOUT", "300"))))
    budget_path = os.environ.get("AIRC_UI_LOCK_BUDGET_FILE")
    # Full migration acceptance interleaves hundreds of launches with agent checks.
    # Keep the ordinary per-launch refusal, without exhausting one shared budget.
    if os.environ.get("AIRC_UI_LOCK_PER_LAUNCH") == "1":
        budget_path = None
    budget = Path(budget_path) if budget_path else None
    spent = float(budget.read_text()) if budget and budget.exists() else 0
    limit = min(limit, max(0, 300 - spent))
    with path.open("a+") as lock:
        def expired(_signum, _frame):
            raise TimeoutError()
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError:
            acquired = False
            if limit > 0:
                # Block in the kernel instead of polling: polling lets a rapid launcher reacquire between every
                # poll and starve an already-waiting ship run. A raising signal handler interrupts flock on macOS.
                previous = signal.signal(signal.SIGALRM, expired)
                signal.setitimer(signal.ITIMER_REAL, limit)
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    acquired = True
                except TimeoutError:
                    pass
                finally:
                    signal.setitimer(signal.ITIMER_REAL, 0)
                    signal.signal(signal.SIGALRM, previous)
        waited = time.monotonic() - started
        if budget:
            budget.write_text(str(spent + waited))
        lock.seek(0)
        holder = lock.read().strip() or "unknown"
        # Strict automation always refuses a timeout, including an exhausted ship budget.
        # Legacy callers retain their explicit opt-in until they migrate to strict mode.
        if not acquired and (os.environ.get("AIRC_UI_LOCK_STRICT") == "1" or not (budget or os.environ.get("AIRC_UI_LOCK_PROCEED") == "1")):
            print(f"UI lock: waited {waited:.2f}s; timeout, refusing; holder {holder}", flush=True)
            return 75
        print(f"UI lock: waited {waited:.2f}s; " + ("acquired" if acquired else f"timeout, proceeding; holder {holder}"), flush=True)
        if acquired:
            lock.seek(0)
            lock.truncate()
            lock.write(f"pid={os.getpid()} since={time.time():.0f}")
            lock.flush()
        # Keep the descriptor open in the child: if this wrapper dies, the still-running check retains the lock.
        # A timeout alone does not excuse assertions: checks must collect their own interference evidence.
        return subprocess.call(sys.argv[1:], pass_fds=(lock.fileno(),))


if __name__ == "__main__":
    sys.exit(main())
