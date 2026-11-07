#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Five interleaved 40-entry/24-entry/previews-off/Chrome 30-page sequences.

Retains page outcomes, per-process footprints and matched sampling ages. A ratio
is diagnostic unless all 30 pages loaded in both browsers; inspect titles too
(bot challenges can have titles). Chrome remains the one-profile control.
"""
import argparse
import ctypes
import json
import signal
import shutil
from pathlib import Path

import run
from frames import idle_seconds


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--chrome', type=Path, default=Path('/Applications/Google Chrome.app'))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--runs', type=int, default=5)
    o = p.parse_args()
    out = o.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    version = run.command(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString',
                           o.chrome / 'Contents/Info.plist']).strip()
    workload = run.ROOT / 'infra/perf/workload.json'
    urls = [t['url'] for t in json.loads(workload.read_text())['tabs']]
    results = {'chrome_version': version, 'pairs': []}
    for i in range(o.runs):
        pair = {}
        for variant in ('large', 'on', 'off', 'chrome'):
            browser = 'chrome' if variant == 'chrome' else 'airc'
            if shutil.disk_usage(out).free < 15_000_000_000:
                raise RuntimeError('Less than 15 GB free; measurement stopped')
            if idle_seconds() < 300:
                raise RuntimeError('HID idle below five minutes; measurement stopped')
            if run.command(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString',
                            o.chrome / 'Contents/Info.plist']).strip() != version:
                raise RuntimeError('Chrome changed during A/B')
            dest = out / ('%s%d' % (variant, i))
            dest.mkdir(parents=True, exist_ok=False)
            (dest / (browser + '-home') / 'Library').mkdir(parents=True)
            run.command(['swiftc', run.ROOT / 'infra/perf/window.swift', '-o', dest / 'window'], 120)
            data = dest / 'data'
            if browser == 'airc':
                data.mkdir()
                (data / 'settings.json').write_text(json.dumps({'tabPreviews': variant != 'off'}))
                args = ['--snapshot', str(dest / 'snap'), '--script', 'perf', '--ephemeral', '--data-dir', str(data),
                        '--perf-workload', str(workload), '--perf-events', str(dest / 'events.jsonl'),
                        '--perf-control', str(dest / 'control.json'), '--perf-load', 'all']
                value = run.measure('airc', o.app.resolve(), args, data, dest,
                                    instrumented=True, expect=(30, 0, 3, 6), leak=False, cpu_seconds=0,
                                    launch_env=['AIRC_PREVIEW_BASELINE=' + str(int(variant == 'large'))])
            else:
                data.mkdir()
                value = run.measure('chrome', o.chrome.resolve(), run.chrome_args(data, urls), data, dest,
                                    sample_at=max(pair[v].get('memory_sample_start_seconds', 80) for v in ('large', 'on', 'off')),
                                    pages=lambda: run.chrome_pages(data), cpu_seconds=0)
            pair[variant] = value
            value['hid_idle_seconds'] = idle_seconds()
            if value['hid_idle_seconds'] < 300:
                value['errors'].append('HID activity during launch; comparison rejected')
            print(variant, i, value['metrics'], value['errors'], flush=True)
            (dest / 'result.json').write_text(json.dumps(value, indent=2) + '\n')
            # Only this launch's throwaway data, after identity-checked process cleanup.
            shutil.rmtree(data, ignore_errors=True)
            shutil.rmtree(dest / (browser + '-home'), ignore_errors=True)
            if value['hid_idle_seconds'] < 300:
                raise RuntimeError('HID activity during launch; measurement stopped')
        pair['mem4'] = {v: run.mem4({'airc_30': pair[v], 'chrome': pair['chrome']})['30'] for v in ('large', 'on', 'off')}
        results['pairs'].append(pair)
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('pair', i, pair['mem4'], flush=True)


def interrupted(signum, frame):
    raise KeyboardInterrupt('measurement interrupted')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    responsible.argtypes = [ctypes.c_int]
    responsible.restype = ctypes.c_int
    run.responsible = responsible
    main()
