#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Run under scripts/ui-check-lock.py; owns a virtual display for one command.
Usage: run.py DISPLAY_HELPER EVIDENCE_DIR [COMMAND ...]
The command inherits AIRC_W10_DISPLAY_ID. No app activation or permissions requested.
"""
import ctypes as C
import time
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys


def main():
    helper, output, *command = sys.argv[1:]
    out = Path(output)
    out.mkdir(parents=True, exist_ok=True)
    # UI lock is inherited from its wrapper; refuse uncoordinated display changes.
    import fcntl
    with (Path.home() / 'arcfork/.ui-check.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            raise SystemExit('Refusing: run via scripts/ui-check-lock.py')
    cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    def online():
        ids = (C.c_uint32 * 32)()
        count = C.c_uint32()
        if cg.CGGetOnlineDisplayList(32, ids, C.byref(count)) != 0:
            raise RuntimeError('cannot enumerate online displays')
        return list(ids)[:count.value]
    # Keep the wrapper's lock descriptor in the display process too. If this
    # runner is killed, EOF destroys the display before that last lock closes.
    identity = os.stat(Path.home() / 'arcfork/.ui-check.lock')
    lock_fds = []
    for name in os.listdir('/dev/fd'):
        try:
            fd = int(name)
            stat = os.fstat(fd)
            if stat.st_dev == identity.st_dev and stat.st_ino == identity.st_ino:
                lock_fds.append(fd)
        except (ValueError, OSError):
            pass
    if not lock_fds:
        raise SystemExit("Refusing: inherited UI lock descriptor missing")
    before = online()
    child = None
    display = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, pass_fds=tuple(lock_fds))
    def stopped(*_):
        raise InterruptedError('runner interrupted')
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    evidence = ''
    try:
        with selectors.DefaultSelector() as poll:
            poll.register(display.stdout, selectors.EVENT_READ)
            if not poll.select(20):
                raise RuntimeError('FAIL-ENV: display creation timeout')
        evidence = display.stdout.readline()
        print(evidence, end='', flush=True)
        info = json.loads(evidence)
        if info['width'] != 1920 or info['height'] != 1080 or info['displayID'] == info['mainDisplayID']:
            raise RuntimeError('FAIL-ENV: second display geometry invalid')
        (out / 'display.json').write_text(json.dumps(info, indent=2) + '\n')
        if command:
            env = dict(os.environ, AIRC_W10_DISPLAY_ID=str(info['displayID']))
            child = subprocess.Popen(command, env=env, pass_fds=tuple(lock_fds))
            try:
                result = child.wait(timeout=240)
            except subprocess.TimeoutExpired:
                result = 1
                print('FAIL: command exceeded 240 seconds', flush=True)
        else:
            result = 0
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        display.stdin.close()
        try:
            display.wait(timeout=10)
        except subprocess.TimeoutExpired:
            display.kill()
            display.wait()
        evidence += display.stdout.read()
        # Some OS versions keep the virtual display alive until the helper exits.
        after = online()
        deadline = time.monotonic() + 8
        while set(after) != set(before) and time.monotonic() < deadline:
            time.sleep(0.2)
            after = online()
        evidence += 'before=' + json.dumps(before) + '\nafter=' + json.dumps(after) + '\n'
        evidence += 'removed=' + str(set(after) == set(before)).lower() + '\n'
        (out / 'display-lifecycle.txt').write_text(evidence)
        print(evidence, end='', flush=True)
    if display.returncode or 'removed=true' not in evidence:
        return 1
    return result


if __name__ == '__main__':
    sys.exit(main())
