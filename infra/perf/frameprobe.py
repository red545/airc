#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""One guarded `--script frames` launch for one action (gaps.py's launch: UI lock that refuses its timeout, HID idle and
disk checked every second, `open -g`, never activated, no HID events), optionally with the main-thread probe.

python3 infra/perf/frameprobe.py --app build/Airc-Chromium.app --output build/fp/cbfirst-0 --action cbfirst --samples 5
python3 infra/perf/frameprobe.py ... --probe        # AIRC_FRAMES_PROBE=1, stacks symbolicated with `atos -p`
python3 infra/perf/frameprobe.py ... --env AIRC_X=1 # extra app environment (A/B switches)

With --probe the app samples its main thread while the measured actions run (Debug/FrameScenario.swift,
MainThreadSampler), writes snap/probe-samples.txt, probe-pcs.txt and probe-marks.json, and waits until this script has
symbolicated the addresses (`atos -p` needs the process alive) into snap/probe-symbols.txt. Probe runs are diagnostic:
the sampling slows the main thread, so their timings never count. Summaries: frameprobe_report.py.
"""
import argparse
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gaps  # noqa: E402
import run  # noqa: E402


def symbolicate(snap, stop):
    marks, pcs_file = snap / 'probe-marks.json', snap / 'probe-pcs.txt'
    while not stop.is_set():
        if marks.exists() and pcs_file.exists():
            time.sleep(0.5)
            pid = json.loads(marks.read_text())['pid']
            pcs = [line.split()[0] for line in pcs_file.read_text().splitlines() if line.strip()]
            out = []
            for i in range(0, len(pcs), 2000):
                chunk = pcs[i:i + 2000]
                r = subprocess.run(['atos', '-p', str(pid)] + ['0x' + p for p in chunk], capture_output=True, text=True,
                                   timeout=180)
                lines = r.stdout.splitlines()
                if len(lines) != len(chunk):
                    out.append('# atos returned %d lines for %d addresses: %s' % (len(lines), len(chunk), r.stderr[:300]))
                out += ['%s %s' % (p, line) for p, line in zip(chunk, lines)]
            (snap / 'probe-symbols.txt').write_text('\n'.join(out))
            (snap / 'probe-symbols.done').write_text('ok')
            return
        time.sleep(0.2)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--action', required=True)
    p.add_argument('--samples', type=int, default=5)
    p.add_argument('--probe', action='store_true')
    p.add_argument('--env', action='append', default=[])
    o = p.parse_args()
    responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    responsible.argtypes = [ctypes.c_int]
    responsible.restype = ctypes.c_int
    run.responsible = responsible
    env = dict(e.split('=', 1) for e in o.env)
    if o.probe:
        env['AIRC_FRAMES_PROBE'] = '1'
    out = o.output.resolve()
    stop = threading.Event()
    watcher = threading.Thread(target=symbolicate, args=(out / 'snap', stop), daemon=True)
    if o.probe:
        watcher.start()
    try:
        gaps.launch(o.app.resolve(), out, o.action, o.samples, 'http://127.0.0.1:9/suggest', extra_env=env)
        print(json.dumps({'ok': True, 'action': o.action, 'out': str(out), 'env': env}))
    except Exception as e:  # the launch's own guards (lock refused, owner active, disk) end up here
        print(json.dumps({'ok': False, 'action': o.action, 'out': str(out), 'error': str(e)}))
        return 1
    finally:
        stop.set()
    return 0


if __name__ == '__main__':
    sys.exit(main())
