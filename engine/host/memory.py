#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Empty-profile physical footprint; isolated data, background launch, bounded cleanup."""
import argparse, json, os, pathlib, subprocess, time, signal
p = argparse.ArgumentParser()
p.add_argument('app', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--settle', type=float, default=60)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
results = []
for count in (0, 1, 3, 6):
    run = a.output / str(count)
    run.mkdir()
    pid = None
    try:
        subprocess.run(['open', '-g', '-n', str(a.app.resolve()), '--args',
            '--user-data-dir='+str(run.resolve() / 'data'), '--use-mock-keychain',
            '--airc-empty-profiles='+str(count), '--airc-ready='+str(run.resolve() / 'ready'),
            '--airc-pid='+str(run.resolve() / 'pid')], check=True)
        deadline = time.monotonic()+45
        while not (run / 'ready').exists():
            if time.monotonic()>deadline: raise RuntimeError('host did not become ready')
            time.sleep(.2)
        pid = int((run / 'pid').read_text())
        time.sleep(a.settle)
        rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True)
        processes = [line.strip().split(None, 2) for line in rows.splitlines()]
        owned = {pid}
        for _ in range(10):
            owned |= {int(row[0]) for row in processes if int(row[1]) in owned}
        (run/'processes.txt').write_text('\n'.join(' '.join(row) for row in processes if int(row[0]) in owned))
        command = ['footprint', '--noCategories', '-j', str(run/'footprint.json')]
        for child in sorted(owned): command += ['-p', str(child)]
        sample = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (run/'footprint.txt').write_text(sample.stdout+sample.stderr)
        results.append({'empty_profiles': count, 'pids': sorted(owned), 'exit': sample.returncode})
        print(json.dumps(results[-1]), flush=True)
    finally:
        if pid is None and (run/'pid').exists(): pid = int((run/'pid').read_text())
        if pid:
            # Only the exact executable launched by this run may be signalled.
            cmd = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
            if str(a.app.resolve()) in cmd: os.kill(pid, signal.SIGTERM)
        time.sleep(2)
(a.output/'runs.json').write_text(json.dumps(results, indent=2))
