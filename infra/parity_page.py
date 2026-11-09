#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The parity page: every Arc feature row and where it stands, in one table.

    infra/parity_page.py [--audit FILE] [--overlay FILE] [--out FILE]

Reads docs/qa/parity-audit.md's feature inventory (ID · feature, status, what's missing, size) and the lead's overlay
(default ../briefs/parity-overlay.json, never committed): per-row `agent` (who's on it now), `next`, and `status`
when the audit hasn't caught up yet. Writes status/parity.html, which the tailnet status site serves. Run from cron.
"""
import argparse, collections, html, json, pathlib, re, subprocess
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
e = lambda s: html.escape(str(s))
ORDER = ['missing', 'partial', 'owner-gated', 'done', 'out of scope']
LABEL = {'missing': 'Missing', 'partial': 'Partial', 'owner-gated': 'Owner', 'done': 'Done', 'out of scope': 'Out of scope'}
AREAS = {'A': 'AI', 'B': 'Boosts', 'C': 'Command Bar', 'E': 'Engine & settings', 'H': 'Sharing', 'K': 'Keyboard',
         'L': 'Library', 'M': 'Media & calls', 'N': 'Notes, Capture, Easels', 'P': 'Pages & themes', 'Q': 'Quality',
         'S': 'Sidebar', 'V': 'Little Arc', 'W': 'Window', 'Y': 'Sync'}


def rows(audit):
    out = []
    for line in audit.read_text().splitlines():
        m = re.match(r'^\| ([A-Z])(\d+) · ([^|]+)\|', line)
        if not m:
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) < 6:
            continue
        status = cells[2] if cells[2] in LABEL else next((c for c in cells if c in LABEL), '?')
        out.append({'id': f'{m[1]}{m[2]}', 'area': AREAS.get(m[1], m[1]), 'feature': m[3].strip(), 'arc': cells[1],
                    'status': status, 'missing': cells[4], 'size': cells[5]})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--audit', default=str(ROOT / 'docs/qa/parity-audit.md'))
    ap.add_argument('--overlay', default=str(ROOT.parent / 'briefs/parity-overlay.json'))
    ap.add_argument('--out', default=str(ROOT.parent / 'status/parity.html'))
    a = ap.parse_args()
    data = rows(pathlib.Path(a.audit))
    try:
        overlay = json.loads(pathlib.Path(a.overlay).read_text())
    except (OSError, ValueError):
        overlay = {}
    notes, agents = overlay.get('rows', {}), overlay.get('agents', [])
    for r in data:
        o = notes.get(r['id'], {})
        r['audit_status'] = r['status']
        r['status'] = o.get('status', r['status'])
        r['agent'], r['next'] = o.get('agent', ''), o.get('next', '')
    c = collections.Counter(r['status'] for r in data)
    scope = sum(v for k, v in c.items() if k != 'out of scope')
    pct = round(100 * c['done'] / scope) if scope else 0
    try:
        rev = subprocess.run(['git', '-C', str(ROOT), 'log', '-1', '--format=%h %cr', '--', 'docs/qa/parity-audit.md'],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        rev = ''
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    data.sort(key=lambda r: (ORDER.index(r['status']) if r['status'] in ORDER else 9, not r['agent'], r['id']))

    bar = ''.join(f'<span class="seg s-{k.replace(" ", "-")}" style="flex:{c[k]}" title="{LABEL[k]} {c[k]}"></span>'
                  for k in ORDER if c[k])
    chips = ''.join(f'<button class="chip s-{k.replace(" ", "-")}" data-f="{e(k)}">{LABEL[k]} <b>{c[k]}</b></button>'
                    for k in ORDER)
    trs = []
    for r in data:
        changed = r['status'] != r['audit_status']
        trs.append(
            f'<tr data-s="{e(r["status"])}"><td class="id">{e(r["id"])}</td><td>{e(r["area"])}</td>'
            f'<td class="f">{e(r["feature"])}</td>'
            f'<td><span class="pill s-{e(r["status"].replace(" ", "-"))}">{e(LABEL.get(r["status"], r["status"]))}</span>'
            f'{"<span class=lag title=\"audit says " + e(r["audit_status"]) + "\">*</span>" if changed else ""}</td>'
            f'<td class="who">{e(r["agent"])}</td><td class="m">{e(r["next"] or r["missing"])}</td>'
            f'<td class="sz">{e(r["size"])}</td></tr>')
    ag = ''.join(f'<li><b>{e(x.get("name", ""))}</b> {e(x.get("what", ""))} <i>{e(x.get("state", ""))}</i></li>'
                 for x in agents)
    page = f'''<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=120><title>Airc parity {pct}%</title>
<style>
:root{{color-scheme:light dark;--bg:#fbfbfd;--fg:#1d1d1f;--mut:#6e6e73;--line:#e5e5ea;--card:#fff}}
@media(prefers-color-scheme:dark){{:root{{--bg:#111113;--fg:#f2f2f7;--mut:#98989f;--line:#2c2c30;--card:#1c1c1f}}}}
body{{margin:0;font:14px/1.4 -apple-system,BlinkMacSystemFont,Inter,system-ui,sans-serif;background:var(--bg);color:var(--fg)}}
main{{max-width:1280px;margin:auto;padding:20px}}h1{{font-size:22px;margin:0 0 4px}}.sub{{color:var(--mut);font-size:12px}}
.bar{{display:flex;height:12px;border-radius:6px;overflow:hidden;margin:14px 0 10px;background:var(--line)}}
.s-done{{--c:#30a46c}}.s-partial{{--c:#f5a524}}.s-missing{{--c:#e5484d}}.s-owner-gated{{--c:#6e56cf}}.s-out-of-scope{{--c:#8e8e93}}
.seg{{background:var(--c)}}.chips{{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:12px}}
.chip{{border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:14px;padding:4px 10px;cursor:pointer;font:inherit}}
.chip::before{{content:"";display:inline-block;width:8px;height:8px;border-radius:4px;background:var(--c);margin-right:6px}}
.chip.on{{outline:2px solid var(--c)}}input{{font:inherit;padding:5px 10px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);min-width:220px}}
table{{width:100%;border-collapse:collapse;background:var(--card);border-radius:10px;overflow:hidden}}
th,td{{text-align:left;padding:7px 9px;border-bottom:1px solid var(--line);vertical-align:top}}th{{font-size:12px;color:var(--mut);font-weight:600;position:sticky;top:0;background:var(--card)}}
.id{{font-variant-numeric:tabular-nums;color:var(--mut);white-space:nowrap}}.f{{font-weight:600;min-width:180px}}.m{{color:var(--mut);font-size:13px}}
.pill{{display:inline-block;border-radius:10px;padding:1px 8px;font-size:12px;font-weight:600;color:#fff;background:var(--c);white-space:nowrap}}
.who{{font-size:12px;white-space:nowrap}}.lag{{color:var(--mut);margin-left:3px}}.sz{{color:var(--mut)}}
ul.ag{{margin:6px 0 14px;padding-left:18px;font-size:13px}}ul.ag i{{color:var(--mut)}}a{{color:inherit}}
</style><main>
<h1>Arc parity: {pct}% done <span class=sub>({c["done"]} of {scope} in scope)</span></h1>
<div class=sub>Updated {now}. Audit last changed {e(rev)}. * = status ahead of the audit (lead overlay). <a href="work.html">Work page</a> · <a href="index.html">Status</a></div>
<div class=bar>{bar}</div><div class=chips>{chips}<input id=q placeholder="Filter…"></div>
{f'<div class=sub>Running now</div><ul class=ag>{ag}</ul>' if ag else ''}
<table><thead><tr><th>ID</th><th>Area</th><th>Feature</th><th>Status</th><th>Who</th><th>What's left / next</th><th>Size</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table></main>
<script>
const on=new Set();const q=document.getElementById('q');
function f(){{const t=q.value.toLowerCase();document.querySelectorAll('tbody tr').forEach(r=>{{
r.hidden=(on.size&&!on.has(r.dataset.s))||(t&&!r.textContent.toLowerCase().includes(t));}});}}
document.querySelectorAll('.chip').forEach(b=>b.onclick=()=>{{on.has(b.dataset.f)?on.delete(b.dataset.f):on.add(b.dataset.f);b.classList.toggle('on');f();}});
q.oninput=f;
</script>'''
    out = pathlib.Path(a.out)
    tmp = out.with_suffix('.tmp')
    tmp.write_text(page)
    tmp.replace(out)


if __name__ == '__main__':
    main()
