#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Force SnapshotWatchdog's expiry in a child app and check it leaves a main-thread sample.

Usage (on the build Mac, test build): scripts/watchdog-sample-check.py <Airc.app> <out dir> [--engine=webkit|chromium]
The child runs `--script watchdog-block-main`, which blocks its main thread; its watchdog fires after 5 s,
writes the FAIL line, the main thread's backtrace and a full sample (bounded to about 3.7 s), and exits 70. PASS
needs exit 70, the FAIL line naming watchdog-sample-<pid>.txt, and that file (the main thread's backtrace) showing
the blocked main thread. The full sample (watchdog-sample-<pid>-full.txt) is reported, not required.
Exit 75: the UI lock was busy, retry later.
"""
import json
import os
import plistlib
import signal
import subprocess
import sys
import time
from pathlib import Path


def main():
    app, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    extra = sys.argv[3:]
    executable = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob('watchdog-sample-*'):
        old.unlink()
    (out / 'log.txt').unlink(missing_ok=True)
    (out / 'ui-launch.json').unlink(missing_ok=True)
    lock = Path(__file__).with_name('ui-check-lock.py')
    command = [sys.executable, str(lock), str(executable), *extra, '--snapshot', str(out),
               '--script', 'watchdog-block-main', '--ephemeral', '--data-dir', str(out / 'data')]
    env = dict(os.environ, AIRC_UI_LOCK_STRICT='1')
    started = time.monotonic()
    wrapper = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, text=True)
    try:
        output, _ = wrapper.communicate(timeout=360)  # up to 300 s of lock wait, then 5 s + sample + exit
        rc = wrapper.returncode
    except subprocess.TimeoutExpired:
        stop_child(out)
        wrapper.kill()
        output, rc = '', None
    print(output.strip())
    if rc == 75 and 'refusing' in output:
        print('RETRY watchdog-sample: UI lock busy')
        return 75
    log = (out / 'log.txt').read_text(errors='replace') if (out / 'log.txt').exists() else ''
    pid = launch_pid(out)
    sample = out / f'watchdog-sample-{pid}.txt'
    text = sample.read_text(errors='replace') if sample.exists() else ''
    checks = [
        (rc == 70, f'child exit {rc} (want 70)'),
        (f'main thread sample: {sample.name}' in log, 'FAIL line names the sample file'),
        (sample.exists() and len(text) > 200, f'{sample.name} exists ({len(text)} bytes)'),
        ('semaphore' in text.lower(), 'sample shows the main thread blocked in a semaphore wait'),
        (f'watchdog: main thread sample backtrace in {sample.name}' in log, 'log says the backtrace was written'),
    ]
    full = out / f'watchdog-sample-{pid}-full.txt'
    print('INFO watchdog-sample: full sample', f'{full.name} ({full.stat().st_size} bytes)' if full.exists() else 'not written (over 3 s or unavailable)')
    elapsed = time.monotonic() - started
    print(f'elapsed {elapsed:.1f} s (launch + 5 s deadline + sample + exit)')
    for line in log.splitlines():
        if 'watchdog' in line:
            print('  log:', line)
    ok = True
    for passed, what in checks:
        print(('PASS' if passed else 'FAIL'), 'watchdog-sample:', what)
        ok &= passed
    return 0 if ok else 1


def launch_pid(out):
    try:
        return json.loads((out / 'ui-launch.json').read_text())['pid']
    except (OSError, ValueError, KeyError):
        return 0


def stop_child(out):
    """Exact PID from the app's own ui-launch.json, never a name match."""
    pid = launch_pid(out)
    args = subprocess.run(['ps', '-ww', '-p', str(pid), '-o', 'args='], capture_output=True, text=True).stdout if pid else ''
    if f'--snapshot {out} ' in args + ' ':
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


if __name__ == '__main__':
    sys.exit(main())
