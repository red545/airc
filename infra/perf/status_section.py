# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Read optional benchmark artifacts without affecting the existing status page."""
import html
import json
import math

def render(runs_dir):
    # Nightly runs (runs/<run>/results.json) and repeated runs combined by aggregate.py (perf/<name>/results.json),
    # oldest to newest by measurement time. A repeated run's headline values are medians; `spread` has min–max.
    history = []
    for path in [*runs_dir.glob('*/results.json'), *(runs_dir.parent / 'perf').glob('*/results.json')]:
        try:
            data = json.loads(path.read_text())
            if data.get('schema_version') == 1: history.append((path, data))
        except (OSError, ValueError, AttributeError):
            continue
    history = sorted(history, key=lambda item: str(item[1].get('timestamp', '')))
    webkit = [h for h in history if h[1].get('engine') == 'webkit']
    history = [h for h in history if h[1].get('engine') != 'webkit'][-30:]
    gaps = render_gaps(runs_dir)
    if not history: return '<p>No reference performance runs yet.</p>' + gaps
    path, latest = history[-1]
    esc = lambda x: html.escape(str(x))
    def num(value):
        return f'{value:.2f}' if isinstance(value,(int,float)) and math.isfinite(value) else 'unavailable'
    def cell(side, key, data=None):
        data = latest if data is None else data
        value = data.get(side,{}).get('metrics',{}).get(key)
        s = data.get(side,{}).get('spread',{}).get(key)
        return num(value) + (f' <span class="dim">({s["min"]:.2f}–{s["max"]:.2f})</span>' if s and s.get('n',0) > 1 else '')
    def was(side, key, data=None, ratio=False):
        # Before → after from aggregate.py --baseline (an earlier aggregate's own medians); '–' when either is missing.
        data = latest if data is None else data
        b = data.get('baseline') or {}
        if ratio: old, new = b.get('ratios', {}).get(key), data.get('ratios', {}).get(key)
        else: old, new = b.get('metrics', {}).get(side, {}).get(key), data.get(side, {}).get('metrics', {}).get(key)
        ok = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
        if not (ok(old) and ok(new)): return '–'
        return f'{num(old)} → {num(new)}' + (f' <span class="dim">({(new - old) / old * 100:+.0f}%)</span>' if old and not ratio else '')
    def since(data=None):
        b = (latest if data is None else data).get('baseline') or {}
        return esc(b.get('label') or str(b.get('timestamp', ''))[:10]) + ' → today' if b else ''
    href = lambda p: esc(p.relative_to(runs_dir.parent).as_posix())
    # Like for like: Chrome with the same 8 pages as Airc's reference run, when the run has it (older runs: 30 tabs).
    chrome = 'chrome_8' if 'chrome_8' in latest else 'chrome'
    rows = []
    for key, title in [('first_window_ms','First window observed (ms; proxy)'),('early_main_mb','Early main footprint (MB; diagnostic)'),('main_mb','Main physical footprint at 60 s (MB)'),
                       ('total_mb','All-process physical footprint (MB)'),('idle_cpu_percent','Idle CPU (%)'),
                       ('space_layout_ms','Space synchronous layout (ms; proxy)')]:
        rows.append(f'<tr><td>{title}</td><td>{cell("airc",key)}</td><td>{cell(chrome,key)}</td><td>{num(latest.get("ratios",{}).get(key))}</td>'
                    + (f'<td>{was("airc",key)}</td><td>{was("airc",key,ratio=True)}</td>' if since() else '') + '</tr>')
    gap_data = read_gaps(runs_dir)
    overrides = {b['id']: b for b in gap_data.get('budgets', []) if b.get('status') != 'unknown'}
    latest = dict(latest, budgets=[dict(b, status=overrides[b['id']]['status'] + ' (separate gap probe; see below)') if b['id'] in overrides else b for b in latest.get('budgets', [])])
    def budget_table(data):
        old = (data.get('baseline') or {}).get('budgets', {})
        head = (f'<tr><th>Budget</th><th>Limit</th><th>Today</th><th>{since(data)}</th></tr>' if since(data) else '')
        fmt = lambda v: f' ({v:.2f})' if isinstance(v, (int, float)) and not isinstance(v, bool) else ''
        return '<table>' + head + ''.join(
            f'<tr><td>{esc(b["id"])}</td><td>{esc(b["budget"])}</td><td>{esc(b["status"])}</td>'
            + (f'<td>{esc(old.get(b["id"], {}).get("status", "–"))}{fmt(old.get(b["id"], {}).get("value"))} → {esc(str(b["status"]).split(" ")[0])}{fmt(b.get("value"))}</td>' if since(data) else '')
            + '</tr>' for b in data.get('budgets', [])) + '</table>'
    budget_rows = budget_table(latest)
    # Shared scale, chronological points, missing observations break lines.
    pair = lambda d: ['airc', 'chrome_8' if 'chrome_8' in d else 'chrome']
    lines = []; all_values = [d.get(n,{}).get('metrics',{}).get('total_mb') for _,d in history for n in pair(d)]
    ceiling = max([v for v in all_values if isinstance(v,(float,int)) and math.isfinite(v) and v>=0] or [1])
    for side,color in [(0,'#0a84ff'),(1,'#30a46c')]:
        previous = None
        for i,(_,data) in enumerate(history):
            name = pair(data)[side]
            v = data.get(name,{}).get('metrics',{}).get('total_mb')
            if not isinstance(v,(int,float)) or not math.isfinite(v) or v<0:
                previous = None; continue
            x,y = 30+i*540/max(1,len(history)-1), 110-90*v/max(1,ceiling)
            if previous: lines.append(f'<line x1="{previous[0]}" y1="{previous[1]}" x2="{x}" y2="{y}" stroke="{color}"/>')
            lines.append(f'<circle cx="{x}" cy="{y}" r="3" fill="{color}"><title>{esc(name)}: {v:.1f} MB</title></circle>')
            previous = (x,y)
    svg = f'<svg viewBox="0 0 600 140" role="img" aria-label="Physical footprint trend, oldest to newest; blue Airc, green Chrome" style="max-width:600px;width:100%"><text x="5" y="12" fill="currentColor" font-size="11">0–{ceiling:.0f} MB · blue Airc / green Chrome (same pages when measured) · oldest → newest</text>{"".join(lines)}<path d="M30 20V110H580" fill="none" stroke="currentColor"/></svg>'
    fair = ''
    if latest.get('mem4'):
        oldm = (latest.get('baseline') or {}).get('mem4', {})
        fair = ('<table><tr><th>MEM-4, same URLs in both</th><th>Airc MB</th><th>Chrome MB</th><th>Airc/Chrome</th>'
                '<th>Pages loaded (Airc, Chrome)</th><th>Idle CPU % (Airc, Chrome)</th>'
                + (f'<th>Airc/Chrome {since()}</th>' if since() else '') + '</tr>'
                + ''.join(f'<tr><td>{esc(n)} loaded</td><td>{num(r.get("airc_mb"))}</td><td>{num(r.get("chrome_mb"))}</td>'
                          f'<td>{num(r.get("ratio"))}</td><td>{esc(r.get("airc_pages_loaded"))}, {esc(r.get("chrome_pages_loaded"))} of {esc(n)}</td>'
                          f'<td>{num(r.get("airc_cpu_percent"))}, {num(r.get("chrome_cpu_percent"))}</td>'
                          + (f'<td>{num(oldm.get(n, {}).get("ratio")) if oldm.get(n) else "–"} → {num(r.get("ratio"))}</td>' if since() else '') + '</tr>'
                          for n, r in latest['mem4'].items()) + '</table>')
    extra = ''
    timing = [('interactive_ms','Launch to interactive'),('space_frame_ms','Space switch frame'),('tab_paint_ms','Loaded tab painted'),
              ('sidebar_ready_ms','Sidebar ready'),('new_space_ms','New Space'),('command_frame_first_ms','First Command Bar frame'),
              ('command_frame_ms','Command Bar frame'),('command_local_ms','Command Bar local results'),('command_suggestions_ms','Suggestions')]
    if latest.get('foreground'):
        f = {'foreground': latest['foreground']}
        f['baseline'] = latest.get('baseline')
        extra += ('<table><tr><th>Airc timings, ms</th><th>Dedicated foreground session</th><th>Background (hidden window)</th>'
                  + (f'<th>Foreground {since()}</th><th>Background {since()}</th>' if since() else '') + '</tr>'
                  + ''.join(f'<tr><td>{t}</td><td>{cell("foreground",k,f)}</td><td>{cell("airc",k)}</td>'
                            + (f'<td>{was("foreground",k,f)}</td><td>{was("airc",k)}</td>' if since() else '') + '</tr>' for k,t in timing) + '</table>')
    for label, side in (latest.get('ab') or {}).items():
        g = {'ab': side}
        extra += (f'<table><tr><th>Airc A/B: {esc(label)} ({esc(" ".join(side.get("app_args") or []) or "no extra arguments")}; '
                  f'n={esc(side.get("launches"))})</th><th>{esc(label)}</th><th>Reference</th></tr>'
                  + ''.join(f'<tr><td>{t}</td><td>{cell("ab",k,g)}</td><td>{cell("airc",k)}</td></tr>'
                            for k,t in [('total_mb','All-process footprint (MB)'),('main_mb','Main footprint (MB)'),
                                        ('idle_cpu_percent','Idle CPU (%)'),('interactive_ms','Launch to interactive (ms)'),
                                        ('leak_ratio','MEM-5 leak ratio')]) + '</table>')
    if webkit:
        wpath, w = webkit[-1]
        wc = 'chrome_8' if 'chrome_8' in w else 'chrome'
        extra += (f'<h3>WebKit engine</h3><p>{esc(w.get("timestamp",""))} · <a href="{href(wpath)}">JSON</a></p>'
                  '<table><tr><th>Metric</th><th>Airc (WebKit)</th><th>Chrome (same 8 pages)</th><th>Airc/Chrome</th>'
                  + (f'<th>Airc {since(w)}</th><th>Airc/Chrome {since(w)}</th>' if since(w) else '') + '</tr>'
                  + ''.join(f'<tr><td>{t}</td><td>{cell("airc",k,w)}</td><td>{cell(wc,k,w)}</td><td>{num(w.get("ratios",{}).get(k))}</td>'
                            + (f'<td>{was("airc",k,w)}</td><td>{was("airc",k,w,ratio=True)}</td>' if since(w) else '') + '</tr>'
                            for k,t in [('main_mb','Main physical footprint (MB)'),('total_mb','All-process physical footprint (MB)'),
                                        ('idle_cpu_percent','Idle CPU (%)')])
                  + ''.join(f'<tr><td>{t} (ms)</td><td>{cell("airc",k,w)}</td><td></td><td></td>'
                            + (f'<td>{was("airc",k,w)}</td><td></td>' if since(w) else '') + '</tr>' for k,t in timing[:6]) + '</table>'
                  + budget_table(w))
    m = latest.get('machine') or {}
    machine = ' · '.join(esc(x) for x in [m.get('cpu'), m.get('macos') and 'macOS ' + m['macos'],
                                           m.get('airc_revision') and 'Airc ' + m['airc_revision'][:10],
                                           m.get('chrome_version') and 'Chrome ' + m['chrome_version']] if x)
    return (f'<p>{esc(latest.get("timestamp",""))} · <b>{"Complete" if latest.get("complete") else "Incomplete / diagnostic only"}</b> · '
            f'<a href="{href(path)}">JSON</a>' + (f' · {machine}' if machine else '') + '</p>'
            + ''.join(f'<p class="dim">{esc(n)}</p>' for n in latest.get('notes',[]))
            + (f'<p class="dim">Before → after: {since()} = {esc((latest.get("baseline") or {}).get("timestamp", ""))} '
               f'({esc(((latest.get("baseline") or {}).get("machine") or {}).get("cpu", ""))}), its own medians, unchanged.</p>' if since() else '')
            + f'<table><tr><th>Metric</th><th>Airc</th><th>Chrome{" (same 8 pages)" if chrome == "chrome_8" else ""}</th><th>Airc/Chrome</th>'
            + (f'<th>Airc {since()}</th><th>Airc/Chrome {since()}</th>' if since() else '') + '</tr>'+''.join(rows)+'</table>'
            + fair + svg + budget_rows + extra + gaps)


def read_gaps(runs_dir):
    path = runs_dir.parent / 'perf-gaps/gaps.json'
    try:
        data = json.loads(path.read_text())
        if data.get('kind') != 'performance-gaps': return {}
        from .gap_results import budgets
        data['budgets'] = budgets(data)
        return data
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return {}


def render_gaps(runs_dir):
    data = read_gaps(runs_dir)
    if not data: return ''
    esc = lambda value: html.escape(str(value))
    rows = []
    for b in data['budgets']:
        metrics = []
        for key, value in b['measurements'].items():
            if isinstance(value, dict) and 'median' in value:
                metrics.append(f"{key}: {value['median']:.3f} ({value['min']:.3f}–{value['max']:.3f}; n={value['n']})")
            elif value: metrics.append(f'{key}: {value}')
        rows.append(f"<tr><td>{esc(b['id'])}</td><td>{esc(b['status'])}</td><td>{esc('; '.join(metrics) or 'unmeasured')}</td><td>{esc(b['reason'])}</td></tr>")
    return (f"<h3>Separate gap probes</h3><p>{esc(data.get('timestamp'))} · <a href='perf-gaps/gaps.json'>JSON</a> · "
            f"binary <code>{esc(data.get('binary_sha256', '')[:12])}</code>"
            + (' · dedicated foreground session' if data.get('dedicated_session') else ' · background windows')
            + (f" · Airc {esc(' '.join(data['app_args']))}" if data.get('app_args') else '')
            + ". Medians (min–max); sources and scopes below. "
            "These results do not replace the reference workload above.</p>"
            + '<table><tr><th>Budget</th><th>Status</th><th>Measurement</th><th>Method / limits</th></tr>' + ''.join(rows) + '</table>')
