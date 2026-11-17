#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Release timing check: a link that launches Airc (Airc not running) → its page's first contentful paint.

The release's window timeline (timeline.py late/atlaunch, in each release's tooling) times windows only. A link opened
while Airc is closed showed its Little Airc window in 0.8 s but painted its page at 5.3 s in 0.1.18 (arcbench), and
nothing caught it. This check measures the page itself, from outside the app, on any build (a signed one too):

- a loopback page with a paint beacon (infra/perf/arcbench_page.js: PerformanceObserver first-contentful-paint, in
  epoch ms), served under its own `pNN.localhost` host;
- the link is handed over by Launch Services, as from another app (`open -n -a <app> <url>`), so it launches Airc and
  opens Little Airc (the default for links from other apps);
- times are from the `open` call: first window (CoreGraphics window list), page script, first contentful paint.

Per app and engine: one launch with a fresh data folder that stays until its blocking rules are compiled (`--settle`),
then `--runs` link launches with that data (the app closed before each). Those are gated: the median paint must be
≤ `--budget` seconds (1.0) and no run over 2× it. One more link launch with a brand-new data folder (first launch ever)
is reported, not gated: its rules have to be compiled once before any page may load (WebKit ~4 s).

Runs on the build Mac inside the strict UI lock, in a dedicated session, with status/timing-run declared by the Linux
coordinator (common rules); the load average is recorded with every run. Builds are copied by the caller; nothing is
installed or registered beyond the app's own Launch Services entry (unregistered at the end).

    python3 infra/release/linkpaint.py --app NEW.app [--app OLD.app] --engine chromium --pages DIR --out DIR
        [--runs 5] [--budget 1.0] [--settle 60] [--env K=V ...]

`--pages`: a folder with pages.json and pNN/site/… (arcbench.py mirror); only its first page is used. Exit 0: every
app within budget; 1: over budget or a run without a paint; 2: setup error.
"""
import argparse, json, os, shutil, statistics, subprocess, sys, time
from pathlib import Path

PERF = Path(__file__).resolve().parents[1] / 'perf'
sys.path.insert(0, str(PERF))


def verdict(rows, budget):
    """Gate over the closed-app link launches of one app: median ≤ budget, none over 2× budget, all painted."""
    paints = [r.get('paint_s') for r in rows if r.get('kind') == 'closed']
    if not paints: return {'pass': False, 'why': 'no closed-app link launch'}
    missing = sum(p is None for p in paints)
    got = sorted(p for p in paints if p is not None)
    median = round(statistics.median(got), 3) if got else None
    why = []
    if missing: why.append(f'{missing} run(s) without a paint')
    if median is not None and median > budget: why.append(f'median {median} s > {budget} s')
    if got and got[-1] > 2 * budget: why.append(f'worst {got[-1]} s > {2 * budget} s')
    before = [r.get('before_main_s') for r in rows if r.get('kind') == 'closed' and r.get('before_main_s') is not None]
    return {'pass': not why, 'median_s': median, 'worst_s': got[-1] if got else None, 'runs': len(paints),
            'slow_before_main': sum(b > 0.5 for b in before),
            'why': '; '.join(why) or 'within budget'}


def main():
    import arcbench as ab
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', type=Path, action='append', required=True)
    p.add_argument('--engine', choices=['chromium', 'webkit'], required=True)
    p.add_argument('--pages', type=Path, required=True); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--runs', type=int, default=5); p.add_argument('--budget', type=float, default=1.0)
    p.add_argument('--settle', type=int, default=60, help='seconds the first plain launch may take to compile its rules')
    p.add_argument('--env', action='append', default=[], help='K=V for every launch (e.g. a test build switch)')
    p.add_argument('--no-first', action='store_true', help='skip the first-launch-ever link (reported only)')
    o = p.parse_args()
    if sys.platform != 'darwin': p.error('runs on the build Mac')
    o.out = o.out.resolve()
    if o.out.exists(): p.error(f'{o.out} exists')
    o.out.mkdir(parents=True)
    ab.PROBE = o.out / 'probe'
    ab.run.command(['swiftc', '-O', PERF / 'arcbench_probe.swift', '-o', ab.PROBE], 180)
    extra = dict(x.split('=', 1) for x in o.env)

    class Airc(ab.Airc):
        timeline = None
        def args(self, profile, window): return super().args(profile, window) + ['--engine', o.engine, '--deny-permission-prompts']
        def env(self, home):
            e = {**super().env(home), **extra}
            if self.timeline: e['AIRC_LAUNCH_TIMELINE'] = str(self.timeline)
            return e

    pages = ab.Pages(o.pages.resolve())
    page = pages.list[0]
    diagnostics = [Path.home() / 'Library/Logs/DiagnosticReports']
    crashes_before = {str(x) for d in diagnostics for x in d.glob('*')}
    summary = {'engine': o.engine, 'budget_s': o.budget, 'apps': [], 'load_before': os.getloadavg()}
    failed = False
    try:
        for n, app in enumerate(o.app):
            browser = Airc(app.resolve())
            base = o.out / f'app{n}'
            rows = []

            def launch(kind, profile, home, link, stay, tag):
                mark = pages.mark()
                browser.timeline = base / f'{tag}.timeline.json' if link else None
                r = {'kind': kind, 'tag': tag, 'load_before': os.getloadavg()}
                s = None
                try:
                    s = ab.Session(browser, profile, home, None, [pages.url(page)] if link else [])
                    w, _ = s.first_window()
                    r['window_s'] = round(w / 1000, 3)
                    if link:
                        fcp = pages.wait(lambda b: b['ev'] == 'fcp' and b['id'] == page['id'], mark, 40)
                        r['paint_s'] = round((fcp['fcp'] - s.started) / 1000, 3) if fcp else None
                        sc = pages.wait(lambda b: b['ev'] == 'script' and b['id'] == page['id'], mark, 1)
                        r['page_script_s'] = round((sc['t'] - s.started) / 1000, 3) if sc else None
                        # The app's own timeline file is written 20 s after its first entry.
                        stay = max(stay, 22)
                    if stay < 0:   # until the blocking rules are compiled (at most -stay seconds)
                        deadline = time.monotonic() - stay
                        webkit = profile / 'Blocking/WebKit'
                        while time.monotonic() < deadline and not any(webkit.glob('ContentRuleList-airc-blocking-v2-[0-9a-f]*')):
                            time.sleep(1)
                        r['compiled'] = any(webkit.glob('ContentRuleList-airc-blocking-v2-[0-9a-f]*'))
                        time.sleep(5)
                    else:
                        time.sleep(stay)
                except Exception as e:
                    r['error'] = str(e)
                finally:
                    if s: r['quit'] = s.quit()
                r['load_after'] = os.getloadavg()
                if browser.timeline and browser.timeline.exists():
                    r['timeline'] = json.loads(browser.timeline.read_text())
                    # macOS's part before Airc's main (from process start): on the build Mac about half the launches of
                    # a Chromium build spend 0.6–1.3 s here, before any app code runs.
                    m = next((e['ms'] for e in r['timeline'] if e['name'] == 'main'), None)
                    r['before_main_s'] = round(m / 1000, 3) if m is not None else None
                print('ROW ' + json.dumps({k: v for k, v in r.items() if k != 'timeline'}), flush=True)
                rows.append(r)
                time.sleep(3)

            base.mkdir()
            profile, home = base / 'data', base / 'home'
            launch('settle', profile, home, False, -o.settle, 'settle')
            for i in range(1, o.runs + 1):
                launch('closed', profile, home, True, 4, f'closed{i}')
            if not o.no_first:
                launch('first', base / 'data-first', base / 'home-first', True, 4, 'first')
            v = verdict(rows, o.budget)
            failed |= not v['pass']
            summary['apps'].append({'app': str(app), 'version': browser.version(), 'verdict': v, 'rows': rows})
            print('VERDICT ' + json.dumps({'app': str(app), **v}), flush=True)
            for d in ['data', 'home', 'data-first', 'home-first']: shutil.rmtree(base / d, ignore_errors=True)
    finally:
        pages.close()
        for app in o.app:
            subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                            '-u', str(app.resolve())], check=False, capture_output=True)
        summary['load_after'] = os.getloadavg()
        summary['new_crash_reports'] = [x.name for d in diagnostics for x in d.glob('*')
                                        if str(x) not in crashes_before and 'Airc' in x.name]
        failed |= bool(summary['new_crash_reports'])
        (o.out / 'result.json').write_text(json.dumps(summary, indent=1) + '\n')
    return 1 if failed else 0


if __name__ == '__main__':
    if sys.platform == 'darwin':
        import ctypes
        sys.path.insert(0, str(PERF))
        import run as _run
        resp = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
        resp.argtypes = [ctypes.c_int]; resp.restype = ctypes.c_int
        _run.responsible = resp
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:
        print(f'linkpaint: {type(e).__name__}: {e}', file=sys.stderr)
        sys.exit(2)
