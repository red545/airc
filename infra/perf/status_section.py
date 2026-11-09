# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Read optional benchmark artifacts without affecting the existing status page."""
import html
import json
import math

def render(runs_dir):
    history = []
    for path in sorted(runs_dir.glob('*/results.json'))[-30:]:
        try:
            data = json.loads(path.read_text())
            if data.get('schema_version') == 1: history.append((path, data))
        except (OSError, ValueError, AttributeError):
            continue
    gaps = render_gaps(runs_dir)
    if not history: return '<p>No reference performance runs yet.</p>' + gaps
    path, latest = history[-1]
    esc = lambda x: html.escape(str(x))
    def num(value):
        return f'{value:.2f}' if isinstance(value,(int,float)) and math.isfinite(value) else 'unavailable'
    # Like for like: Chrome with the same 8 pages as Airc's reference run, when the run has it (older runs: 30 tabs).
    chrome = 'chrome_8' if 'chrome_8' in latest else 'chrome'
    rows = []
    for key, title in [('first_window_ms','First window observed (ms; proxy)'),('early_main_mb','Early main footprint (MB; diagnostic)'),('main_mb','Main physical footprint at 60 s (MB)'),
                       ('total_mb','All-process physical footprint (MB)'),('idle_cpu_percent','Idle CPU (%)'),
                       ('space_layout_ms','Space synchronous layout (ms; proxy)')]:
        values = [latest.get(n,{}).get('metrics',{}).get(key) for n in ['airc',chrome]]
        rows.append(f'<tr><td>{title}</td><td>{num(values[0])}</td><td>{num(values[1])}</td><td>{num(latest.get("ratios",{}).get(key))}</td></tr>')
    gap_data = read_gaps(runs_dir)
    overrides = {b['id']: b for b in gap_data.get('budgets', []) if b.get('status') != 'unknown'}
    latest = dict(latest, budgets=[dict(b, status=overrides[b['id']]['status'] + ' (separate gap probe; see below)') if b['id'] in overrides else b for b in latest.get('budgets', [])])
    budget_rows = ''.join(f'<tr><td>{esc(b["id"])}</td><td>{esc(b["budget"])}</td><td>{esc(b["status"])}</td></tr>' for b in latest.get('budgets',[]))
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
        fair = ('<table><tr><th>MEM-4, same URLs in both</th><th>Airc MB</th><th>Chrome MB</th><th>Airc/Chrome</th>'
                '<th>Pages loaded (Airc, Chrome)</th><th>Idle CPU % (Airc, Chrome)</th></tr>'
                + ''.join(f'<tr><td>{esc(n)} loaded</td><td>{num(r.get("airc_mb"))}</td><td>{num(r.get("chrome_mb"))}</td>'
                          f'<td>{num(r.get("ratio"))}</td><td>{esc(r.get("airc_pages_loaded"))}, {esc(r.get("chrome_pages_loaded"))} of {esc(n)}</td>'
                          f'<td>{num(r.get("airc_cpu_percent"))}, {num(r.get("chrome_cpu_percent"))}</td></tr>'
                          for n, r in latest['mem4'].items()) + '</table>')
    return (f'<p>{esc(latest.get("timestamp",""))} · <b>{"Complete" if latest.get("complete") else "Incomplete / diagnostic only"}</b> · '
            f'<a href="runs/{esc(path.parent.name)}/results.json">JSON</a></p>'
            + ''.join(f'<p class="dim">{esc(n)}</p>' for n in latest.get('notes',[]))
            + f'<table><tr><th>Metric</th><th>Airc</th><th>Chrome{" (same 8 pages)" if chrome == "chrome_8" else ""}</th><th>Airc/Chrome</th></tr>'+''.join(rows)+'</table>'
            + fair + svg+'<table>'+budget_rows+'</table>' + gaps)


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
            f"binary <code>{esc(data.get('binary_sha256', '')[:12])}</code>. Medians (min–max); sources and scopes below. "
            "These results do not replace the reference workload above.</p>"
            + '<table><tr><th>Budget</th><th>Status</th><th>Measurement</th><th>Method / limits</th></tr>' + ''.join(rows) + '</table>')
