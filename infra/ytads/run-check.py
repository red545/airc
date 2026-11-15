#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Run one already-built native fixture/live case on the build Mac under its UI lock."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('engine', choices=['webkit', 'chromium'])
parser.add_argument('--video', help='Fixed public video ID, home or search; omit for the local CI fixture')
parser.add_argument('--locked', action='store_true', help=argparse.SUPPRESS)
args = parser.parse_args()
if sys.platform != 'darwin':
    sys.exit('Run on the build Mac.')
root = Path(__file__).resolve().parents[2]
if not args.locked:
    env = dict(os.environ, AIRC_UI_LOCK_TIMEOUT='15')
    sys.exit(subprocess.call([sys.executable, str(root / 'scripts/ui-check-lock.py'),
                             sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], '--locked'], env=env))
scenario = 'ytads-live' if args.video else 'ytads'
output = root / 'build/ytads-checks' / args.engine / (args.video or 'fixture') / time.strftime('%Y%m%dT%H%M%S')
output.mkdir(parents=True)
data = output / 'profile'
app = root / 'build' / ('Airc.app' if args.engine == 'webkit' else 'Airc-Chromium.app')
if not app.is_dir():
    sys.exit('Build the test app first.')
command = ['open', '-g', '-n', '-W', '--env', 'AIRC_YTADS_SOURCE=' + str(root),
           '--env', 'AIRC_YTADS_VIDEO=' + (args.video or ''), '--env', 'AIRC_TELEMETRY_ENABLED=0',
           str(app), '--args', '--engine=' + args.engine, '--script', scenario,
           '--data-dir', str(data), '--snapshot', str(output), '--automated', '--skip-onboarding']

def own_pids():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    return [int(row.strip().split()[0]) for row in rows
            if str(app / 'Contents/MacOS/Airc') + ' ' in row and str(data) in row]

timed_out = False
with (output / 'launch.log').open('w') as log:
    launch = subprocess.Popen(command, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    try:
        launch.wait(timeout=100 if args.video else 230)
    except subprocess.TimeoutExpired:
        timed_out = True
        for pid in own_pids():
            subprocess.run(['sample', str(pid), '3', '-file', str(output / ('hang-' + str(pid) + '.txt'))], timeout=10)
        print('FAIL: native app timed out; stack retained', flush=True)
    finally:
        pids = own_pids()
        for pid in pids:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        try: launch.wait(timeout=8)
        except subprocess.TimeoutExpired:
            for pid in pids:
                if pid in own_pids():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            launch.terminate()
log = output / 'log.txt'
text = log.read_text() if log.exists() else ''
passes = sum(line.startswith('PASS ') for line in text.splitlines())
failures = [line for line in text.splitlines() if line.startswith(('FAIL', 'ENGINE-FAIL'))]
print(output, flush=True)
print('\n'.join(failures), flush=True)
print(f'{scenario} {args.engine}: {passes} passes; {len(failures)} failures', flush=True)
sys.exit(0 if not timed_out and f'[{scenario}]' in text and passes and not failures else 1)
