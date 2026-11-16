#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Black-box browser comparison on the build Mac: Airc (any build, including a published one) against other
Chromium-based browsers, measured the same way for each, from outside the app.

Nothing here needs an app hook, Accessibility, screen capture or AppleEvents. Pages are local copies of public pages
(`mirror`, on a box with wget), served from 127.0.0.1 under one `pNN.localhost` host per page (so each page is its own
site, as on the web), with a small injected beacon (arcbench_page.js) that reports paint, load, visibility, frame,
focus and key times in epoch milliseconds. Keys are real HID events from the stable UI driver (`--pid`: delivered only
to a foreground target). Windows and activation come from arcbench_probe.swift (CoreGraphics window list, no names).

Cases (each one launch series of one browser, run inside the strict UI lock in a dedicated session, with
status/timing-run declared by the coordinator):

    python3 infra/perf/arcbench.py launch --browser airc --app PATH --pages DIR --out OUT/launch-airc-1
        fresh profile launch → first window; warm relaunch → first window; link launch (warm profile) → window and
        the page's first contentful paint. Each launch quits before the next.
    python3 infra/perf/arcbench.py tabs --browser chrome --pages DIR --out OUT/tabs-chrome-1 [--window x,y,w,h]
        a fresh profile opens the 20 pages as tabs; 60 s settle after the last load; phys_footprint of every process;
        ⌃PageDown ×30 (key → the next page's first frame); ⌘T ×30 (key → focus leaves the page, i.e. the new tab's
        field took it); then the app hidden and 300 s idle CPU over all its processes.
    python3 infra/perf/arcbench.py report OUT [--markdown FILE] [--json FILE] [--svg FILE]

Browsers: `airc` (`--app`, Airc's own data folder and settings, telemetry off), `chrome` (/Applications/Google
Chrome.app, throwaway --user-data-dir). `arc` is defined but refuses to launch: see ARC_BLOCKED.
Both run with a synthetic home (CFFIXED_USER_HOME) and Chromium's mock keychain, so no owner data is read.
"""
import argparse, http.server, json, os, re, shutil, signal, statistics, subprocess, sys, threading, time, urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run  # noqa: E402  (process discovery, footprint)

HERE = Path(__file__).resolve().parent
DRIVER = Path.home() / 'arcfork/tools/airc-ui-driver/airc-ui-driver'
CHROME = Path('/Applications/Google Chrome.app')
ARC_BLOCKED = ("Arc 1.171 can't run isolated on a Mac where its owner is signed in: new sign-ups are closed, so a fresh "
               "profile stops at sign-in, and a second instance shares the login keychain's Arc account items (auth "
               "and sync), whatever CFFIXED_USER_HOME or --user-data-dir say. Measuring it needs a Mac or macOS user "
               "with its own signed-in Arc, with the owner's approval.")


# ---------------------------------------------------------------- browsers

class Browser:
    name = ''
    urls_in_argv = False   # True: URLs go on the command line; False: Launch Services hands them over (link events)
    def __init__(self, app=None): self.app = Path(app) if app else None
    @property
    def executable(self): raise NotImplementedError
    def prepare(self, profile, home, tabs): (home / 'Library').mkdir(parents=True, exist_ok=True)
    def args(self, profile, window): raise NotImplementedError
    def env(self, home): return {'CFFIXED_USER_HOME': str(home)}
    def marker(self, profile): return str(profile)
    def reset_new_tab(self): raise NotImplementedError
    def version(self):
        return plist(self.app, 'CFBundleShortVersionString')


class Airc(Browser):
    name = 'airc'
    @property
    def executable(self): return self.app / 'Contents/MacOS/Airc'
    def prepare(self, profile, home, tabs):
        super().prepare(profile, home, tabs)
        profile.mkdir(parents=True, exist_ok=True)
        settings = profile / 'settings.json'
        values = json.loads(settings.read_text()) if settings.exists() else {}
        values['shareUsageData'] = False
        # Links from other apps open in Little Airc by default; the 20-tab case wants them as tabs in the window.
        if tabs: values['externalLinks'] = 'recentSpace'
        settings.write_text(json.dumps(values))
    def args(self, profile, window):
        return ['--data-dir', str(profile), '--skip-onboarding', '--use-mock-keychain']
    def env(self, home): return {**super().env(home), 'AIRC_TELEMETRY_ENABLED': '0'}
    def reset_new_tab(self): return 'esc'          # ⌘T opens the Command Bar; Esc closes it without a tab
    def version(self): return f"{plist(self.app, 'CFBundleShortVersionString')} ({(plist(self.app, 'AircRevision') or '')[:8]})"


class Chrome(Browser):
    name = 'chrome'
    urls_in_argv = True    # `open -n -a Chrome URL…` fails for a second instance; Chrome reads them from argv
    def __init__(self, app=None): super().__init__(app or CHROME)
    @property
    def executable(self): return self.app / 'Contents/MacOS/Google Chrome'
    def args(self, profile, window):
        a = [f'--user-data-dir={profile}', '--no-first-run', '--no-default-browser-check', '--use-mock-keychain']
        if window:
            x, y, w, h = window
            a += [f'--window-position={x},{y}', f'--window-size={w},{h}']
        return a
    def reset_new_tab(self): return 'cmd+w'        # ⌘T opens a New Tab page; ⌘W closes it, back to the page


class Arc(Browser):
    name = 'arc'
    def __init__(self, app=None): super().__init__(app or '/Applications/Arc.app')
    @property
    def executable(self): return self.app / 'Contents/MacOS/Arc'
    def args(self, profile, window): raise SystemExit(ARC_BLOCKED)


BROWSERS = {'airc': Airc, 'chrome': Chrome, 'arc': Arc}


def plist(app, key):
    try: return run.command(['/usr/libexec/PlistBuddy', '-c', f'Print :{key}', Path(app) / 'Contents/Info.plist']).strip()
    except Exception: return None


# ---------------------------------------------------------------- pages and beacons

class Pages:
    """Serves OUT/pages/pNN/site/… for host pNN.localhost and records the beacons (with the server's receive time)."""
    def __init__(self, root):
        self.root = Path(root)
        self.list = json.loads((self.root / 'pages.json').read_text())
        self.script = (HERE / 'arcbench_page.js').read_bytes()
        self.beacons, self.lock = [], threading.Lock()
        pages = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
                try: b = json.loads(body) if self.path == '/__beacon' else None
                except ValueError: b = None
                if isinstance(b, dict) and 'ev' in b:   # a mirrored page's own POSTs are answered and dropped
                    b['received'] = time.time() * 1000
                    with pages.lock: pages.beacons.append(b)
                self.send_response(204); self.end_headers()
            def do_GET(self):
                host = (self.headers.get('Host') or '').split('.')[0]
                path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
                if path == '/__bench.js':
                    return self.reply(200, pages.script, 'text/javascript')
                site = (pages.root / host / 'site').resolve()
                f = (site / path.lstrip('/')).resolve()
                if not re.fullmatch(r'p\d\d', host) or site not in f.parents or not f.is_file():
                    return self.reply(404, b'', 'text/plain')
                data = f.read_bytes()
                kind = {'.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript',
                        '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
                        '.gif': 'image/gif', '.webp': 'image/webp', '.woff2': 'font/woff2', '.woff': 'font/woff',
                        '.json': 'application/json', '.ico': 'image/x-icon'}.get(f.suffix.lower(), 'application/octet-stream')
                if f.suffix.lower() == '.html':
                    tag = f'<script src="/__bench.js?id={host}"></script>'.encode()
                    m = re.search(rb'<head[^>]*>', data, re.I)
                    data = data[:m.end()] + tag + data[m.end():] if m else tag + data
                self.reply(200, data, kind)
            def reply(self, code, data, kind):
                self.send_response(code)
                self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
    def url(self, page):
        return f"http://{page['id']}.localhost:{self.port}{urllib.parse.quote(page['path'])}"
    def mark(self):
        with self.lock: return len(self.beacons)
    def wait(self, test, since=0, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock: found = [b for b in self.beacons[since:] if test(b)]
            if found: return found[0]
            time.sleep(0.005)
        return None
    def since(self, mark):
        with self.lock: return list(self.beacons[mark:])
    def close(self): self.server.shutdown()


# ---------------------------------------------------------------- the app under test

def probe(*args, timeout=40):
    return run.command([PROBE, *args], timeout).strip()


def key(combo, pid):
    """A real key via the UI driver (foreground-guarded --pid). Returns (epoch ms before, after the call)."""
    t0 = time.time() * 1000
    out = subprocess.run([str(DRIVER), '--key', combo, '--pid', str(pid)], capture_output=True, text=True, timeout=10)
    t1 = time.time() * 1000
    if out.returncode: raise RuntimeError(f'driver --key {combo}: {out.stdout.strip()[-200:]} {out.stderr.strip()[-200:]}')
    return t0, t1


class Session:
    """One launch of one browser with one profile; its own processes only (run.Instance: executable + profile marker)."""
    def __init__(self, browser, profile, home, window=None, urls=(), tabs=False):
        self.browser, self.profile, self.home = browser, Path(profile), Path(home)
        browser.prepare(self.profile, self.home, tabs)
        self.instance = run.Instance(browser.executable, browser.marker(self.profile))
        cmd = ['open', '-n']
        for k, v in browser.env(self.home).items(): cmd += ['--env', f'{k}={v}']
        args = browser.args(self.profile, window)
        if browser.urls_in_argv: args, urls = [*args, *urls], []
        cmd += ['-a', str(browser.app), *urls, '--args', *args]
        self.started = time.time() * 1000
        try:
            run.command(cmd, 30)
        except Exception:
            # `open` can report a failure after the app started anyway (Chrome with URLs): stop what it started.
            time.sleep(3); self.instance.discover(); self.instance.cleanup()
            raise
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not self.instance.pid:
            self.instance.discover(); time.sleep(0.01)
        if not self.instance.pid: raise RuntimeError('launch: PID not found in 30 s')
        self.pid = self.instance.pid
    def first_window(self, timeout=40):
        t, *bounds = probe('window', str(self.pid), str(timeout), timeout=timeout + 5).split()
        return float(t) * 1000 - self.started, list(map(int, bounds))
    def front(self):
        if probe('front') != str(self.pid): probe('activate', str(self.pid))
        return probe('front') == str(self.pid)
    def quit(self, timeout=15):
        """SIGTERM to the main process, the same for every browser (Airc's ⌘Q is hold-to-quit, which the driver can't
        press; Chrome shuts down cleanly on SIGTERM); then the run's own PIDs only."""
        how = 'SIGTERM'
        try: os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.instance.discover(): time.sleep(0.2)
        left = bool(self.instance.discover())
        self.instance.cleanup()
        return how + (' then killed' if left else '')


def footprints(instance, attempts=3):
    """phys_footprint (vmmap --summary) of every process of the launch, the same for every browser; retried when the
    process set changes while it's sampled."""
    for _ in range(attempts):
        rows = instance.discover()
        sample = []
        try:
            for pid, row in rows.items():
                sample.append({'pid': pid, 'main': pid == instance.pid, 'kind': run.kind(row['command'], pid == instance.pid),
                               'mb': round(run.footprint(pid), 1)})
        except RuntimeError:
            time.sleep(2); continue
        if set(rows) == set(instance.discover()):
            return {'total_mb': round(sum(x['mb'] for x in sample), 1),
                    'main_mb': next((x['mb'] for x in sample if x['main']), None),
                    'renderers': sum(x['kind'] == 'renderer' for x in sample), 'processes': len(sample),
                    'per_process': sorted(sample, key=lambda x: -x['mb'])}
        time.sleep(2)
    raise RuntimeError('process set kept changing during the footprint sample')


def idle_cpu(instance, seconds):
    begin = instance.discover(); t0 = time.monotonic()
    time.sleep(seconds)
    end = instance.discover(); elapsed = time.monotonic() - t0
    gone = set(begin) - set(end)
    # Processes that started during the interval count from zero; ones that exited lose their last seconds (recorded).
    cpu = sum(end[p]['cpu'] - begin.get(p, {'cpu': 0})['cpu'] for p in end)
    return {'cpu_percent': round(100 * cpu / elapsed, 3), 'seconds': round(elapsed, 1),
            'processes_started': len(set(end) - set(begin)), 'processes_exited': len(gone),
            'top': sorted(({'kind': run.kind(end[p]['command'], p == instance.pid),
                            'cpu_percent': round(100 * (end[p]['cpu'] - begin.get(p, {'cpu': 0})['cpu']) / elapsed, 3)}
                           for p in end), key=lambda x: -x['cpu_percent'])[:8]}


# ---------------------------------------------------------------- cases

def settle_load(limit=8.0, longest=60):
    """Other agents compile on the build Mac; the engine build pauses for status/timing-run. Waits (at most `longest`
    seconds) for the 1-minute load average to fall under `limit`, and returns what it saw."""
    t0 = time.monotonic()
    while os.getloadavg()[0] > limit and time.monotonic() - t0 < longest: time.sleep(2)
    return {'waited_s': round(time.monotonic() - t0, 1), 'load': os.getloadavg()}


def case_launch(o, browser, pages):
    """Fresh profile → first window; warm relaunch → first window; link launch (warm profile) → window + FCP."""
    result = {'steps': []}
    profile, home = o.out / 'profile', o.out / 'home'
    first = pages.list[0]
    for step in ['fresh', 'warm', 'link']:
        mark = pages.mark()
        urls = [pages.url(first)] if step == 'link' else []
        s = Session(browser, profile, home, o.window, urls)
        r = {'step': step, 'load_before': os.getloadavg()}
        try:
            r['first_window_ms'], r['window'] = s.first_window()
            if step == 'link':
                fcp = pages.wait(lambda b: b['ev'] == 'fcp' and b['id'] == first['id'], mark, 30)
                r['page_fcp_ms'] = round(fcp['fcp'] - s.started, 1) if fcp else None
                load = pages.wait(lambda b: b['ev'] == 'load' and b['id'] == first['id'], mark, 30)
                r['page_load_ms'] = round(load['t'] - s.started, 1) if load else None
            time.sleep(4)   # let the launch finish its deferred work before quitting
            r['windows'] = int(probe('count', str(s.pid)))
        except Exception as e:
            r['error'] = str(e)
        finally:
            r['quit'] = s.quit()
        r['load_after'] = os.getloadavg()
        result['steps'].append(r)
        time.sleep(3)
    return result


def case_tabs(o, browser, pages):
    result = {}
    profile, home = o.out / 'profile', o.out / 'home'
    urls = [pages.url(p) for p in pages.list]
    mark = pages.mark()
    s = Session(browser, profile, home, o.window, urls, tabs=True)
    try:
        result['first_window_ms'], result['window'] = s.first_window()
        # Every page loaded (its load beacon), then 60 s settle from the last one. Airc (like Arc) loads a tab when it is
        # first shown, Chrome loads every tab at once: both visit each tab once with ⌃PageDown (the same keys).
        if not s.front(): raise RuntimeError('the browser is not frontmost: keys would go elsewhere')
        loaded_ids = lambda: {b['id'] for b in pages.since(mark) if b['ev'] == 'load'}
        visits = 0
        while len(loaded_ids()) < len(pages.list) and visits < 2 * len(pages.list):
            before = len(loaded_ids())
            key('ctrl+pagedown', s.pid); visits += 1
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and len(loaded_ids()) == before: time.sleep(0.1)
            time.sleep(0.3)
        while visits < len(pages.list):   # the rest of one full round, for browsers that had loaded everything
            key('ctrl+pagedown', s.pid); visits += 1; time.sleep(0.5)
        loaded = loaded_ids()
        result['load_visits'] = visits
        result['pages_loaded'] = len(loaded)
        result['all_loaded_s'] = round((time.time() * 1000 - s.started) / 1000, 1)
        time.sleep(60)
        result['windows'] = int(probe('count', str(s.pid)))
        result['window_list'] = probe('list', str(s.pid))
        result['window'] = list(map(int, probe('bounds', str(s.pid)).split()))
        result['memory'] = footprints(s.instance)
        result['memory']['load'] = os.getloadavg()
        if not s.front(): raise RuntimeError('the browser is not frontmost: keys would go elsewhere')

        # ⌃PageDown: key → the next page's visibility change and its first frame (rAF), and that frame's work done.
        switches = []
        for i in range(o.presses + 1):
            m = pages.mark()
            t0, t1 = key('ctrl+pagedown', s.pid)
            b = pages.wait(lambda b: b['ev'] == 'visframe' and b['start'] >= t0 - 1, m, 3)
            if i and b:   # the first switch only brings the series into a known state
                switches.append({'page': b['id'], 'driver_ms': round(t1 - t0, 1), 'visible_ms': round(b['start'] - t0, 2),
                                 'frame_ms': round(b['raf'] - t0, 2), 'frame_done_ms': round(b['after'] - t0, 2)})
            elif i: switches.append({'missed': True, 'driver_ms': round(t1 - t0, 1)})
            time.sleep(0.6)
        result['tab_switch'] = switches

        # Delivery calibration: ⇧↓ (bound in neither browser) to the focused page, the same driver path as the shortcuts
        # (a modifier, then the key 10 ms later, foreground check): the page's key-down time minus the moment before
        # the call. Subtracting it gives latencies from the key-down itself.
        calib = []
        for _ in range(10):
            m = pages.mark()
            t0, t1 = key('shift+down', s.pid)
            b = pages.wait(lambda b: b['ev'] == 'key' and b.get('key') == 'ArrowDown' and b['start'] >= t0 - 50, m, 2)
            calib.append(round(b['start'] - t0, 2) if b else None)
            time.sleep(0.4)
        result['driver_offset_ms'] = calib

        # ⌘T: key → focus leaves the page (the new tab's field took the keyboard); then close it again.
        newtabs = []
        for i in range(o.presses):
            m = pages.mark()
            t0, t1 = key('cmd+t', s.pid)
            b = pages.wait(lambda b: b['ev'] in ('blur', 'vis') and b['start'] >= t0 - 1, m, 3)
            newtabs.append({'driver_ms': round(t1 - t0, 1), **({'focus_left_ms': round(b['start'] - t0, 2), 'via': b['ev']}
                                                              if b else {'missed': True})})
            time.sleep(0.6)
            m = pages.mark()
            key(browser.reset_new_tab(), s.pid)
            back = pages.wait(lambda b: b['ev'] == 'focus', m, 3)
            if not back: newtabs[-1]['focus_not_back'] = True
            time.sleep(0.6)
        result['new_tab'] = newtabs

        # Idle: the app hidden (every page occluded), all its processes' CPU over o.idle seconds.
        result['hidden'] = probe('hide', str(s.pid)) == 'hidden'
        result['idle'] = idle_cpu(s.instance, o.idle)
        result['idle']['load'] = os.getloadavg()
        result['memory_after_idle_mb'] = footprints(s.instance)['total_mb']
    finally:
        result['quit'] = s.quit()
    return result


# ---------------------------------------------------------------- report

def stats(values):
    v = sorted(x for x in values if isinstance(x, (int, float)))
    if not v: return None
    q = statistics.quantiles(v, n=4) if len(v) >= 4 else [v[0], statistics.median(v), v[-1]]
    return {'median': round(statistics.median(v), 2), 'min': round(v[0], 2), 'max': round(v[-1], 2),
            'p25': round(q[0], 2), 'p75': round(q[2], 2), 'n': len(v)}


def collect(root):
    runs = {}
    for f in sorted(Path(root).glob('*/result.json')):
        r = json.loads(f.read_text())
        runs.setdefault((r['case'], r['browser']), []).append(r)
    return runs


def report(root):
    runs, out = collect(root), {}
    for (case, browser), rs in runs.items():
        o = out.setdefault(browser, {'version': rs[0].get('version')})
        if case == 'launch':
            for step in ['fresh', 'warm', 'link']:
                rows = [s for r in rs for s in r.get('steps', []) if s['step'] == step and 'error' not in s]
                o[f'launch_{step}_load'] = [s.get('load_before') for s in rows]
                o[f'launch_{step}_window_ms'] = {'stats': stats([s['first_window_ms'] for s in rows]),
                                                 'runs': [round(s['first_window_ms'], 1) for s in rows]}
                if step == 'link':
                    o['launch_link_fcp_ms'] = {'stats': stats([s.get('page_fcp_ms') for s in rows]),
                                               'runs': [s.get('page_fcp_ms') for s in rows]}
        if case == 'tabs':
            ok = [r for r in rs if 'error' not in r]
            o['memory_total_mb'] = {'stats': stats([r['memory']['total_mb'] for r in ok if 'memory' in r]),
                                    'runs': [r.get('memory', {}).get('total_mb') for r in ok]}
            o['memory_main_mb'] = {'stats': stats([r['memory']['main_mb'] for r in ok if 'memory' in r]),
                                   'runs': [r.get('memory', {}).get('main_mb') for r in ok]}
            o['renderers'] = [r.get('memory', {}).get('renderers') for r in ok]
            o['pages_loaded'] = [r.get('pages_loaded') for r in ok]
            per_run_median = lambda key, field: [statistics.median([x[field] for x in r.get(key, []) if field in x])
                                                 for r in ok if any(field in x for x in r.get(key, []))]
            for name, keyname, field in [('tab_switch_frame_ms', 'tab_switch', 'frame_ms'),
                                         ('tab_switch_frame_done_ms', 'tab_switch', 'frame_done_ms'),
                                         ('new_tab_focus_ms', 'new_tab', 'focus_left_ms')]:
                every = [x[field] for r in ok for x in r.get(keyname, []) if field in x]
                o[name] = {'stats': stats(every), 'per_run_medians': [round(x, 2) for x in per_run_median(keyname, field)],
                           'missed': sum(1 for r in ok for x in r.get(keyname, []) if x.get('missed'))}
            # From the key-down itself: each sample minus its own run's median ⇧↓ offset. Diagnostic only: the offset
            # differs by browser (the page's key-down time isn't purely the driver's), so compare the raw times.
            offset = lambda r: statistics.median([x for x in r.get('driver_offset_ms', []) if isinstance(x, (int, float))] or [0])
            for name, keyname, field in [('tab_switch_frame_from_keydown_ms', 'tab_switch', 'frame_ms'),
                                         ('new_tab_focus_from_keydown_ms', 'new_tab', 'focus_left_ms')]:
                o[name] = {'stats': stats([x[field] - offset(r) for r in ok for x in r.get(keyname, []) if field in x])}
            o['driver_offset_ms'] = stats([x for r in ok for x in r.get('driver_offset_ms', [])])
            o['memory_load'] = [r.get('memory', {}).get('load') for r in ok]
            o['idle_load'] = [r.get('idle', {}).get('load') for r in ok]
            o['idle_cpu_percent'] = {'stats': stats([r['idle']['cpu_percent'] for r in ok if 'idle' in r]),
                                     'runs': [r.get('idle', {}).get('cpu_percent') for r in ok]}
            o['hidden_for_idle'] = [r.get('hidden') for r in ok]
            o['loads'] = [r.get('load_before') for r in ok]
            o['errors'] = [r['error'] for r in rs if 'error' in r]
    return out


def svg(summary, path):
    """A small bar chart of the medians (lower is better), one panel per metric, no dependencies."""
    metrics = [('launch_fresh_window_ms', 'Launch, new profile (ms)'), ('launch_warm_window_ms', 'Launch, warm (ms)'),
               ('launch_link_fcp_ms', 'Link launch → page painted (ms)'), ('memory_total_mb', '20 tabs, total memory (MB)'),
               ('tab_switch_frame_done_ms', 'Tab switch → first frame (ms, incl. driver)'),
               ('new_tab_focus_ms', '⌘T → field focused (ms, incl. driver)'),
               ('idle_cpu_percent', 'Idle CPU, 20 tabs hidden (% of a core)')]
    browsers = [b for b in ['airc', 'arc', 'chrome'] if b in summary]
    colors = {'airc': '#3b6fd8', 'arc': '#d8573b', 'chrome': '#8a8f98'}
    labels = {'airc': 'Airc', 'arc': 'Arc', 'chrome': 'Chrome'}
    W, ph, top = 760, 64, 60
    rows = [(k, t) for k, t in metrics if any((summary[b].get(k) or {}).get('stats') for b in browsers)]
    H = top + len(rows) * (ph + 22) + 30
    e = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
         'font-family="-apple-system, Helvetica, Arial, sans-serif">', f'<rect width="{W}" height="{H}" fill="#fff"/>',
         '<text x="24" y="34" font-size="20" font-weight="600" fill="#111">Medians, same Mac, same pages (lower is better)</text>']
    y = top
    for k, title in rows:
        vals = {b: summary[b][k]['stats']['median'] for b in browsers if (summary[b].get(k) or {}).get('stats')}
        hi = max(vals.values()) or 1
        e.append(f'<text x="24" y="{y + 12}" font-size="13" fill="#333">{title}</text>')
        for i, b in enumerate(browsers):
            if b not in vals: continue
            by = y + 20 + i * 22
            w = max(2, (W - 260) * vals[b] / hi)
            e.append(f'<text x="24" y="{by + 13}" font-size="12" fill="#555">{labels[b]}</text>')
            e.append(f'<rect x="90" y="{by}" width="{w:.1f}" height="16" rx="3" fill="{colors[b]}"/>')
            e.append(f'<text x="{96 + w:.1f}" y="{by + 13}" font-size="12" fill="#111">{vals[b]:g}</text>')
        y += ph + 22
    e.append('</svg>')
    Path(path).write_text('\n'.join(e) + '\n')


# ---------------------------------------------------------------- mirror (on a box with wget)

def mirror(urls_file, out):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    pages = []
    for i, u in enumerate(Path(urls_file).read_text().split(), 1):
        d = out / f'p{i:02d}'
        subprocess.run(['wget', '-q', '-e', 'robots=off', '-U', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36', '-p', '-k', '-E', '-H',
                        '-nH', '-P', str(d / 'site'), u], timeout=180)
        path = urllib.parse.unquote(urllib.parse.urlsplit(u).path) or '/'
        for c in [path, path.rstrip('/') + '.html', path.rstrip('/') + '/index.html', path + 'index.html']:
            if (d / 'site' / c.lstrip('/')).is_file() and c != '/': path = c; break
        pages.append({'id': d.name, 'source': u, 'path': path})
    (out / 'pages.json').write_text(json.dumps(pages, indent=1) + '\n')


# ---------------------------------------------------------------- main

PROBE = None

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    for name in ['launch', 'tabs']:
        c = sub.add_parser(name)
        c.add_argument('--browser', choices=sorted(BROWSERS), required=True)
        c.add_argument('--app', type=Path)
        c.add_argument('--pages', type=Path, required=True)
        c.add_argument('--out', type=Path, required=True)
        c.add_argument('--window', type=lambda s: [int(x) for x in s.split(',')], help='x,y,w,h for browsers that take it')
        c.add_argument('--presses', type=int, default=30)
        c.add_argument('--idle', type=int, default=300)
        c.add_argument('--run', type=int, default=0)
    r = sub.add_parser('report'); r.add_argument('root', type=Path)
    r.add_argument('--json', type=Path); r.add_argument('--svg', type=Path)
    m = sub.add_parser('mirror'); m.add_argument('urls'); m.add_argument('out')
    o = p.parse_args()
    if o.cmd == 'mirror': return mirror(o.urls, o.out)
    if o.cmd == 'report':
        s = report(o.root)
        if o.json: o.json.write_text(json.dumps(s, indent=1) + '\n')
        if o.svg: svg(s, o.svg)
        print(json.dumps({b: {k: (v.get('stats') or {}).get('median') if isinstance(v, dict) and 'stats' in v else None
                              for k, v in d.items()} for b, d in s.items()}, indent=1))
        return 0
    if sys.platform != 'darwin': p.error('cases run on the build Mac')
    global PROBE
    o.out = o.out.resolve()
    if o.out.exists(): shutil.rmtree(o.out)
    o.out.mkdir(parents=True)
    PROBE = o.out / 'probe'
    run.command(['swiftc', '-O', HERE / 'arcbench_probe.swift', '-o', PROBE], 180)
    browser = BROWSERS[o.browser](o.app)
    pages = Pages(o.pages.resolve())
    result = {'case': o.cmd, 'browser': o.browser, 'run': o.run, 'version': browser.version(), 'machine': run.machine(o.app or CHROME),
              'load_before': os.getloadavg(), 'started': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'window_arg': o.window}
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    signal.alarm(900)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt('case watchdog 900 s')))
    try:
        result['settle'] = settle_load()
        result.update((case_launch if o.cmd == 'launch' else case_tabs)(o, browser, pages))
    except (Exception, KeyboardInterrupt) as e:
        result['error'] = f'{type(e).__name__}: {e}'
    finally:
        signal.alarm(0)
        pages.close()
        result['load_after'] = os.getloadavg()
        result['beacons'] = [[b.get('id'), b.get('ev'), round(b.get('t', 0)), b.get('vis')] for b in pages.beacons]
        (o.out / 'result.json').write_text(json.dumps(result, indent=1) + '\n')
        # Profiles and synthetic homes are throwaway: keep only the result.
        for d in ['profile', 'home']: shutil.rmtree(o.out / d, ignore_errors=True)
        print(json.dumps({k: v for k, v in result.items() if k not in ('machine', 'beacons')})[:3000])
    return 1 if 'error' in result else 0


if __name__ == '__main__':
    import ctypes
    if sys.platform == 'darwin':
        resp = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
        resp.argtypes = [ctypes.c_int]; resp.restype = ctypes.c_int
        run.responsible = resp
    sys.exit(main())
