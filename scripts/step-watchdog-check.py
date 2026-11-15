#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Prove SnapshotWatchdog's per-step bound: a step that never finishes fails the run fast, with the right verdict.

Usage (on the build Mac, test build): scripts/step-watchdog-check.py <Airc.app> <out dir> [--engine=webkit|chromium]
Three launches of `--script watchdog-step-stall|watchdog-step-block` (a step that never calls done: the main thread
free, or blocked in a semaphore). The bound is 4 s there (90 s for `events`; AIRC_STEP_LIMIT=<s> sets it for any check).
The environment probe looks at the UI driver's path, which here is a stand-in (AIRC_UI_DRIVER_PATH_FOR_PROBE):
  1. stall, stand-in replaced a moment ago (a reinstall)  -> `FAIL-ENV` naming the reinstall, exit 70
  2. stall, stand-in missing                              -> `FAIL-ENV` naming the missing driver, exit 70
  3. block, stand-in old and idle (nothing found)         -> `FAIL [independent]` ..., no environment evidence, and a
                                                              main-thread sample showing the semaphore wait, exit 70
Each must end within ~25 s of launch (not the 240 s hard timeout). Exit 75: the UI lock was busy, retry later.
Stops a stuck app by its exact PID (ui-launch.json), never by name.
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
    app, out_root = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    extra = sys.argv[3:]
    executable = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    out_root.mkdir(parents=True, exist_ok=True)
    stand = out_root / 'driver-standin'
    cases = [
        ('reinstall', 'watchdog-step-stall', 'fresh', 'FAIL-ENV', 'replaced'),
        ('missing', 'watchdog-step-stall', 'missing', 'FAIL-ENV', 'missing'),
        ('nothing-found', 'watchdog-step-block', 'old', 'FAIL [independent]', 'no environment evidence'),
    ]
    ok = True
    for name, script, state, kind, words in cases:
        out = out_root / name
        out.mkdir(parents=True, exist_ok=True)
        for old in out.glob('watchdog-sample-*'):
            old.unlink()
        (out / 'log.txt').unlink(missing_ok=True)
        (out / 'ui-launch.json').unlink(missing_ok=True)
        stand.unlink(missing_ok=True)
        if state != 'missing':
            stand.write_text('#!/bin/sh\nexit 0\n')
            stand.chmod(0o755)
        if state == 'old':
            long_ago = time.time() - 86400
            os.utime(stand, (long_ago, long_ago))
        command = [sys.executable, str(Path(__file__).with_name('ui-check-lock.py')), str(executable), *extra, '--snapshot', str(out),
                   '--script', script, '--ephemeral', '--data-dir', str(out / 'data')]
        env = dict(os.environ, AIRC_UI_LOCK_STRICT='1', AIRC_UI_DRIVER_PATH_FOR_PROBE=str(stand))
        started = time.monotonic()
        wrapper = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, text=True)
        try:
            output, _ = wrapper.communicate(timeout=360)
            rc = wrapper.returncode
        except subprocess.TimeoutExpired:
            stop_child(out)
            wrapper.kill()
            output, rc = '', None
        elapsed = time.monotonic() - started
        if rc == 75 and 'refusing' in output:
            print('RETRY step-watchdog: UI lock busy')
            return 75
        log = (out / 'log.txt').read_text(errors='replace') if (out / 'log.txt').exists() else ''
        pid = launch_pid(out)
        sample = out / f'watchdog-sample-{pid}.txt'
        text = sample.read_text(errors='replace') if sample.exists() else ''
        line = next((l for l in log.splitlines() if 'stuck for' in l), '')
        checks = [
            (rc == 70, f'child exit {rc} (want 70)'),
            (line.startswith(kind + ' ' + script) or line.startswith(kind + ' ' + script.replace('-', '-')), f'verdict line starts "{kind} {script}": {line[:200]}'),
            (words in line, f'verdict names "{words}"'),
            ('off-main watchdog' in line, 'verdict says it came from the off-main watchdog'),
            (sample.exists() and len(text) > 100, f'main-thread sample written ({len(text)} bytes)'),
            (name != 'nothing-found' or 'semaphore' in text.lower(), 'a blocked main thread shows its semaphore wait in the sample'),
            (elapsed < 60, f'ended after {elapsed:.0f} s, well before the 240 s hard timeout'),
        ]
        for passed, what in checks:
            print(('PASS' if passed else 'FAIL'), f'step-watchdog {name}:', what)
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
