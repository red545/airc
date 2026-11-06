#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Launch timing A/B on the build Mac: the app's own interactive_ms (process start → first idle run loop after the
window) over alternating launches with and without an extra argument.

    python3 infra/perf/launch.py --app build/Airc-Chromium.app --runs 5 --b-arg=--airc-switches=aperitifHelpers=off

Each launch runs `--script perf` on a three-page workload (hidden, isolated data), asks for the timed actions at once,
reads interactive_ms and first-window time, and quits the run's own PIDs. Output: OUTPUT/<stamp>/launch.json.
"""
import argparse, datetime, json, signal, statistics, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run  # noqa: E402

# Small, but what the scenario's timed actions need: two Spaces, two loaded tabs in the first.
WORKLOAD = {'profiles': ['Personal'], 'spaces': [{'id': 0, 'profile': 0}, {'id': 1, 'profile': 0}],
            'tabs': [{'url': 'https://news.ycombinator.com/', 'space': 0, 'recent': True},
                     {'url': 'https://en.wikipedia.org/wiki/Web_browser', 'space': 0, 'recent': True},
                     {'url': 'https://developer.mozilla.org/en-US/docs/Web/CSS', 'space': 1, 'recent': True}]}


def launch(app, out, extra):
    out.mkdir(parents=True)
    (out / 'home/Library').mkdir(parents=True)
    (out / 'workload.json').write_text(json.dumps(WORKLOAD))
    instance = run.Instance(app / 'Contents/MacOS/Airc', out / 'data')
    try:
        start = time.monotonic()
        run.command(['open', '-g', '-j', '-n', '--env', f'CFFIXED_USER_HOME={out / "home"}', app, '--args',
                     '--snapshot', out / 'snap', '--script', 'perf', '--ephemeral', '--data-dir', out / 'data',
                     '--perf-workload', out / 'workload.json', '--perf-events', out / 'events.jsonl',
                     '--perf-control', out / 'control.json', *extra])
        while not instance.pid and time.monotonic() - start < 20:
            instance.discover(); time.sleep(.02)
        run.command([out.parent / 'window', str(instance.pid)], 22)
        first_window = (time.monotonic() - start) * 1000
        run.event(out / 'events.jsonl', 'workload_ready', 60)
        run.control_action(out, '', {'action': 'measure'})
        t = run.event(out / 'events.jsonl', 'timings', 120)
        return {'first_window_ms': round(first_window, 1), 'interactive_ms': t.get('interactive_ms')}
    finally:
        instance.cleanup()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--app', type=Path, default=run.ROOT / 'build/Airc-Chromium.app')
    p.add_argument('--output', type=Path, default=Path.home() / 'arcfork/perf-launch')
    p.add_argument('--runs', type=int, default=5)
    p.add_argument('--b-arg', action='append', default=[], help='argument for the B launches (repeatable)')
    o = p.parse_args()
    signal.alarm(900)
    out = o.output.resolve() / datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ')
    out.mkdir(parents=True)
    run.command(['swiftc', run.ROOT / 'infra/perf/window.swift', '-o', out / 'window'], 120)
    results = {'A': [], 'B': [], 'b_args': o.b_arg}
    for i in range(o.runs):
        for side, extra in [('A', []), ('B', o.b_arg)]:
            try: results[side].append(launch(o.app.resolve(), out / f'{side}{i}', extra))
            except Exception as e: results.setdefault('errors', []).append(f'{side}{i}: {e}')
    for side in 'AB':
        v = [r['interactive_ms'] for r in results[side] if isinstance(r.get('interactive_ms'), (int, float))]
        w = [r['first_window_ms'] for r in results[side]]
        if v: print(f"{side} {' '.join(o.b_arg) if side == 'B' else '(default)'}: interactive median {statistics.median(v):.0f} ms "
                    f"{v}; first window median {statistics.median(w):.0f} ms")
    (out / 'launch.json').write_text(json.dumps(results, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    import ctypes
    r = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    r.argtypes = [ctypes.c_int]; r.restype = ctypes.c_int
    run.responsible = r
    sys.exit(main())
