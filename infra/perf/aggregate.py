#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Combine repeated run.py results into one results.json the status page reads (schema_version 1).

    python3 infra/perf/aggregate.py --output OUT RUN/results.json ... \
        [--foreground RUN/results.json ...] [--ab LABEL=RUN/results.json ...]

Positional runs are the background reference runs (each Airc, chrome_8 and, when measured, airc_30 and chrome launch).
Headline metrics are medians over the runs that measured them; `spread` keeps min, max and n, and `runs` keeps every
run's own metrics. A run never fills another's missing value with zero. `--foreground` runs (run.py --foreground in a
dedicated UI session) decide the timing budgets; their background values stay in the reason. `--ab` adds Airc-only
comparison runs (e.g. mcp_off) as medians next to the reference. Budgets are recomputed by run.py's own rules.
"""
import argparse, importlib.util, json, statistics
from pathlib import Path

spec = importlib.util.spec_from_file_location('perf_run', Path(__file__).with_name('run.py'))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

KEYS = ['airc', 'chrome_8', 'airc_30', 'chrome']
TIMING = {'launch': 'interactive_ms', 'space': 'space_frame_ms', 'tab': 'tab_paint_ms',
          'sidebar-ready': 'sidebar_ready_ms', 'new-space': 'new_space_ms'}


def number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x == x


def combine(sides):
    """Median of each metric over the launches that measured it; conservative page/verification flags."""
    sides = [s for s in sides if s]
    if not sides: return None
    # Like for like: a launch whose window was still on screen for its samples (run.py hidden_for_sample False)
    # doesn't count toward the medians; it is kept in `runs` and counted here.
    shown = sum(1 for s in sides if s.get('hidden_for_sample') is False)
    sides = [s for s in sides if s.get('hidden_for_sample') is not False]
    if not sides: return {'metrics': {}, 'spread': {}, 'launches': 0, 'excluded_on_screen': shown, 'errors': []}
    names = sorted({k for s in sides for k, v in s.get('metrics', {}).items() if number(v)})
    metrics, spread = {}, {}
    for name in names:
        values = [s['metrics'][name] for s in sides if number(s.get('metrics', {}).get(name))]
        metrics[name] = statistics.median(values)
        spread[name] = {'min': min(values), 'max': max(values), 'n': len(values)}
    out = {'metrics': metrics, 'spread': spread, 'launches': len(sides), 'excluded_on_screen': shown,
           'errors': [e for s in sides for e in s.get('errors', [])]}
    pages = [s.get('pages_loaded') for s in sides]
    out['pages_loaded'] = min(pages) if all(number(p) for p in pages) else None   # every launch must load every page
    for flag in ['reference_verified', 'leak_verified']:
        if any(flag in s for s in sides): out[flag] = all(s.get(flag) for s in sides)
    ages = [s.get('memory_sample_start_seconds') for s in sides if number(s.get('memory_sample_start_seconds'))]
    if ages: out['memory_sample_start_seconds'] = statistics.median(ages)
    return out


def aggregate(paths, foreground=(), ab=()):
    runs = [json.loads(Path(p).read_text()) for p in paths]
    if not runs: raise SystemExit('no runs')
    engines = {r.get('engine') for r in runs}
    if len(engines) > 1: raise SystemExit(f'runs mix engines: {engines}')
    last = runs[-1]
    run.LAUNCH_LIMIT_MS = 500 if last.get('engine') == 'webkit' else 1000   # spec 2.12, as run.py sets it per app
    data = {'schema_version': 1, 'kind': 'aggregate', 'timestamp': last['timestamp'], 'engine': last.get('engine'),
            'machine': last.get('machine'), 'workload': last.get('workload'), 'app_args': last.get('app_args', []),
            'notes': [f'Median of {len(runs)} background runs ({runs[0]["timestamp"]} … {last["timestamp"]}); '
                      'min–max per metric in "spread", each run in "runs". Caches not flushed.',
                      *last.get('notes', [])[1:]]}
    data['notes'] = [n for n in data['notes'] if not n.startswith('A/B: ')]
    if data['app_args']: data['notes'].append('Airc launched with ' + ' '.join(data['app_args']))
    for key in KEYS:
        side = combine([r.get(key) for r in runs])
        if side: data[key] = side
    data['runs'] = [{'timestamp': r['timestamp'], 'error': r.get('error'), 'machine': r.get('machine'),
                     **{k: {'metrics': r[k].get('metrics', {}), 'pages_loaded': r[k].get('pages_loaded'),
                            'hidden_for_sample': r[k].get('hidden_for_sample'),
                            'errors': r[k].get('errors', [])} for k in KEYS if k in r}} for r in runs]
    data['mem4'] = run.mem4(data)
    budgets = run.budgets(data)
    if foreground:
        fruns = [json.loads(Path(p).read_text()) for p in foreground]
        front = combine([r.get('airc') for r in fruns])
        data['foreground'] = dict(front, timestamps=[r['timestamp'] for r in fruns])
        fb = {b['id']: b for b in run.budgets({'airc': front})}
        for b in budgets:
            if b['id'] in TIMING and fb.get(b['id'], {}).get('status') in ('pass', 'fail'):
                metric = TIMING[b['id']]
                s, back = front['spread'][metric], b.get('value')
                b.update(status=fb[b['id']]['status'], value=fb[b['id']]['value'],
                         reason=f'dedicated foreground session, median of {s["n"]} ({s["min"]:.1f}–{s["max"]:.1f})'
                                + (f'; background {back:.1f}' if number(back) else ''))
        data['notes'].append(f'Timing budgets: median of {len(fruns)} Airc runs in a dedicated foreground session '
                             '(window key); memory and CPU from the background runs.')
    for b in budgets:   # say how far apart the runs were, so a median pass near the limit is visible
        metric = TIMING.get(b['id']) or {'MEM-1': 'main_mb', 'MEM-2': 'empty_profile_mb', 'MEM-5': 'leak_ratio'}.get(b['id'])
        s = data.get('airc', {}).get('spread', {}).get(metric)
        if s and 'foreground' not in b.get('reason', '') and b['status'] in ('pass', 'fail'):
            b['reason'] = f'median of {s["n"]} background runs ({s["min"]:.2f}–{s["max"]:.2f})'
    data['budgets'] = budgets
    a, c = data.get('airc', {}).get('metrics', {}), data.get('chrome_8', {}).get('metrics', {})
    data['ratios'] = {k: (a[k] / c[k] if number(a.get(k)) and number(c.get(k)) and c[k] else None)
                      for k in ('total_mb', 'main_mb', 'idle_cpu_percent')}
    data['ab'] = {}
    for item in ab:
        label, _, path = item.partition('=')
        other = json.loads(Path(path).read_text())
        data['ab'].setdefault(label, []).append(other)
    data['ab'] = {label: dict(combine([r.get('airc') for r in rs]), app_args=rs[-1].get('app_args', []),
                              timestamps=[r['timestamp'] for r in rs]) for label, rs in data['ab'].items()}
    def real(errors):   # a helper exiting before its early (diagnostic) footprint and excluded launches don't count
        return [e for e in errors if not e.startswith('vmmap:') and not e.startswith('window still on screen')]
    clean = all(not r.get('error') and all(not real(r.get(k, {}).get('errors', [])) for k in KEYS if k in r) for r in runs)
    data['excluded_on_screen'] = {k: data[k].get('excluded_on_screen', 0) for k in KEYS if k in data}
    if any(data['excluded_on_screen'].values()):
        data['notes'].append('Launches whose window stayed on screen during the samples are left out of the medians: '
                             + ', '.join(f'{k} {n}' for k, n in data['excluded_on_screen'].items() if n) + '.')
    data['complete'] = bool(clean and len(runs) >= 3 and data.get('mem4', {}).get('8', {}).get('verified'))
    return data


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--foreground', nargs='*', default=[])
    p.add_argument('--ab', action='append', default=[], help='LABEL=results.json (repeatable)')
    p.add_argument('runs', nargs='+')
    o = p.parse_args()
    data = aggregate(o.runs, o.foreground, o.ab)
    o.output.mkdir(parents=True, exist_ok=True)
    (o.output / 'results.json').write_text(json.dumps(data, indent=2) + '\n')
    print(json.dumps({b['id']: [b['status'], b.get('value')] for b in data['budgets']}, indent=1))


if __name__ == '__main__':
    main()
