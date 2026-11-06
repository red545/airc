#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Where a browser's renderers keep their memory: each process's footprint by vmmap region type, Airc vs Chrome.

    python3 infra/perf/regions.py airc   --app build/Airc-Chromium.app [--workload W.json] [--wait 45]
    python3 infra/perf/regions.py chrome URL… [--wait 45]

Airc runs its `--script perf` workload (hidden, isolated data; a small workload file narrows it to one page); Chrome a
throwaway profile with the URLs. After `--wait` seconds, every process's `vmmap --summary` is reduced to dirty+swapped
MB per region type (what phys_footprint counts, roughly), printed per process kind. Cleanup signals only this run's
identity-checked PIDs. Output also goes to OUTPUT/<stamp>/regions.json.
"""
import argparse, datetime, json, re, signal, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run  # noqa: E402

UNITS = {'': 1, 'B': 1, 'K': 1024, 'M': 1024 ** 2, 'G': 1024 ** 3}


def size(text):
    m = re.fullmatch(r'([\d.]+)([BKMG]?)', text)
    return float(m[1]) * UNITS[m[2]] / 1e6 if m else 0.0


def regions(pid):
    """{region type: dirty+swapped MB} and the reported physical footprint."""
    out = run.command(['vmmap', '--summary', str(pid)], 30)
    table, footprint = {}, None
    m = re.search(r'^Physical footprint:\s*(\S+)', out, re.M)
    if m: footprint = size(m[1])
    started = False
    for line in out.splitlines():
        if line.startswith('REGION TYPE'): started = True; continue
        if not started or line.startswith(('===', '---')) or not line.strip(): continue
        if line.startswith('TOTAL'): break
        cols = re.split(r'\s{2,}', line.strip())
        # name, virtual, resident, dirty, swapped, volatile, nonvol, empty, count[, …]
        if len(cols) >= 5 and re.fullmatch(r'[\d.]+[BKMG]?', cols[3] or ''):
            table[cols[0]] = round(size(cols[3]) + size(cols[4]), 2)
    return table, footprint


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('browser', choices=['airc', 'chrome'])
    parser.add_argument('urls', nargs='*')
    parser.add_argument('--app', type=Path, default=run.ROOT / 'build/Airc-Chromium.app')
    parser.add_argument('--workload', type=Path, default=run.ROOT / 'infra/perf/workload.json')
    parser.add_argument('--output', type=Path, default=Path.home() / 'arcfork/perf-regions')
    parser.add_argument('--wait', type=float, default=45)
    parser.add_argument('--extra', action='append', default=[], help='extra browser argument (repeatable)')
    o = parser.parse_args()
    signal.alarm(300)
    out = o.output.resolve() / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ') + '-' + o.browser)
    (out / 'home/Library').mkdir(parents=True)
    if o.browser == 'airc':
        app, marker = o.app.resolve(), out / 'data'
        exe = app / 'Contents/MacOS/Airc'
        args = ['--snapshot', out / 'snap', '--script', 'perf', '--ephemeral', '--data-dir', marker,
                '--perf-workload', o.workload.resolve(), '--perf-events', out / 'events.jsonl', '--perf-control', out / 'c.json']
    else:
        app, marker = Path('/Applications/Google Chrome.app'), out / 'profile'
        exe = app / 'Contents/MacOS/Google Chrome'
        marker.mkdir()
        args = run.chrome_args(marker, o.urls)
    args += o.extra
    instance = run.Instance(exe, marker)
    result = {'browser': o.browser, 'processes': [], 'errors': []}
    try:
        run.command(['open', '-g', '-j', '-n', '--env', f'CFFIXED_USER_HOME={out / "home"}', app, '--args', *map(str, args)])
        deadline = time.monotonic() + 20
        while not instance.pid and time.monotonic() < deadline:
            instance.discover(); time.sleep(.05)
        time.sleep(o.wait)
        for pid, row in instance.discover().items():
            try:
                table, fp = regions(pid)
                result['processes'].append({'pid': pid, 'kind': run.kind(row['command'], pid == instance.pid),
                                            'executable': Path(row['command'].split(' --')[0]).name,
                                            'footprint_mb': fp, 'regions': table})
            except Exception as e: result['errors'].append(f'{pid}: {e}')
    finally:
        instance.cleanup()
    (out / 'regions.json').write_text(json.dumps(result, indent=2) + '\n')
    for p in sorted(result['processes'], key=lambda p: (p['kind'], -(p['footprint_mb'] or 0))):
        top = sorted(p['regions'].items(), key=lambda kv: -kv[1])[:9]
        print(f"{p['kind']:24} {p['executable'][-24:]:24} {p['footprint_mb'] or 0:7.1f} MB  " + ', '.join(f'{k} {v:.1f}' for k, v in top[:6]))
    print(out)


if __name__ == '__main__':
    import ctypes
    r = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    r.argtypes = [ctypes.c_int]; r.restype = ctypes.c_int
    run.responsible = r
    sys.exit(main())
