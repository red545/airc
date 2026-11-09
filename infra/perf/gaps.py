#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Fresh-process gap probes; guarded UI lock, loopback suggestions, no HID injection.

python3 infra/perf/gaps.py --app build/Airc-Chromium.app --output build/gaps --runs 5
Only publish complete, guarded measurements. Missing presentation stays unknown.
"""
import argparse
import ctypes
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import signal
import shutil
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse

import run
from frames import idle_seconds

ACTIONS = ['swipe', 'feedback', 'sidebar', 'cbfirst', 'cbkey', 'suggestions', 'mem3', 'idle']


def limits():
    idle = idle_seconds()
    disk = run.command(['diskutil', 'info', '/System/Volumes/Data'])
    free = int(re.search(r'Container Free Space:.*?\((\d+) Bytes\)', disk)[1])
    if idle < 300 or free < 14_000_000_000:
        raise RuntimeError(f'Pause: HID idle {idle:.1f}s, free {free / 1e9:.2f} GB')
    return {'hid_idle_s': idle, 'free_bytes': free}


class Suggestions(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('q', [''])[0]
        body = json.dumps([query, [query + ' loopback']]).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def do_HEAD(self):
        self.send_response(200); self.end_headers()

    def log_message(self, *_):
        pass


def census(event):
    """CF description repeats a timer in multiple modes: count unique identities.
    Keep raw evidence. This is NOT a census of dispatch/engine worker timers.
    """
    text = event.get('runloop', '')
    timers = {}
    for address, body in re.findall(r'<CFRunLoopTimer (0x[0-9a-f]+)\s+[^>]*>\{([^}]+)\}', text):
        interval = re.search(r'interval\s*=\s*([\d.e+-]+)', body)
        due = re.search(r'next fire date = [\d.e+-]+ \(([\d.e+-]+) @', body)
        timers[address] = {'interval_s': float(interval[1]) if interval else None,
                           'due_s': float(due[1]) if due else None,
                           'callout': body.split('callout = ')[-1].split(', context =')[0]}
    return {'count': len(timers) if 'timers =' in text else None,
            'positive_interval_count': sum((v['interval_s'] or 0) > 0 for v in timers.values()) if timers else None,
            'due_within_30s': sum(v['due_s'] is not None and v['due_s'] <= 30 for v in timers.values()),
            'timers': list(timers.values()), 'scope': event.get('scope'), 'raw': text}


def launch(app, out, action, samples, endpoint, profile=False, extra_env=None):
    out.mkdir(parents=True, exist_ok=False)
    (out / 'home/Library').mkdir(parents=True)
    instance = run.Instance(app / 'Contents/MacOS/Airc', out / 'data')
    guard = [limits()]
    env = {'CFFIXED_USER_HOME': str(out / 'home'), 'AIRC_FRAMES_ONLY': action,
           'AIRC_FRAMES_RUNS': str(samples), 'AIRC_FRAMES_SECTIONS': '1',
           'AIRC_LIVE_SUGGESTIONS': '1' if action == 'suggestions' else '0',
           'AIRC_SUGGESTION_LOOPBACK': endpoint, **(extra_env or {})}
    args = ['open', '-g', '-n', '-W']  # visible background window; never activate
    for k, v in env.items(): args += ['--env', k + '=' + v]
    args += [str(app), '--args', '--snapshot', str(out / 'snap'), '--script', 'perf' if action == 'idle' else 'frames',
             '--ephemeral', '--data-dir', str(out / 'data'), '--airc-data-dir=' + str(out / 'data')]
    if action == 'idle':
        workload = {'profiles': ['One', 'Two', 'Three'], 'spaces': [{'id': i, 'profile': i % 3} for i in range(6)],
                    'tabs': [{'space': i % 6, 'url': 'data:text/html,<title>Idle fixture</title>quiet', 'recent': i < 8} for i in range(30)]}
        (out / 'workload.json').write_text(json.dumps(workload))
        args += ['--perf-workload', str(out / 'workload.json'), '--perf-events', str(out / 'events.jsonl'), '--perf-control', str(out / 'control.json')]
    logfile = (out / 'lock.log').open('w')
    proc = subprocess.Popen([sys.executable, str(run.ROOT / 'scripts/ui-check-lock.py'), sys.executable,
                             __file__, '--guard-open', *args], stdout=logfile, stderr=subprocess.STDOUT)
    tracer = None
    try:
        deadline = time.monotonic() + 450
        last_guard = 0
        def check():
            nonlocal last_guard
            if time.monotonic() > deadline: raise RuntimeError('scenario deadline')
            if time.monotonic() - last_guard > 1:
                guard.append(limits()); last_guard = time.monotonic()
            instance.discover()
            if proc.poll() is not None and not instance.pid:
                raise RuntimeError('launch ended: ' + (out / 'lock.log').read_text())
        def wait(seconds):
            end = time.monotonic() + seconds
            while time.monotonic() < end: check(); time.sleep(.1)
        def event(name):
            while True:
                check()
                if (out / 'events.jsonl').exists():
                    for line in (out / 'events.jsonl').read_text().splitlines():
                        try: value = json.loads(line)
                        except ValueError: continue
                        if value.get('event') == name: return value
                time.sleep(.1)
        while not instance.pid: check(); time.sleep(.1)
        if profile and action != 'idle':
            tracer = subprocess.Popen(['sample', str(instance.pid), '20', '-mayDie', '-file', str(out / 'profile.txt')], stdout=logfile, stderr=logfile)
        if action == 'idle':
            ready = event('workload_ready'); pages = event('pages')
            if tuple(ready.get(k) for k in ('profiles', 'spaces', 'loaded_tabs', 'unloaded_tabs')) != (3, 6, 8, 22):
                raise RuntimeError('idle workload counts not verified')
            if len(pages.get('pages', [])) != 8 or any(p.get('title') != 'Idle fixture' for p in pages['pages']):
                raise RuntimeError('idle fixture pages not loaded')
            wait(30)
            run.control_action(out, '', {'action': 'census'})
            timer = event('timer_census')
            begin = instance.discover(); t0 = time.monotonic(); wait(30); end = instance.discover()
            elapsed = time.monotonic() - t0
            stable = set(begin) == set(end) and bool(begin)
            rows = [{'pid': p, 'kind': run.kind(begin[p]['command'], p == instance.pid),
                     'cpu_percent': 100 * (end[p]['cpu'] - begin[p]['cpu']) / elapsed} for p in begin if p in end]
            value = {'ready': ready, 'pages': pages, 'timers': census(timer), 'processes': rows,
                     'cpu_percent': sum(p['cpu_percent'] for p in rows) if stable else None,
                     'stable': stable, 'interval_s': elapsed}
            # Capture a diagnostic profile whenever the CPU budget fails.
            if stable and (value['cpu_percent'] >= 1 or (value['timers'].get('count') or 0) > 0 or profile):
                hottest = max(rows, key=lambda p: p['cpu_percent']) if value['cpu_percent'] >= 1 else {'pid': instance.pid}
                subprocess.run(['sample', str(hottest['pid']), '5', '-file', str(out / 'profile.txt')], stdout=logfile, stderr=logfile, timeout=20)
            check()
        else:
            path = out / 'snap/frames.json'
            while not path.exists(): check(); time.sleep(.1)
            value = json.loads(path.read_text())
        guard.append(limits())
        value['guard'] = guard
        value['action'] = action
        (out / 'result.json').write_text(json.dumps(value, indent=2))
        return value
    finally:
        instance.cleanup()
        try: proc.wait(10)
        except subprocess.TimeoutExpired: proc.terminate(); proc.wait(5)
        if tracer: tracer.wait(30)
        logfile.close()
        shutil.rmtree(out / "data", ignore_errors=True)
        shutil.rmtree(out / "home", ignore_errors=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--runs', type=int, default=5)
    p.add_argument('--samples', type=int, default=5)
    p.add_argument('--actions', nargs='+', choices=ACTIONS, default=ACTIONS)
    p.add_argument('--profile', action='store_true')
    o = p.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Suggestions)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    out = o.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    data = {'schema_version': 1, 'kind': 'performance-gaps', 'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'binary_sha256': hashlib.sha256((o.app / 'Contents/MacOS/Airc').read_bytes()).hexdigest(),
            'requested_runs': o.runs, 'requested_samples': o.samples, 'runs': {}, 'errors': []}
    try:
        for i in range(o.runs):
            for action in o.actions:
                print(action, i, flush=True)
                value = launch(o.app.resolve(), out / f'{action}-{i}', action, o.samples,
                               f'http://127.0.0.1:{server.server_port}/suggest', o.profile)
                data['runs'].setdefault(action, []).append(value)
                (out / 'gaps.json').write_text(json.dumps(data, indent=2))
    except (Exception, KeyboardInterrupt) as e:
        data['errors'].append(str(e)); print(str(e), flush=True)
    finally:
        from gap_results import budgets
        data['budgets'] = budgets(data)
        (out / 'gaps.json').write_text(json.dumps(data, indent=2))
        server.shutdown()
    return int(bool(data['errors']))


if __name__ == '__main__':
    if sys.argv[1:2] == ['--guard-open']:
        holder = (Path.home() / 'arcfork/.ui-check.lock').read_text()
        if 'pid=' + str(os.getppid()) + ' ' not in holder: raise RuntimeError('UI lock timeout: refusing launch')
        limits(); os.execvp(sys.argv[2], sys.argv[2:])
    r = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    r.argtypes = [ctypes.c_int]; r.restype = ctypes.c_int; run.responsible = r
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
