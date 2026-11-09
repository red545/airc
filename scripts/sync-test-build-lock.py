#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Refuse a busy build host, allowing the Linux coordinator to yield to quiet/relink reservations."""
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def main():
    with (Path.home() / 'arcfork/.agent-build.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Build host busy; retry later', flush=True)
            return 75
        if shutil.disk_usage(Path.home()).free < 15 * 1024**3:
            return 75
        child = subprocess.Popen(['bash', 'scripts/sync-test-build.sh'], start_new_session=True,
            pass_fds=(lock.fileno(),), env=dict(os.environ, AIRC_BUILD_LOCK_FD=str(lock.fileno())))
        def stop(sig, frame):
            if child.poll() is None:
                os.killpg(child.pid, sig)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, stop)
        while child.poll() is None:
            if shutil.disk_usage(Path.home()).free < 15 * 1024**3:
                stop(signal.SIGTERM, None)
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    stop(signal.SIGKILL, None)
                    child.wait()
                return 75
            time.sleep(2)
        return child.returncode


if __name__ == '__main__':
    sys.exit(main())
