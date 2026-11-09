#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Hold the build Mac's build lock and enforce its 15 GiB disk floor."""
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def main():
    home = Path.home()
    path = home / 'arcfork' / '.agent-build.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if shutil.disk_usage(home).free < 15 * 1024**3:
            print('build refused: less than 15 GiB free', file=sys.stderr)
            return 75
        env = dict(os.environ, AIRC_BUILD_LOCK_FD=str(lock.fileno()))
        child = subprocess.Popen(sys.argv[1:], env=env, start_new_session=True, pass_fds=(lock.fileno(),))
        def stop(signum, _frame):
            if child.poll() is None:
                os.killpg(child.pid, signum)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while child.poll() is None:
            if shutil.disk_usage(home).free < 15 * 1024**3:
                print('build stopped: less than 15 GiB free', file=sys.stderr)
                stop(signal.SIGTERM, None)
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    stop(signal.SIGKILL, None)
                    child.wait()
                return 75
            time.sleep(5)
        return child.returncode


if __name__ == '__main__':
    sys.exit(main())
