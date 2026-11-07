#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Interleaved frame A/B in one test binary, isolated profiles, no HID or screenshots.

A selects the baseline path where a comparison hook exists. Each launch repeats
its action. Command Bar pruning was reverted: current Command Bar A/B launches
exercise the same path; its baseline environment flag supports archived binaries.
The first-command case switches loaded tabs 250 ms before every opening.
"""
import argparse
import ctypes
import json
import signal
import shutil
import re
import time
from pathlib import Path

import run


def idle_seconds():
    text = run.command(['ioreg', '-c', 'IOHIDSystem'])
    return int(re.search(r'"HIDIdleTime"\s*=\s*(\d+)', text)[1]) / 1e9


def launch(app, out, action, baseline, count):
    if idle_seconds() < 300:
        raise RuntimeError('HID idle below five minutes; measurement stopped')
    out.mkdir(parents=True, exist_ok=False)
    (out / 'home/Library').mkdir(parents=True)
    instance = run.Instance(app / 'Contents/MacOS/Airc', out / 'data')
    try:
        env = {'CFFIXED_USER_HOME': str(out / 'home'), 'AIRC_FRAMES_ONLY': action,
               'AIRC_FRAMES_RUNS': str(count), 'AIRC_FRAMES_SECTIONS': '1',
               'AIRC_PREVIEW_BASELINE': str(int(baseline and action == 'previewcache')),
               'AIRC_NEW_SPACE_BASELINE': str(int(baseline and action == 'newspace')),
               'AIRC_COMMAND_BASELINE': str(int(baseline and action in ('cbfirst', 'cbnew', 'cburl', 'cbkey')))}
        args = ['open', '-g', '-j', '-n']
        for k, v in env.items():
            args += ['--env', k + '=' + v]
        run.command(args + [app, '--args', '--snapshot', out / 'snap', '--script', 'frames',
                           '--ephemeral', '--data-dir', out / 'data'])
        end = time.monotonic() + 100
        result = out / 'snap/frames.json'
        while time.monotonic() < end:
            instance.discover()
            if result.exists():
                value = json.loads(result.read_text())
                if action == 'cbfirst' and value.get('command_bar_new_tab_tab_switches') != count:
                    raise RuntimeError('scenario did not verify every requested tab switch')
                if action == 'newspace' and (value.get('new_space_created') != count or
                                             value.get('new_space_correct_footers') != count):
                    raise RuntimeError('scenario did not create and show every requested Space')
                if action == 'previewcache':
                    cache = value.get('preview_cache', {})
                    if (cache.get('entries') != (30 if baseline else 24) or
                            not cache.get('lru_correct') or cache.get('warning_entries') != 8 or
                            cache.get('cleared_entries') != 0):
                        raise RuntimeError('preview cache capacity, LRU, or pressure trim failed')
                value['hid_idle_seconds'] = idle_seconds()
                if value['hid_idle_seconds'] < 300:
                    raise RuntimeError('HID activity during frame launch; sample rejected')
                return value
            time.sleep(.25)
        raise RuntimeError('frames.json timed out')
    finally:
        instance.cleanup()
        shutil.rmtree(out / "data", ignore_errors=True)
        shutil.rmtree(out / "home", ignore_errors=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--runs', type=int, default=5)
    p.add_argument('--samples', type=int, default=5)
    p.add_argument('--actions', nargs='+', default=['newspace', 'cbfirst', 'cbnew'])
    o = p.parse_args()
    out = o.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for action in o.actions:
        for i in range(o.runs):
            for side in ('A', 'B'):
                dest = out / ('%s-%s%d' % (action, side, i))
                value = launch(o.app.resolve(), dest, action, side == 'A', o.samples)
                results.append({'action': action, 'side': side, 'run': i, 'frames': value})
                (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
                key = {'newspace': 'new_space', 'previewcache': 'preview_cache'}.get(action, 'command_bar_new_tab')
                print(action, side, i, json.dumps(value.get(key)), flush=True)
    print('Completed %d interleaved launches' % len(results), flush=True)


def interrupted(signum, frame):
    raise KeyboardInterrupt('measurement interrupted')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    responsible.argtypes = [ctypes.c_int]
    responsible.restype = ctypes.c_int
    run.responsible = responsible
    main()
