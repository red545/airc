#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""One W10 engine's write/read/fallback launches; run under UI lock.
run.py calls this with a second display for write + read. Call with --fallback
once that helper has exited. Each process has an exact-PID deadline.
"""
import time
import json
import runpy
import signal
import os
from pathlib import Path
import subprocess
import sys


def main():
    # Also protect standalone fallback launches: another process holding the lock
    # is insufficient; this runner must inherit the wrapper's descriptor.
    identity = os.stat(Path.home() / 'arcfork/.ui-check.lock')
    inherited = False
    for name in os.listdir('/dev/fd'):
        try:
            stat = os.fstat(int(name))
            inherited |= stat.st_dev == identity.st_dev and stat.st_ino == identity.st_ino
        except (ValueError, OSError):
            pass
    if not inherited:
        raise SystemExit('Refusing: run via scripts/ui-check-lock.py')
    bundle, engine, evidence, *flags = sys.argv[1:]
    root = Path(evidence).resolve()
    root.mkdir(parents=True, exist_ok=True)
    home = root / 'home'
    home.mkdir(exist_ok=True)
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), AIRC_DISABLE_LEGACY_WINDOW_CAPTURE='1',
               AIRC_MEDIA_PROMPT_CHECKS='0', AIRC_MEDIALIB_DEVICES='0')
    if '--fallback' in flags:
        # Assert disappearance of the actual previous ID, not an unset/zero ID.
        display = json.loads((root / 'display/display.json').read_text())
        env['AIRC_W10_DISPLAY_ID'] = str(display['displayID'])
    bundle = Path(bundle).resolve()
    def interrupted(*_):
        raise InterruptedError('W10 check interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    failed = False
    phases = ['parityw10-fallback'] if '--fallback' in flags else ['parityw10', 'parityw10-read']
    for phase in phases:
        output = root / phase
        output.mkdir(exist_ok=True)
        with (output / 'process.txt').open('w') as log:
            pidfile = output / 'pid.txt'
            pidfile.unlink(missing_ok=True)
            activation = output / 'activation.txt'
            activation.unlink(missing_ok=True)
            # Launch Services registers/activates a real application; a direct SSH executable
            # launch can remain inactive even after NSApp.activate. This is a dedicated UI slot.
            command = ['open', '-n', '-W']
            for key in ['CFFIXED_USER_HOME', 'AIRC_DISABLE_LEGACY_WINDOW_CAPTURE',
                        'AIRC_MEDIA_PROMPT_CHECKS', 'AIRC_MEDIALIB_DEVICES', 'AIRC_W10_DISPLAY_ID']:
                if key in env:
                    command += ['--env', key + '=' + env[key]]
            command += [str(bundle), '--args', '--engine=' + engine, '--snapshot', str(output),
                        '--script', phase, '--data-dir', str(home / 'data')]
            proc = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            try:
                # Ask AppKit from the external runner once the exact new app PID is known.
                # This is not Apple Events control and never requests AX authorization.
                deadline = time.monotonic() + 8
                while not pidfile.exists() and proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if pidfile.exists():
                    pid = int(pidfile.read_text())
                    # Startup may surface notification UI after the pre-launch preflight.
                    # Reuse the existing dedicated-session policy under the same held lock.
                    if os.environ.get('AIRC_UI_DEDICATED_SESSION') == '1':
                        runpy.run_path(str(Path(__file__).resolve().parents[2] / 'scripts/ui-session-preflight.py'))['prepare']()
                    js = ("ObjC.import('AppKit'); var a=$.NSRunningApplication.runningApplicationWithProcessIdentifier(" + str(pid) + "); "
                          "console.log('activation-request=' + a.activateWithOptions(3)); "
                          "console.log('foreground-self=' + ($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == " + str(pid) + ")); "
                          "console.log('foreground-notification=' + (ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) == 'com.apple.UserNotificationCenter')); ")
                    subprocess.run(['osascript', '-l', 'JavaScript', '-e', js], stdout=log, stderr=log, timeout=5, check=False)
                deadline = time.monotonic() + 100
                while proc.poll() is None and time.monotonic() < deadline:
                    if activation.exists() and pidfile.exists():
                        activation.unlink()
                        if os.environ.get('AIRC_UI_DEDICATED_SESSION') == '1':
                            runpy.run_path(str(Path(__file__).resolve().parents[2] / 'scripts/ui-session-preflight.py'))['prepare']()
                            subprocess.run(['osascript', '-l', 'JavaScript', '-e', js], stdout=log, stderr=log, timeout=5, check=False)
                    time.sleep(0.1)
                code = proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                code = 1
            finally:
                # A PID written by this scenario is preferred. Exact executable identity
                # also covers a startup hang before the scenario can write its PID.
                executable = str(bundle / 'Contents/MacOS/Airc')
                def ours():
                    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
                    found = []
                    for row in rows.splitlines():
                        fields = row.strip().split(None, 1)
                        if len(fields) == 2 and fields[1] == executable:
                            found.append(int(fields[0]))
                    return found
                pids = ours()
                for pid in pids:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                if pids:
                    time.sleep(2)
                    remaining = set(ours())
                    for pid in pids:
                        if pid in remaining:
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        report = output / 'log.txt'
        text = report.read_text() if report.exists() else 'FAIL: missing scenario log'
        print(text, flush=True)
        failed |= code != 0 or 'FAIL' in text
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
