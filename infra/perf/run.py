#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Bounded macOS benchmark. Missing instrumentation is UNKNOWN, never a pass."""
import argparse, ctypes, datetime, fcntl, json, os, re, signal, subprocess, sys, threading, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def command(args, timeout=20):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name}: exit {p.returncode}: {p.stderr[-400:]}')
    return p.stdout

def processes():
    rows = {}
    for line in command(['ps', '-axo', 'pid=,ppid=,lstart=,time=,command=']).splitlines():
        parts = line.split(None, 8)
        if len(parts) == 9:
            pid, parent = map(int, parts[:2])
            clock = parts[7].replace('-', ':').split(':')
            seconds = sum(float(x) * y for x, y in zip(reversed(clock), [1,60,3600,86400]))
            rows[pid] = {'parent':parent,'birth':' '.join(parts[2:7]),'cpu':seconds,'command':parts[8]}
    return rows

def footprint(pid):
    out = command(['vmmap', '--summary', str(pid)], 15)
    m = re.search(r'^Physical footprint:\s*([\d.]+)([KMGT]?)', out, re.M)
    if not m:
        raise RuntimeError('vmmap did not report physical footprint')
    return float(m[1]) * 1024 ** (' KMGT'.index(m[2]) if m[2] else 0) / 1e6

DIAGNOSE_TOOLS = (('vmmap', ['vmmap', '--summary']), ('footprint', ['footprint', '--noCategories', '-p']),
                  ('heap', ['heap', '-s', '-H']))

def diagnose_main(pid, out, tag=''):
    """Saves `vmmap --summary`, `footprint` and `heap` (malloc by class, sorted by size) for one process; with
    --app-env=MallocStackLogging=lite also `malloc_history -allBySize` (stacks). Returns {tool: file or error}."""
    found = {}
    tools = list(DIAGNOSE_TOOLS)
    if DIAGNOSE_STACKS: tools.append(('malloc_history', ['malloc_history', str(pid), '-allBySize']))
    for name, argv in tools:
        path = out / f'diag{tag}-{name}.txt'
        try:
            r = subprocess.run(argv if name == 'malloc_history' else [*argv, str(pid)], capture_output=True, text=True,
                               timeout=300)
            path.write_text(r.stdout + (('\n--- stderr\n' + r.stderr) if r.stderr.strip() else ''))
            found[name] = path.name if r.returncode == 0 or r.stdout else f'exit {r.returncode}: {r.stderr[:200]}'
        except Exception as e: found[name] = f'error: {e}'
    return found

def rusage_footprint_mb(pid):
    """phys_footprint from proc_pid_rusage (rusage_info_v2; the same value vmmap reports), cheap enough to sample
    every 200 ms. None when the process is gone."""
    buf = ctypes.create_string_buffer(512)
    if ctypes.CDLL(None).proc_pid_rusage(pid, 2, buf) != 0: return None
    return int.from_bytes(buf.raw[72:80], 'little') / 1e6

def process_start(pid):
    """Epoch seconds the process started (proc_bsdinfo pbi_start_tvsec/usec), to line samples up with the app's
    LaunchTimeline (ms since process start)."""
    buf = ctypes.create_string_buffer(136)
    if ctypes.CDLL(None).proc_pidinfo(pid, 3, ctypes.c_uint64(0), buf, 136) != 136: return None
    return int.from_bytes(buf.raw[120:128], 'little') + int.from_bytes(buf.raw[128:136], 'little') / 1e6

class FootprintTrace(threading.Thread):
    """--diagnose: the main process's footprint every 200 ms from launch, as (ms since process start, MB)."""
    def __init__(self, pid, peak_mb=None, out=None, tag=''):
        super().__init__(daemon=True); self.pid = pid; self.samples = []; self.done = threading.Event()
        self.start_epoch = process_start(pid)
        # --diagnose-peak: one dump (heap, vmmap, malloc stacks with MallocStackLogging) the first time the footprint
        # crosses peak_mb, to see what a transient launch peak is made of.
        self.peak_mb, self.out, self.tag, self.peak_dump = peak_mb, out, tag, None
    def run(self):
        while not self.done.wait(.2):
            mb = rusage_footprint_mb(self.pid)
            if mb is None: return
            self.samples.append((round((time.time() - (self.start_epoch or 0)) * 1000), round(mb, 1)))
            if self.peak_mb and self.peak_dump is None and mb >= self.peak_mb:
                self.peak_dump = {'at_ms': self.samples[-1][0], 'mb': round(mb, 1),
                                  'files': diagnose_main(self.pid, self.out, self.tag + '-peak')}
    def save(self, path):
        self.done.set()
        if self.ident: self.join(2)
        path.write_text(json.dumps({'pid': self.pid, 'start_epoch': self.start_epoch, 'samples': self.samples}))
        peak = max(self.samples, key=lambda s: s[1], default=None)
        return {'file': path.name, 'peak_mb': peak and peak[1], 'peak_ms': peak and peak[0], 'count': len(self.samples),
                **({'peak_dump': self.peak_dump} if self.peak_mb else {})}

def kind(command_line, main=False):
    """A process's role from its command line: main, gpu-process, renderer, utility:<service>, …."""
    if main: return 'main'
    t = re.search(r'--type=(\S+)', command_line)
    if not t: return 'other:' + Path(command_line.split(' --')[0]).name
    sub = re.search(r'--utility-sub-type=(\S+)', command_line)
    return t[1] + (':' + sub[1].split('.')[-1] if sub else '')

class Instance:
    def __init__(self, executable, marker):
        self.executable, self.marker = str(executable), str(marker)
        self.pid = None
        self.owned = {}
        self.before = processes()
    def discover(self):
        rows = processes()
        if self.pid is None:
            for pid, row in rows.items():
                if pid not in self.before and row['command'].startswith(self.executable) and self.marker in row['command']:
                    self.pid = pid
                    self.owned[pid] = row['birth']
                    break
        if self.pid in rows and self.owned.get(self.pid) == rows[self.pid]['birth']:
            # WebKit XPC services are parented to launchd. Responsibility, not
            # process-name matching or a before/after diff, establishes ownership.
            for _ in range(4):
                for pid, row in rows.items():
                    if pid in self.before:
                        continue
                    parent = rows.get(row['parent'])
                    owned_parent = parent and self.owned.get(row['parent']) == parent['birth']
                    if owned_parent or responsible(pid) == self.pid:
                        self.owned[pid] = row['birth']
        return {p:r for p,r in rows.items() if self.owned.get(p) == r['birth']}
    def cleanup(self):
        for sig in [signal.SIGTERM, signal.SIGKILL]:
            rows = self.discover()
            for pid in reversed(list(rows)):
                try: os.kill(pid, sig)
                except ProcessLookupError: pass
            time.sleep(0.5)

def event(path, kind, timeout=20):
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    value = json.loads(line)
                    if value.get('event') == kind: return value
                except ValueError: pass  # writer may be between writes
        time.sleep(.1)
    raise RuntimeError(f'app event {kind} timed out after {timeout}s')

def loaded(page):
    """A page counts as loaded when it committed its site, not an error page: a title that isn't its address."""
    url, title = page.get('url') or '', (page.get('title') or '').strip()
    host = re.sub(r'^\w+://(www\.)?', '', url).split('/')[0]
    return bool(title) and not url.startswith(('chrome-error:', 'about:', 'data:')) and title not in (url, host)

def chrome_pages(profile):
    """Chrome's open pages (URL, title) from its DevTools endpoint, which run.py enables on a throwaway profile."""
    port = int((profile / 'DevToolsActivePort').read_text().split()[0])
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list', timeout=10) as r:
        targets = json.load(r)
    return [{'url': t.get('url'), 'title': t.get('title')} for t in targets if t.get('type') == 'page']

def total_footprint(instance, attempts=3):
    """All of a run's processes' footprint; a helper exiting between discovery and vmmap (a closed tab's renderer
    winding down) is retried with a fresh process list instead of losing the measurement."""
    for attempt in range(attempts):
        try: return sum(footprint(p) for p in instance.discover())
        except RuntimeError:
            if attempt == attempts - 1: raise
            time.sleep(2)

def control_action(out, tag, action):
    """Atomically replaces the app's control file (it watches the folder for writes)."""
    temporary = out/f'control{tag}.tmp'
    temporary.write_text(json.dumps(action))
    temporary.replace(out/f'control{tag}.json')

def measure(name, app, args, marker, out, instrumented=False, tag='', expect=(8, 22, 3, 6), leak=True,
            sample_at=None, pages=None, cpu_seconds=30, launch_env=(), diagnose=False):
    """One launch. Set cpu_seconds=0 for memory-only comparisons (no CPU metric). Airc (`instrumented`) waits for its workload, Chrome until `sample_at` seconds after launch (the
    matched Airc run's memory-sample age, so both are sampled as long after launch); then memory, 30 s of idle CPU
    and, for Airc's reference run, the 100-tab leak cycle. `pages`: Chrome's page list, read before the sample."""
    instance = Instance(app / 'Contents/MacOS' / ('Airc' if name == 'airc' else 'Google Chrome'), marker)
    result = {'errors':[], 'metrics':{}}
    m = result['metrics']
    events = out/f'events{tag}.jsonl'
    trace = None
    try:
        start = time.monotonic()
        # --foreground (Airc only): a normal activating launch in a dedicated UI session, so the window is key while
        # the timed actions run (timings can differ from hidden background windows). Chrome always stays background.
        front = FOREGROUND and name == 'airc'
        launch = ['open','-n'] if front else ['open','-g','-j','-n']
        launch += ['--env', f'CFFIXED_USER_HOME={out / (name+tag+"-home")}']
        if front: launch += ['--env', 'AIRC_UI_DEDICATED_SESSION=1']
        for setting in launch_env: launch += ['--env', setting]
        command([*launch, app, '--args', *args])
        deadline = start + 20
        while time.monotonic() < deadline:
            instance.discover()
            if instance.pid: break
            time.sleep(.02)
        if not instance.pid: raise RuntimeError('launch PID not found within 20 s')
        if diagnose or TRACE or PEAK_MB:
            trace = FootprintTrace(instance.pid, PEAK_MB, out, tag); trace.start()
        command([out / 'window', str(instance.pid), *(['keep'] if front else [])], 22)
        m['first_window_ms'] = (time.monotonic()-start)*1000
        # This is external first-window observation, NOT cold interactive launch.
        observed = []
        sample = instance.discover()
        for pid in sample:
            try: observed.append({'pid':pid, 'main':pid==instance.pid, 'mb':footprint(pid)})
            except Exception as e: result['errors'].append(str(e))
        result['early_processes'] = observed
        m['early_main_mb'] = next((x['mb'] for x in observed if x['main']), None)
        if diagnose:
            # At the first window: the launch's peak (cold blocking compile) is still in the process.
            result['diagnosis_early'] = diagnose_main(instance.pid, out, tag + '-early')
        ready = event(events,'workload_ready',180) if instrumented else None
        if ready and (ready.get('loaded_tabs'),ready.get('unloaded_tabs'),ready.get('profiles'),ready.get('spaces')) != expect:
            raise RuntimeError('app did not confirm the reference workload')
        result['reference_verified'] = bool(ready)
        if ready and 'malloc_large_cache' in ready: result['malloc_large_cache'] = ready['malloc_large_cache']
        if ready: result['ready_seconds'] = time.monotonic()-start
        if not front:
            # Hide again once the workload is up: the first hide (at the first window) can come before the browser
            # window exists, which then opens on screen and draws its page while Chrome's stay hidden. Checked, and
            # recorded with the result, before the settle and every sample.
            for _ in range(3):
                state = command([out / 'window', str(instance.pid), 'hide'], 10).strip()
                if state == 'hidden': break
            result['hidden_for_sample'] = state == 'hidden'
            if state != 'hidden': result['errors'].append('window still on screen after hiding: samples not like for like')
        time.sleep(60 if instrumented else max(0, start+(sample_at or 60)-time.monotonic()))
        if instrumented:
            # The app's own page check (title, URL, visibility, animation frames), emitted once its loads are done.
            try:
                seen = event(events, 'pages', 30)
                result['pages'] = seen.get('pages', [])
                result['window_visible'] = seen.get('window_visible')
            except RuntimeError as e: result['errors'].append(f'page check: {e}')   # an app without it
        elif pages:
            try: result['pages'] = pages()
            except Exception as e: result['errors'].append(f'page list: {e}')
        if 'pages' in result:
            result['pages_loaded'] = sum(map(loaded, result['pages']))
        sample = instance.discover()
        if instance.pid not in sample:
            raise RuntimeError('scenario exited before steady state; reference/perf scenario hook required')
        result['memory_sample_start_seconds'] = time.monotonic()-start
        memory = []
        for pid in sample:
            try: memory.append({'pid':pid,'main':pid==instance.pid,'kind':kind(sample[pid]['command'],pid==instance.pid),
                                'executable':Path(sample[pid]['command'].split(' --')[0]).name,
                                'mb':footprint(pid)})
            except Exception as e: result['errors'].append(str(e))
        result['memory_sample_end_seconds'] = time.monotonic()-start
        result['steady_processes'] = memory
        after_memory = instance.discover()
        if len(memory) == len(sample) and set(sample) == set(after_memory):
            m['total_mb'] = sum(x['mb'] for x in memory)
        else:
            result['errors'].append('incomplete footprint sample or process set changed during memory sampling')
        m['main_mb'] = next((x['mb'] for x in memory if x['main']), None)
        m['renderer_count'] = sum(1 for x in memory if x['kind'] == 'renderer')
        if cpu_seconds > 0:
            begin = instance.discover(); t0 = time.monotonic()
            time.sleep(cpu_seconds)
            end = instance.discover(); elapsed = time.monotonic()-t0
            if instance.pid not in begin or instance.pid not in end or set(begin) != set(end):
                result['errors'].append('process set changed during idle CPU interval')
            else:
                m['idle_cpu_percent'] = 100 * sum(end[p]['cpu']-begin[p]['cpu'] for p in begin) / elapsed
                # Which processes burn the idle CPU (the browser, GPU, each renderer and utility), hottest first.
                result['idle_cpu_processes'] = sorted(({'pid':p,'kind':kind(begin[p]['command'],p==instance.pid),
                    'cpu_percent':round(100*(end[p]['cpu']-begin[p]['cpu'])/elapsed,3)} for p in begin),
                    key=lambda x:-x['cpu_percent'])
        if diagnose:
            # --diagnose: what the main process holds, after the idle CPU interval (heap pauses it, so never before a
            # metric) and before the timed actions. Diagnosis only: these runs' timings are not published.
            result['diagnosis'] = diagnose_main(instance.pid, out, tag)
        if trace:
            result['footprint_trace'] = trace.save(out / f'diag{tag}-trace.json')
        if instrumented and leak:
            # Only now the timed actions (they show every loaded page once): memory and idle CPU above were taken
            # from the same untouched state as Chrome's.
            control_action(out, tag, {'action':'measure'})
            timings = event(events,'timings',120)
            result['timings'] = timings
            m.update({k:v for k,v in timings.items() if k != 'event' and isinstance(v,(int,float))})
            # Use a fresh baseline immediately before the leak cycle, not startup memory.
            m['leak_before_mb'] = total_footprint(instance)
            control_action(out, tag, {'action':'leak','count':100,'url':'about:blank','page_timeout_seconds':20})
            done = event(events,'leak_closed',120)
            if done.get('opened') != 100 or done.get('closed') != 100:
                raise RuntimeError('app did not verify all 100 leak cycles')
            time.sleep(60)
            m['leak_after_mb'] = total_footprint(instance)
            m['leak_ratio'] = m['leak_after_mb']/m['leak_before_mb']
            result['leak_verified'] = True
    except Exception as e:
        result['errors'].append(str(e))
    finally:
        if trace and 'footprint_trace' not in result:
            result['footprint_trace'] = trace.save(out / f'diag{tag}-trace.json')
        instance.cleanup()
    return result

def budgets(data):
    a = data.get('airc',{}).get('metrics',{})
    specs = [
        ('launch','Cold interactive launch ≤500 ms WebKit / ≤1000 ms Chromium'),
        ('space','Space input to presented frame ≤16 ms, no dropped frames'),
        ('swipe','Swipe tracks every frame'),('feedback','Sidebar feedback next frame'),
        ('tab','Loaded tab fully painted ≤50 ms'),('sidebar-ready','Sidebar interactive ≤300 ms after window'),
        ('new-space','New Space and profile ≤1 frame'),('sidebar-toggle','Hide/show 100–110 ms'),
        ('command','Command Bar first frame ≤8 ms; local results same frame; suggestions ≤100 ms'),
        ('MEM-1','Main process ≤150 MB'),('MEM-2','Empty loaded profile ≤40 MB'),
        ('MEM-3','Unload timeout/pressure; protect visible/audio/dirty tabs; restore state'),
        ('MEM-4','Total ≤Chrome; target ≤0.8×Chrome'),('MEM-5','100 open/close cycles: final ≤1.05×baseline'),
        ('MEM-6','No-media idle CPU <1%; no idle timers')]
    rows = [{'id':key,'budget':desc,'status':'unknown',
             'reason':'Current showcase is not the reference workload; required app instrumentation missing'}
            for key,desc in specs]
    if data.get('airc',{}).get('reference_verified'):
        checks = {'launch':('interactive_ms',LAUNCH_LIMIT_MS), 'space':('space_frame_ms',16),
                  'tab':('tab_paint_ms',50),'sidebar-ready':('sidebar_ready_ms',300),
                  'new-space':('new_space_ms',1000/120), 'MEM-1':('main_mb',150),
                  'MEM-2':('empty_profile_mb',40),'MEM-5':('leak_ratio',1.05)}
        for row in rows:
            if row['id'] in checks:
                metric,limit = checks[row['id']]
                if isinstance(a.get(metric),(int,float)):
                    row.update(status='pass' if a[metric]<=limit else 'fail',value=a[metric],reason='Instrumented reference run')
        # MEM-4: the same pages loaded in both browsers (the reference 8, and all 30), each page checked.
        fair = data.get('mem4', {}).get('8', {})
        if isinstance(fair.get('ratio'), (int, float)):
            row = next(r for r in rows if r['id'] == 'MEM-4')
            other = data.get('mem4', {}).get('30', {}).get('ratio')
            note = f"same 8 URLs: {fair['airc_mb']:.0f} vs {fair['chrome_mb']:.0f} MB" + (
                f"; all 30: ratio {other:.2f}" if isinstance(other, (int, float)) else '')
            if fair.get('verified'):
                row.update(status='pass' if fair['ratio'] <= 1 else 'fail', value=round(fair['ratio'], 3),
                           reason=note + (' (target ≤0.8 met)' if fair['ratio'] <= 0.8 else ' (target ≤0.8 missed)'))
            else:
                row.update(value=round(fair['ratio'], 3), reason=note + '; not every page loaded in both browsers')
        # MEM-6: idle CPU at or over 1% fails outright; under it, timer absence still isn't demonstrated.
        # A shown page that runs animations isn't an idle window (idlecpu: the reference Wikipedia page's pulsing dot
        # draws at the display's rate in Chrome too, ~10%). Then the number is reported, not judged: MEM-6's verdict
        # for Airc itself comes from `--script idlecpu` (a static page in front, per state, both engines).
        cpu = a.get('idle_cpu_percent')
        shown = [p for p in data.get('airc', {}).get('pages', []) if p.get('shown')]
        moving = sum(int(p.get('animations') or 0) for p in shown)
        if isinstance(cpu, (int, float)):
            row = next(r for r in rows if r['id'] == 'MEM-6')
            if moving and cpu >= 1:
                row.update(value=round(cpu, 3), status='unknown',
                           reason=f'idle CPU {cpu:.2f}% (all processes, 30 s) with the shown page running {moving} '
                                  f'animation(s) ({shown[0].get("url", "?")}): page content, not an idle window; '
                                  'judge MEM-6 with --script idlecpu')
            else:
                row.update(value=round(cpu, 3), status='fail' if cpu >= 1 else 'unknown',
                           reason=f'idle CPU {cpu:.2f}% (all processes, 30 s)' + ('' if cpu >= 1 else '; no-timer criterion unproven'))
        # Composite requirements (frame drops, timer absence, pressure exclusions)
        # remain unknown until separately demonstrated; never infer from a proxy.
    return rows

def mem4(data):
    """MEM-4 like for like: totals for the same URLs loaded in both browsers, 8 (the reference) and all 30."""
    rows = {}
    for label, airc, chrome, n in [('8', 'airc', 'chrome_8', 8), ('30', 'airc_30', 'chrome', 30)]:
        a, c = data.get(airc, {}), data.get(chrome, {})
        am, cm = a.get('metrics', {}).get('total_mb'), c.get('metrics', {}).get('total_mb')
        row = {'pages': n, 'airc': airc, 'chrome': chrome, 'airc_mb': am, 'chrome_mb': cm,
               'airc_pages_loaded': a.get('pages_loaded'), 'chrome_pages_loaded': c.get('pages_loaded'),
               'airc_renderers': a.get('metrics', {}).get('renderer_count'),
               'chrome_renderers': c.get('metrics', {}).get('renderer_count'),
               'airc_cpu_percent': a.get('metrics', {}).get('idle_cpu_percent'),
               'chrome_cpu_percent': c.get('metrics', {}).get('idle_cpu_percent'),
               'airc_sampled_at_s': a.get('memory_sample_start_seconds'),
               'chrome_sampled_at_s': c.get('memory_sample_start_seconds')}
        row['verified'] = row['airc_pages_loaded'] == n and row['chrome_pages_loaded'] == n
        row['ratio'] = am / cm if isinstance(am, (int, float)) and isinstance(cm, (int, float)) and cm else None
        cpu = (row['airc_cpu_percent'], row['chrome_cpu_percent'])
        row['cpu_ratio'] = cpu[0] / cpu[1] if all(isinstance(x, (int, float)) for x in cpu) and cpu[1] else None
        rows[label] = row
    return rows

FOREGROUND = False

def machine(app):
    """What the numbers were measured on: hardware, macOS, and the two browsers' versions (from their Info.plist)."""
    def plist(bundle, key):
        try: return command(['/usr/libexec/PlistBuddy','-c',f'Print :{key}',Path(bundle)/'Contents/Info.plist']).strip()
        except Exception: return None
    def sysctl(name):
        try: return command(['sysctl','-n',name]).strip()
        except Exception: return None
    try: macos = command(['sw_vers','-productVersion']).strip()
    except Exception: macos = None
    return {'cpu':sysctl('machdep.cpu.brand_string'),'cores':sysctl('hw.ncpu'),
            'memory_gb':round(int(sysctl('hw.memsize') or 0)/2**30) or None,'macos':macos,
            'airc_version':plist(app,'CFBundleShortVersionString'),'airc_revision':plist(app,'AircRevision'),
            'chrome_version':plist('/Applications/Google Chrome.app','CFBundleShortVersionString')}

# Spec 2.12: cold launch ≤500 ms on the WebKit dev engine, ≤1 s with Chromium and all profiles loaded.
LAUNCH_LIMIT_MS = 500


def chrome_args(profile, urls):
    # A fresh throwaway profile (never the owner's); DevTools on a random local port lists the pages for the load check.
    return [f'--user-data-dir={profile}','--no-first-run','--no-default-browser-check','--disable-background-mode',
            '--autoplay-policy=user-gesture-required','--remote-debugging-port=0',*urls]

def write(data, out, root):
    data['budgets'] = budgets(data)
    data['mem4'] = mem4(data)
    data['budgets'] = budgets(data)
    a,c = [data.get(k,{}).get('metrics',{}) for k in ['airc','chrome_8']]
    # Like-for-like ratios only (the same 8 pages in both); other keys stay null.
    data['ratios'] = {k: (a[k]/c[k] if k in ('total_mb','main_mb','idle_cpu_percent') and isinstance(a.get(k),(int,float))
                          and isinstance(c.get(k),(int,float)) and c[k] else None) for k in set(a)|set(c)}
    keys = ['airc','chrome_8','airc_30','chrome']
    summary = '\n'.join([data['timestamp'],*data['notes'],*[f'{k}: {data.get(k,{}).get("metrics",{})}; errors: {data.get(k,{}).get("errors",[])}' for k in keys],
                         *[f"MEM-4 {n} pages: Airc {r['airc_mb'] or 0:.0f} MB / Chrome {r['chrome_mb'] or 0:.0f} MB = "
                           f"{r['ratio'] if r['ratio'] is None else round(r['ratio'],3)}; loaded {r['airc_pages_loaded']}/{n} and "
                           f"{r['chrome_pages_loaded']}/{n}; idle CPU {r['airc_cpu_percent']} vs {r['chrome_cpu_percent']}"
                           for n,r in data['mem4'].items()],
                         *[f"{b['id']}: {b['status']} — {b['budget']}" + (f" ({b['reason']})" if b.get('value') is not None else '')
                           for b in data['budgets']]])+'\n'
    for directory in [out,root]:
        (directory/'results.json').write_text(json.dumps(data,indent=2)+'\n')
        (directory/'summary.txt').write_text(summary)
    return summary

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app',type=Path,default=ROOT/'build/Airc.app')
    parser.add_argument('--output',type=Path,default=Path.home()/'arcfork/perf')
    parser.add_argument('--instrumented',action='store_true',help='requires the app perf hook described in infra/perf/README.md')
    parser.add_argument('--no-30',dest='thirty',action='store_false',help='skip the all-30-loaded MEM-4 variant (Airc and Chrome)')
    parser.add_argument('--airc-only',action='store_true',help='only the Airc reference run (before/after iteration; no MEM-4)')
    parser.add_argument('--foreground',action='store_true',help='Airc launches activate (run inside AIRC_UI_DEDICATED_SESSION=1 '
                        'scripts/ui-check-lock.py): the window is key during the timed actions; Chrome stays background')
    parser.add_argument('--diagnose',action='store_true',help='also save vmmap/footprint/heap of the Airc main process '
                        'after its idle CPU sample (diag-*.txt); diagnosis only, never for published numbers')
    parser.add_argument('--diagnose-peak',type=float,metavar='MB',help='with the trace: dump heap/vmmap (and malloc stacks '
                        'with MallocStackLogging) when the main footprint first reaches MB')
    parser.add_argument('--trace',action='store_true',help='only the main process footprint every 200 ms (diag-trace.json), '
                        'no dumps: cheap enough for measured runs')
    parser.add_argument('--app-env',action='append',default=[],help='KEY=VALUE for the Airc launch, e.g. MallocStackLogging=lite '
                        '(with --diagnose adds malloc_history stacks)')
    parser.add_argument('--app-arg',action='append',default=[],help='extra Airc argument for A/B runs, e.g. --app-arg=--airc-switches=aperitifHelpers=off')
    options = parser.parse_args()
    # The apps get these paths as arguments and start with / as their directory: a relative --output silently
    # gives them nowhere to write their events (every launch then fails at the window probe).
    options.output, options.app = options.output.resolve(), options.app.resolve()
    global LAUNCH_LIMIT_MS, FOREGROUND, DIAGNOSE_STACKS, TRACE, PEAK_MB
    TRACE = options.trace
    PEAK_MB = options.diagnose_peak
    FOREGROUND = options.foreground
    DIAGNOSE_STACKS = any(e.startswith('MallocStackLogging=') for e in options.app_env)
    LAUNCH_LIMIT_MS = 1000 if 'Chromium' in options.app.name else 500
    if sys.platform != 'darwin': parser.error('requires the build Mac')
    signal.alarm(WATCHDOG_S)
    options.output.mkdir(parents=True,exist_ok=True)
    lock = (options.output/'.lock').open('w')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ')
    out = options.output/stamp; out.mkdir()
    data = {'schema_version':1,'timestamp':stamp,'complete':False,'notes':[
        'Background, hidden windows; not fullscreen acceptance tests. Single launch; caches not flushed.',
        ('Airc uses instrumented perf scenario.' if options.instrumented else 'Airc fallback is showcase, NOT 30-tab reference.')
        + ' MEM-4 is like for like: Chrome loads the same 8 URLs (chrome_8), and both load all 30 (airc_30, chrome).',
        'Chrome uses one throwaway profile; Airc the reference three. Chrome is sampled as long after launch as the matched Airc run.',
        'CPU uses process CPU-time deltas, one-core percent; phys_footprint uses vmmap, decimal MB.',
        'Page waits: Airc ≤20 s per page then stops loading; a page counts as loaded when its title is not its address.'],
        'workload':json.loads((ROOT/'infra/perf/workload.json').read_text())}
    data['machine'] = machine(options.app)
    data['engine'] = 'chromium' if 'Chromium' in options.app.name else 'webkit'
    data['app_args'] = options.app_arg
    data['app_env'] = options.app_env
    if options.diagnose or DIAGNOSE_STACKS: data['notes'].append('DIAGNOSIS run (--diagnose/MallocStackLogging): not for publishing.')
    if options.app_env: data['notes'].append('A/B: Airc launched with environment ' + ' '.join(options.app_env))
    data['foreground'] = options.foreground
    # Other agents compile on the build Mac: keep the load next to the timings (1, 5, 15 min averages).
    data['load'] = {'start': list(os.getloadavg())}
    if options.foreground:
        data['notes'][0] = ('Airc in a dedicated foreground session (window key; AIRC_UI_DEDICATED_SESSION=1), Chrome in '
                            'hidden background windows. Single launch; caches not flushed.')
    if options.app_arg: data['notes'].append('A/B: Airc launched with ' + ' '.join(options.app_arg))
    urls = [t['url'] for t in data['workload']['tabs']]
    recent = [t['url'] for t in data['workload']['tabs'] if t.get('recent')]
    try:
        screen = subprocess.run(['screen','-ls'],capture_output=True,text=True,timeout=10)
        data['engine_build_running'] = 'airc-engine' in screen.stdout
        if data['engine_build_running']: data['notes'].append('NOISY: Chromium engine build running concurrently.')
        command(['swiftc',ROOT/'infra/perf/window.swift','-o',out/'window'],120)
        def airc(tag, extra):
            (out/f'airc{tag}-home'/'Library').mkdir(parents=True)
            args = ['--snapshot',str(out/f'snapshots{tag}'),'--script','perf' if options.instrumented else 'showcase',
                    '--ephemeral','--data-dir',str(out/f'airc{tag}-data')]
            if options.instrumented:
                args += ['--perf-workload',str(ROOT/'infra/perf/workload.json'),'--perf-events',str(out/f'events{tag}.jsonl'),
                         '--perf-control',str(out/f'control{tag}.json'),*extra]
            return args + options.app_arg
        def chrome(tag, pages, sample_at):
            (out/f'chrome{tag}-home'/'Library').mkdir(parents=True)
            # Dedicated child directory avoids stale sessions and never reuses owner data.
            profile = options.output/'chrome-profile'/(stamp+tag); profile.mkdir(parents=True)
            return measure('chrome',Path('/Applications/Google Chrome.app'),chrome_args(profile,pages),profile,out,
                           tag=tag,sample_at=sample_at,pages=lambda: chrome_pages(profile))
        age = lambda key: data.get(key,{}).get('memory_sample_start_seconds') or 80
        data['airc'] = measure('airc', options.app.resolve(),airc('',[]),out/'airc-data',out,options.instrumented,
                               launch_env=options.app_env, diagnose=options.diagnose)
        log = out/'snapshots/log.txt'
        if log.exists():
            text = log.read_text()
            match = re.search(r'space switch \(click/key path, ms\): ([\d., ]+)',text)
            if match: data['airc']['metrics']['space_layout_ms'] = max(map(float,match[1].split(',')))
            data['notes'].append('space_layout_ms measures synchronous layout, not a presented frame.')
        write(data, out, options.output)
        if not options.airc_only:
            data['chrome_8'] = chrome('-8', recent, age('airc'))
            write(data, out, options.output)
            if options.instrumented and options.thirty:
                data['airc_30'] = measure('airc', options.app.resolve(), airc('-30', ['--perf-load', 'all']),
                                          out/'airc-30-data', out, True, tag='-30', expect=(30, 0, 3, 6), leak=False)
                write(data, out, options.output)
            # Chrome with all 30 pairs with airc_30; --no-30 skips both (as documented, ~4 minutes less).
            if options.thirty: data['chrome'] = chrome('', urls, age('airc_30'))
    except (Exception, Deadline) as e: data['error'] = str(e)
    data['load']['end'] = list(os.getloadavg())
    summary = write(data, out, options.output)
    print(summary)
    return 3  # incomplete, not a false green acceptance run

DIAGNOSE_STACKS = False
TRACE = False
PEAK_MB = None

# The whole run: four launches (~10 minutes), inside the nightly's 15-minute perf step.
WATCHDOG_S = 840

class Deadline(BaseException):
    """The watchdog: not an Exception, so a launch's error handling can't swallow it and start the next launch."""

if __name__ == '__main__':
    if sys.platform == 'darwin':
        responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
        responsible.argtypes = [ctypes.c_int]; responsible.restype = ctypes.c_int
    def stop(signum, frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,stop)
    def deadline(signum, frame): raise Deadline(f'whole benchmark exceeded {WATCHDOG_S} seconds')
    signal.signal(signal.SIGALRM,deadline)
    sys.exit(main())
