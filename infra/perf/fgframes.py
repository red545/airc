#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Foreground frame budgets for both engines: Space switch, New Space and the first Command Bar frame.

`--script frames` (Debug/FrameScenario.swift) in a dedicated foreground session (window key), one launch per engine,
action and run. Each action starts in a display-link callback and is timed to the first vsync after its Core Animation
commit, so `frames` 1 is the next vsync. Budgets: Space switch ≤16.7 ms (its first slide frame), New Space ≤8.3 ms,
Command Bar first frame ≤8 ms (`cbfirst`: a loaded-tab switch 250 ms before each ⌘T; sample 0 is the process's first).

On the build Mac, one launch (inside the strict UI lock, like every timing run):

    AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py \
        python3 infra/perf/fgframes.py launch --app build/Airc.app --action switch --samples 10 --output OUT/webkit-switch-1

`series` runs every engine × action × run that way, one lock hold per launch (exit 75 = refused: waits a minute and
retries; the lock is never bypassed), and `summary` combines the launches' frames.json files:

    python3 infra/perf/fgframes.py series --app build/Airc.app --app build/Airc-Chromium.app --runs 3 --output OUT
    python3 infra/perf/fgframes.py summary OUT [--json OUT/summary.json]

`--env NAME=VALUE` passes a test switch to the app (A/B arms in one binary); `--arm` labels it. Each launch records the
Mac's load average before and after (`load`): other agents compile on the build Mac, so read timings with it.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
BUDGETS = {'switch': ('space_switch', 16.7), 'newspace': ('new_space', 8.3), 'cbfirst': ('command_bar_new_tab', 8.0)}


def engine_of(app):
    return 'chromium' if 'Chromium' in Path(app).name else 'webkit'


def own_pid(executable, marker):
    for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
        pid, _, cmd = line.strip().partition(' ')
        if cmd.startswith(executable + ' ') and marker in cmd:
            return int(pid)
    return None


def launch(app, action, samples, out, env=(), arm='', timeout=300, probe=False):
    """One foreground `--script frames` launch; returns its result record (also written to OUT/result.json).
    `probe`: AIRC_FRAMES_PROBE=1, the in-app main-thread sampler, symbolicated with `atos -p` (frameprobe.py); its
    timings are diagnostic only (the sampling slows the main thread)."""
    app, out = Path(app).resolve(), Path(out).resolve()
    if out.exists():
        shutil.rmtree(out)
    data = out / 'data'
    (data / 'Chromium').mkdir(parents=True)
    engine = engine_of(app)
    extra = dict(e.split('=', 1) for e in env)
    if probe:
        extra['AIRC_FRAMES_PROBE'] = '1'
    settings = {'AIRC_UI_DEDICATED_SESSION': '1', 'CFFIXED_USER_HOME': str(data), 'AIRC_FRAMES_ONLY': action,
                'AIRC_FRAMES_RUNS': str(samples), 'AIRC_FRAMES_SECTIONS': '1', 'AIRC_LIVE_SUGGESTIONS': '0', **extra}
    args = ['open', '-n', '-W']
    for k, v in settings.items():
        args += ['--env', f'{k}={v}']
    args += [str(app), '--args', f'--engine={engine}', '--snapshot', str(out), '--script', 'frames', '--ephemeral',
             '--data-dir', str(data), '--airc-data-dir=' + str(data)]
    record = {'engine': engine, 'action': action, 'arm': arm, 'env': extra, 'samples': samples,
              'load_before': os.getloadavg(), 'started': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    stop = threading.Event()
    if probe:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import frameprobe
        threading.Thread(target=frameprobe.symbolicate, args=(out, stop), daemon=True).start()
    p = subprocess.Popen(args)
    executable = str(app / 'Contents/MacOS/Airc')
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Never outlive the check: sample, then stop only this launch's own PID.
        pid = own_pid(executable, str(out))
        if pid:
            subprocess.run(['sample', str(pid), '2', '-file', str(out / 'timeout.sample.txt')])
            os.kill(pid, signal.SIGTERM)
            time.sleep(2)
            if own_pid(executable, str(out)) == pid:
                os.kill(pid, signal.SIGKILL)
        p.terminate()
        record['error'] = 'outer timeout'
    stop.set()
    record['load_after'] = os.getloadavg()
    if probe:
        record['probe'] = True
    shutil.rmtree(data, ignore_errors=True)
    frames = out / 'frames.json'
    if frames.exists():
        record['frames'] = json.loads(frames.read_text())
    elif 'error' not in record:
        record['error'] = 'no frames.json'
    (out / 'result.json').write_text(json.dumps(record, indent=1) + '\n')
    return record


def summarize(records):
    """Per engine, action and arm: medians and next-vsync counts over every launch's samples."""
    groups = {}
    for r in records:
        if r.get('error') or r.get('probe') or r['action'] not in BUDGETS:
            continue
        key, budget = BUDGETS[r['action']]
        f = r['frames'].get(key) or {}
        g = groups.setdefault((r['engine'], r['action'], r.get('arm') or ''), {
            'budget_ms': budget, 'launches': 0, 'presented': [], 'work': [], 'commit': [], 'frames': [], 'first': [],
            'load': []})
        g['launches'] += 1
        presented = f.get('presented_samples_ms') or []
        g['presented'] += presented
        g['work'] += f.get('work_samples_ms') or []
        g['commit'] += f.get('commit_samples_ms') or []
        g['frames'] += [x for x in f.get('frames') or [] if x is not None]
        if presented:
            g['first'].append(presented[0])
        g['load'].append(round(r['load_before'][0], 1))
    out = []
    for (engine, action, arm), g in sorted(groups.items()):
        p = sorted(g['presented'])
        row = {'engine': engine, 'action': action, 'arm': arm, 'budget_ms': g['budget_ms'], 'launches': g['launches'],
               'n': len(p), 'load_1m': g['load']}
        if p:
            row.update(presented_median=round(statistics.median(p), 2), presented_p90=round(p[min(len(p) - 1, int(len(p) * .9))], 2),
                       presented_max=round(p[-1], 2), within_budget=sum(1 for x in p if x <= g['budget_ms']),
                       next_vsync=sum(1 for x in g['frames'] if x == 1),
                       work_median=round(statistics.median(g['work']), 2) if g['work'] else None,
                       work_max=round(max(g['work']), 2) if g['work'] else None,
                       commit_median=round(statistics.median(g['commit']), 2) if g['commit'] else None,
                       first_per_launch=g['first'])
        out.append(row)
    return out


def table(rows):
    lines = ['engine    action    arm      budget  launches  n   presented med/p90/max   ≤budget  next-vsync  work med/max   load(1m)']
    for r in rows:
        if 'presented_median' not in r:
            lines.append(f"{r['engine']:9} {r['action']:9} {r['arm'] or '-':8} no samples")
            continue
        lines.append(f"{r['engine']:9} {r['action']:9} {r['arm'] or '-':8} {r['budget_ms']:6} {r['launches']:9} {r['n']:3}   "
                     f"{r['presented_median']:6.2f} {r['presented_p90']:6.2f} {r['presented_max']:6.2f}   "
                     f"{r['within_budget']:3}/{r['n']:<3}  {r['next_vsync']:3}/{r['n']:<3}    "
                     f"{r['work_median']:5.2f} {r['work_max']:5.2f}   {r['load_1m']}")
    return '\n'.join(lines)


def load_records(paths):
    records = []
    for root in paths:
        for f in sorted(Path(root).rglob('result.json')):
            records.append(json.loads(f.read_text()))
    return records


def series(o):
    """Every app × action × run, each launch in its own strict, dedicated UI-lock hold."""
    for i in range(o.runs):
        for app in o.app:
            for action in o.actions:
                dest = o.output.resolve() / f'{engine_of(app)}-{action}{"-" + o.arm if o.arm else ""}-{i + 1}'
                cmd = [sys.executable, str(ROOT / 'scripts/ui-check-lock.py'), sys.executable, str(Path(__file__).resolve()),
                       'launch', '--app', str(app), '--action', action, '--samples', str(o.samples), '--output', str(dest)]
                if o.arm:
                    cmd += ['--arm', o.arm]
                for e in o.env:
                    cmd += ['--env', e]
                env = dict(os.environ, AIRC_UI_DEDICATED_SESSION='1', AIRC_UI_LOCK_STRICT='1')
                for _ in range(60):
                    rc = subprocess.call(cmd, env=env, stdin=subprocess.DEVNULL)
                    if rc != 75:
                        break
                    time.sleep(60)   # refused: the lock is busy or the session isn't ready; never proceed without it
                print(f'{dest.name} rc={rc}', flush=True)
    rows = summarize(load_records([o.output]))
    print(table(rows))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    one = sub.add_parser('launch')
    one.add_argument('--app', type=Path, required=True)
    one.add_argument('--action', required=True)
    one.add_argument('--samples', type=int, default=10)
    one.add_argument('--output', type=Path, required=True)
    one.add_argument('--env', action='append', default=[])
    one.add_argument('--arm', default='')
    one.add_argument('--probe', action='store_true')
    many = sub.add_parser('series')
    many.add_argument('--app', type=Path, action='append', required=True)
    many.add_argument('--actions', nargs='+', default=list(BUDGETS))
    many.add_argument('--runs', type=int, default=3)
    many.add_argument('--samples', type=int, default=10)
    many.add_argument('--output', type=Path, required=True)
    many.add_argument('--env', action='append', default=[])
    many.add_argument('--arm', default='')
    summary = sub.add_parser('summary')
    summary.add_argument('dirs', nargs='+')
    summary.add_argument('--json', type=Path)
    o = p.parse_args()
    if o.cmd == 'launch':
        if os.environ.get('AIRC_UI_DEDICATED_SESSION') != '1':
            p.error('run inside AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 scripts/ui-check-lock.py')
        r = launch(o.app, o.action, o.samples, o.output, o.env, o.arm, probe=o.probe)
        print(json.dumps({k: v for k, v in r.items() if k != 'frames'}))
        key = BUDGETS.get(o.action, (None,))[0]
        if key and 'frames' in r:
            print(o.action, json.dumps(r['frames'].get(key)))
        return 1 if r.get('error') else 0
    if o.cmd == 'series':
        return series(o)
    rows = summarize(load_records(o.dirs))
    print(table(rows))
    if o.json:
        o.json.write_text(json.dumps(rows, indent=1) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
