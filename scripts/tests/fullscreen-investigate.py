#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""One scratch-only fullscreen attempt (--script fullscreen-exit), optionally under LLDB, capped at 55 seconds.

Run on the build Mac with APP OUTPUT --case CASE [--no-debugger].
The app must be a scratch test build: an org.airc.fscrash* or org.airc.fsexit* bundle identity and a renamed
executable (AircFullscreen*, AircFsexit*), so its crash reports never count against the owner's Airc ones. Under LLDB
it must be ad-hoc signed with get-task-allow. Without LLDB the app's own crash records run (CrashRecords, Crash.log).
No capture or HID posting. Never targets another app, profile, or debugger session.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import subprocess
import time

CASES = ['native', 'native-rapid', 'native-esc', 'native-video', 'native-split', 'native-webkit', 'native-switch',
         'little-over-native', 'html', 'switch', 'split', 'little', 'pip', 'webkit', 'webkit-switch']
IDENTITIES = ('org.airc.fscrash', 'org.airc.fsexit')
EXECUTABLES = ('AircFullscreen', 'AircFsexit')


def environment():
    hid = subprocess.check_output(['ioreg', '-r', '-c', 'IOHIDSystem'], text=True, timeout=2)
    idle = float(re.search(r'"HIDIdleTime"\s*=\s*(\d+)', hid).group(1)) / 1e9
    session = subprocess.check_output(['ioreg', '-n', 'Root', '-d1'], text=True, timeout=2)
    locked = bool(re.search(r'"CGSSessionScreenIsLocked"\s*=\s*(?:Yes|true)', session))
    return idle, locked


def app_pids(executable):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=2).splitlines()
    return [int(row.strip().split(None, 1)[0]) for row in rows
            if row.strip().split(None, 1)[-1] == str(executable)]


def attempt(app, output, case, debugger=True):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if not info.get('CFBundleIdentifier', '').startswith(IDENTITIES):
        raise ValueError('Refusing a non-investigator bundle identity')
    if not info.get('CFBundleExecutable', '').startswith(EXECUTABLES):
        raise ValueError('Rename the scratch executable so its reports cannot exhaust the owner report quota')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if app_pids(executable):
        raise RuntimeError('Scratch app already running; refusing an ambiguous target')
    idle, locked = environment()
    if locked or idle < 180:
        return {'case': case, 'status': 'SKIP', 'idle': idle, 'locked': locked}
    output.mkdir(parents=True, exist_ok=False)
    (output / 'home/Library').mkdir(parents=True)
    started = time.monotonic()
    started_wall = time.time()
    previous_idle = idle
    debug = None
    seen_pids = set()
    log = (output / 'lldb.log').open('w')
    result = {'case': case, 'status': 'FAIL', 'reason': 'no completed scenario', 'debugger': debugger}
    env = ['--env', f'CFFIXED_USER_HOME={output / "home"}', '--env', 'AIRC_FULLSCREEN_ACTIVATE=1',
           '--env', f'AIRC_FULLSCREEN_CASE={case}']
    if debugger:
        env += ['--env', 'AIRC_FULLSCREEN_DEBUG_PAUSE=1']
    try:
        subprocess.run(['open', '-g', '-n', *env, str(app), '--args', '--automated',
                        '--engine=chromium', '--snapshot', str(output), '--script', 'fullscreen-exit',
                        '--data-dir', str(output / 'data'), '--use-mock-keychain'], check=True, timeout=3)
        while time.monotonic() - started < 53:
            # Kernel HID state, independent of the app's main loop / debugger stop.
            idle, locked = environment()
            current_pids = app_pids(executable)
            seen_pids.update(current_pids)
            if locked or idle < 180 or idle + .1 < previous_idle:
                result.update(status='ABORT', reason='owner hardware activity or screen locked')
                break
            previous_idle = idle
            ready = output / 'debug-ready'
            if debugger and debug is None and ready.exists():
                pid = int(ready.read_text())
                if pid not in current_pids:
                    raise RuntimeError('Debugger ready PID is not the scratch executable')
                debug = subprocess.Popen(['lldb', '--batch', '-o', f'process attach --pid {pid}',
                                          '-o', 'continue', '-k', 'bt all', '-k', 'process kill', '-k', 'quit'],
                                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            scenario = output / 'log.txt'
            if scenario.exists() and not current_pids:
                text = scenario.read_text()
                # SKIP: the owner came back (the app's own idle gate); SKIP-ENV: something else kept a check from running.
                owner = re.search(r'\nSKIP .*(owner idle|aborted: hardware activity|activation denied)', text)
                result.update(status='SKIP' if owner else 'FAIL' if '\nFAIL ' in text else 'SKIP-ENV' if '\nSKIP ' in text else 'PASS',
                              reason='scenario complete', debugger_attached=debug is not None)
                break
            if debug is not None and debug.poll() is not None and not current_pids:
                result.update(status='CRASH_OR_DEBUGGER_FAILURE', reason='debugger ended before scenario log')
                break
            if not debugger and seen_pids and not current_pids and time.monotonic() - started > 2:
                result.update(status='CRASH', reason='the app ended without writing its scenario log')
                break
            time.sleep(.2)
        else:
            result.update(status='TIMEOUT', reason='53 second external deadline')
            # A hang: its main thread is the evidence. Under LLDB a SIGINT stops the app and the batch runs 'bt all'.
            for pid in app_pids(executable):
                if debug is not None and debug.poll() is None:
                    os.kill(pid, signal.SIGINT)
                    try: debug.wait(timeout=20)
                    except subprocess.TimeoutExpired: pass
                elif debug is None:
                    subprocess.run(['sample', str(pid), '2', '-file', str(output / 'sample.txt')], capture_output=True, timeout=30)
    finally:
        # Cleanup only our uniquely identified scratch process. SIGCONT allows SIGTERM if LLDB left it stopped.
        for pid in app_pids(executable):
            seen_pids.add(pid)
            for sig in [signal.SIGCONT, signal.SIGTERM]:
                try: os.kill(pid, sig)
                except ProcessLookupError: pass
        if debug is not None and debug.poll() is None:
            try: os.killpg(debug.pid, signal.SIGTERM)
            except ProcessLookupError: pass
        time.sleep(.3)
        for pid in app_pids(executable):
            if pid in seen_pids:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
        log.close()
        result['pids'] = sorted(seen_pids)
        # Only reports named for our renamed scratch executable, never the owner's Airc reports; they go to the
        # archive, out of macOS's 25-per-name folder.
        diagnostics = Path.home() / 'Library/Logs/DiagnosticReports'
        archive = Path.home() / 'arcfork/diag-archive/fsexit'
        if result['status'].startswith('CRASH'):
            time.sleep(8)   # ReportCrash takes a while on a big stack, when it manages at all
        for report in diagnostics.glob(info['CFBundleExecutable'] + '-*.ips'):
            archive.mkdir(parents=True, exist_ok=True)
            shutil.move(str(report), archive / report.name)
            result.setdefault('ips', []).append(report.name)
        # Retain small crash evidence, not a new Chromium profile per overnight attempt.
        data = output / 'data'
        if (data / 'Crash.log').exists(): shutil.copy2(data / 'Crash.log', output / 'Crash.log')
        if (data / 'CrashRecords').exists(): shutil.copytree(data / 'CrashRecords', output / 'CrashRecords', dirs_exist_ok=True)
        # WebKit's helper processes outlive the app for a moment and may still be writing there.
        for scratch in [data, output / 'home']:
            for last in [False, False, True]:
                try:
                    if scratch.exists(): shutil.rmtree(scratch, ignore_errors=last)
                    break
                except OSError:
                    time.sleep(2)
        result['started'] = started_wall
        result['elapsed_seconds'] = round(time.monotonic() - started, 2)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--case', choices=CASES, required=True)
    parser.add_argument('--no-debugger', action='store_true', help='let the app crash on its own (its crash records)')
    args = parser.parse_args()
    result = attempt(args.app.resolve(), args.output.resolve(), args.case, debugger=not args.no_debugger)
    print(json.dumps(result))
    raise SystemExit(0 if result['status'] == 'PASS' else 2 if result['status'] == 'SKIP' else 1)
