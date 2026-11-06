#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Idle-CPU diagnosis on the build Mac: which processes and threads burn CPU once the reference workload is idle.

    python3 infra/perf/idle.py --app build/Airc-Chromium.app [--settle 30] [--interval 30] [--sample 5]

Launches the app's `--script perf` workload exactly like run.py (hidden, isolated data), waits for its `pages` event
(its loads are done; pages not hidden are listed), settles, then records per-process CPU-time deltas and idle wakeups over the interval
and runs `sample` on the hottest processes. Output: OUTPUT/<stamp>/idle.json, idle.txt and sample-*.txt. Never touches
other apps; cleanup signals only this run's identity-checked PIDs.
"""
import argparse, datetime, json, re, signal, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run  # noqa: E402  (the harness: Instance, processes, kind, event, command)


def wakeups(pids, seconds):
    """Idle wakeups per process from `top` over `seconds` (the second sample is the interval's)."""
    if not pids: return {}
    args = ['top', '-l', '2', '-s', str(seconds), '-stats', 'pid,cpu,idlew', *sum((['-pid', str(p)] for p in pids[:30]), [])]
    out = run.command(args, seconds + 30)
    last = out.split('PID')[-1].splitlines()[1:]
    rows = {}
    for line in last:
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit():
            rows[int(parts[0])] = {'top_cpu': float(parts[1]), 'idle_wakeups': int(re.sub(r'\D', '', parts[2]) or 0)}
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=run.ROOT / 'build/Airc-Chromium.app')
    parser.add_argument('--output', type=Path, default=Path.home() / 'arcfork/perf-idle')
    parser.add_argument('--settle', type=float, default=30)
    parser.add_argument('--interval', type=float, default=30)
    parser.add_argument('--sample', type=int, default=5, help='seconds of `sample` per hot process (0: none)')
    parser.add_argument('--hot', type=float, default=0.3, help='sample processes above this CPU %%')
    parser.add_argument('--extra', action='append', default=[], help='extra app argument (repeatable)')
    parser.add_argument('--timeline', type=float, default=0, help='seconds of 5 s per-process CPU buckets after timings')
    parser.add_argument('--trace', action='store_true',
                        help='Time Profiler trace of the main process over the interval (trace.xml; tpsum.py --threads)')
    o = parser.parse_args()
    if sys.platform != 'darwin': parser.error('requires the build Mac')
    signal.alarm(600)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ')
    out = o.output.resolve() / stamp
    (out / 'airc-home/Library').mkdir(parents=True)
    run.command(['swiftc', run.ROOT / 'infra/perf/window.swift', '-o', out / 'window'], 120)
    app = o.app.resolve()
    instance = run.Instance(app / 'Contents/MacOS/Airc', out / 'airc-data')
    result = {'app': str(app), 'settle_s': o.settle, 'interval_s': o.interval, 'errors': []}
    try:
        args = ['--snapshot', out / 'snapshots', '--script', 'perf', '--ephemeral', '--data-dir', out / 'airc-data',
                '--perf-workload', run.ROOT / 'infra/perf/workload.json', '--perf-events', out / 'events.jsonl',
                '--perf-control', out / 'control.json', *o.extra]
        run.command(['open', '-g', '-j', '-n', '--env', f'CFFIXED_USER_HOME={out / "airc-home"}', app, '--args', *args])
        deadline = time.monotonic() + 20
        while not instance.pid and time.monotonic() < deadline:
            instance.discover(); time.sleep(.02)
        if not instance.pid: raise RuntimeError('launch PID not found')
        run.command([out / 'window', str(instance.pid)], 22)
        result['ready'] = run.event(out / 'events.jsonl', 'workload_ready', 180)
        # The app's page report comes once its loads are done (its timed actions wait for the harness's "measure").
        result['pages'] = run.event(out / 'events.jsonl', 'pages', 120).get('pages')
        if o.timeline:
            # Per-kind CPU in 5-second buckets: settling (decaying) load vs steady or periodic work.
            buckets, previous, t = [], instance.discover(), time.monotonic()
            while time.monotonic() - t < o.timeline:
                time.sleep(5)
                now, rows, dt = instance.discover(), {}, time.monotonic() - t - 5 * len(buckets)
                for pid in now:
                    if pid in previous:
                        k = run.kind(now[pid]['command'], pid == instance.pid)
                        k = 'renderer' if k == 'renderer' else k
                        rows[f'{k}:{pid}'] = round(100 * (now[pid]['cpu'] - previous[pid]['cpu']) / dt, 1)
                buckets.append({'t': round(time.monotonic() - t), 'total': round(sum(rows.values()), 1),
                                **{k: v for k, v in rows.items() if v >= 0.5}})
                previous = now
            result['timeline'] = buckets
        time.sleep(o.settle)
        tracer = None
        if o.trace:
            tracer = subprocess.Popen(['xcrun', 'xctrace', 'record', '--quiet', '--template', 'Time Profiler', '--output',
                                       str(out / 'idle.trace'), '--attach', str(instance.pid), '--time-limit',
                                       f'{int(o.interval) + 5}s'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(3)   # xctrace attaches
        begin = instance.discover(); t0 = time.monotonic()
        time.sleep(o.interval)
        end = instance.discover(); elapsed = time.monotonic() - t0
        if tracer:
            tracer.send_signal(signal.SIGINT); tracer.wait(60)
            xml = run.command(['xcrun', 'xctrace', 'export', '--input', out / 'idle.trace', '--xpath',
                               '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], 120)
            (out / 'trace.xml').write_text(xml)
            result['trace_summary'] = run.command([sys.executable, Path(__file__).with_name('tpsum.py'),
                                                   out / 'trace.xml', '--threads'], 120)
        rows = []
        for pid in begin:
            if pid in end:
                rows.append({'pid': pid, 'kind': run.kind(begin[pid]['command'], pid == instance.pid),
                             'cpu_percent': round(100 * (end[pid]['cpu'] - begin[pid]['cpu']) / elapsed, 3)})
        rows.sort(key=lambda r: -r['cpu_percent'])
        result['total_cpu_percent'] = round(sum(r['cpu_percent'] for r in rows), 3)
        result['churn'] = sorted(set(begin) ^ set(end))
        for pid, w in wakeups([r['pid'] for r in rows], 10).items():
            next(r for r in rows if r['pid'] == pid).update(w)
        result['processes'] = rows
        if o.sample:
            for r in [r for r in rows if r['cpu_percent'] >= o.hot][:6]:
                f = out / f"sample-{r['kind'].replace(':', '-')}-{r['pid']}.txt"
                try: run.command(['sample', str(r['pid']), str(o.sample), '-mayDie', '-file', f], o.sample + 60)
                except Exception as e: result['errors'].append(f'sample {r["pid"]}: {e}')
    except Exception as e:
        result['errors'].append(str(e))
    finally:
        instance.cleanup()
    (out / 'idle.json').write_text(json.dumps(result, indent=2) + '\n')
    lines = [f"{stamp} total {result.get('total_cpu_percent')}% of one core over {o.interval:.0f} s"]
    lines += [f"page {p.get('visibility')} {p.get('frames')} frames/s: {p.get('title', '')[:50]}"
              for p in result.get('pages') or [] if p.get('visibility') != 'hidden' or p.get('frames')]
    lines += [f"{r['cpu_percent']:7.3f}%  idle wakeups (top, 10 s) {r.get('idle_wakeups', '?'):>5}  {r['kind']} ({r['pid']})"
              for r in result.get('processes', [])]
    lines += [json.dumps(b) for b in result.get('timeline', [])]
    if result.get('trace_summary'): lines.append(result['trace_summary'])
    lines += [f'error: {e}' for e in result['errors']]
    (out / 'idle.txt').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines)); print(out)
    return 0 if not result['errors'] else 1


if __name__ == '__main__':
    if sys.platform == 'darwin':
        import ctypes
        r = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
        r.argtypes = [ctypes.c_int]; r.restype = ctypes.c_int
        run.responsible = r
    def deadline(signum, frame): raise TimeoutError('idle diagnosis exceeded 600 seconds')
    signal.signal(signal.SIGALRM, deadline)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
