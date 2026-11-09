#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The work page beside the status page: what's live, what's building, the agents, the queue, what waits on the owner.

    infra/work_page.py [--state FILE] [--status DIR]

Reads the lead's state file (default ../briefs/work.json next to the repo; never committed), the ship loop's runs and
log in the status folder (default ../status), cached installed/local-feed build numbers from the Mac, and git,
then writes DIR/work.html. Run from cron every few minutes; SSH attempts are cached for ten minutes.
"""
import argparse, html, json, os, pathlib, re, subprocess
from datetime import datetime, timezone
from owner_versions import owner_versions
from xctest_summary import FAILED
from run_result import state as run_state, LABELS

ROOT = pathlib.Path(__file__).resolve().parents[1]
e = lambda s: html.escape(str(s))


def build_label(v):
    try:
        return datetime.strptime(v, '%Y%m%d%H%M').strftime('%-d %b %H:%M')
    except ValueError:
        return v


def published_revs():
    # Every publish (the loop's or one by hand) leaves its evidence with the bundle's Info.plist.
    revs = {}
    for plist in (ROOT.parent / 'artifacts' / 'release' / 'dev-channel').glob('publish.*/Info.plist'):
        try:
            import plistlib
            d = plistlib.loads(plist.read_bytes())
            revs[d.get('AircRevision', '')] = d.get('CFBundleVersion', '')
        except Exception:
            pass
    return revs


def runs(status, n=8):
    out = []
    published = published_revs()
    newest = True
    for d in sorted((status / 'runs').glob('*/'), reverse=True)[:n]:
        steps = {}
        for line in (d / 'steps.tsv').read_text().splitlines() if (d / 'steps.tsv').exists() else []:
            name, rc, secs = (line.split('\t') + ['', ''])[:3]
            steps[name] = rc
        rev = (d / 'rev.txt').read_text().strip() if (d / 'rev.txt').exists() else ''
        subject = (d / 'subject.txt').read_text().strip() if (d / 'subject.txt').exists() else ''
        pub = steps.get('publish-dev')
        gate_state = run_state(d)
        if gate_state in ('WAIT', 'ENV'):
            result, cls = LABELS[gate_state], 'skip'
        elif rev in published:
            result, cls = f'published · {build_label(published[rev])}', 'ok'
        elif steps.get('mac-online', '0') != '0':
            result, cls = 'Mac offline', 'skip'
        elif pub == '0':
            result, cls = 'published', 'ok'
        elif pub == '3':
            result, cls = 'checks failed', 'bad'
        elif pub is not None:
            result, cls = 'publish failed', 'bad'
        elif steps.get('build-app') not in (None, '0'):
            result, cls = 'checks failed', 'bad'
        elif newest and building_now():
            result, cls = 'running…', 'skip'
        else:
            result, cls = 'stopped', 'skip'
        newest = False
        out.append((d.name, rev, subject, result, cls, list(steps)[-1:] or ['starting']))
    return out


def short(text, n):
    return text if len(text) <= n else text[:n].rsplit(' ', 1)[0].rstrip(',.;:·') + '…'


def building_now():
    r = subprocess.run(['pgrep', '-f', 'infra/nightly.sh'], capture_output=True, text=True)
    return bool(r.stdout.strip())


def commits(n=12):
    r = subprocess.run(['git', '-C', str(ROOT), 'log', f'-{n}', '--format=%h\t%cd\t%s', '--date=format:%H:%M'],
                       capture_output=True, text=True)
    return [l.split('\t', 2) for l in r.stdout.splitlines() if l.count('\t') >= 2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--state', default=str(ROOT.parent / 'briefs' / 'work.json'))
    ap.add_argument('--status', default=str(ROOT.parent / 'status'))
    a = ap.parse_args()
    status = pathlib.Path(a.status)
    state = json.loads(pathlib.Path(a.state).read_text()) if pathlib.Path(a.state).exists() else {}
    live = json.loads((status / 'live.json').read_text()) if (status / 'live.json').exists() else {}
    owner = owner_versions(status)
    rs = runs(status)
    now = datetime.now(timezone.utc).strftime('%H:%M UTC')

    steps_order = ['mac-online', 'export', 'test-AircDesign', 'test-AircImport', 'test-AircKit', 'build-app',
                   'publish-dev', 'snapshots-webkit', 'try-copy']
    step_names = {'mac-online': 'checking the Mac', 'export': 'copying the code', 'test-AircDesign': 'package tests',
                  'test-AircImport': 'package tests', 'test-AircKit': 'package tests', 'build-app': 'building and testing the app',
                  'publish-dev': 'publishing to your Airc', 'snapshots-webkit': 'extra WebKit checks', 'try-copy': 'finishing'}

    def elapsed(since):
        try:
            hh, mm = map(int, since.split(':'))
            n = datetime.now(timezone.utc)
            mins = (n.hour * 60 + n.minute) - (hh * 60 + mm)
            return f'{mins // 60} h {mins % 60:02d} min' if mins >= 60 else f'{max(mins, 0)} min'
        except ValueError:
            return ''

    css = """
:root{color-scheme:light dark;--bg:#F7F6F4;--card:#FFFFFF;--sunk:#EFEDEA;--line:#E3E0DC;--ink:#14110F;--dim:#7F7873;
--faint:#A9A39E;--blue:#3139FB;--blue-soft:#3139FB14;--green:#2F9E62;--red:#E5484D;--shadow:0 1px 2px #14110F0D,0 8px 24px #14110F0A}
@media(prefers-color-scheme:dark){:root{--bg:#110F0E;--card:#1D1A18;--sunk:#2F2A28;--line:#2F2A28;--ink:#FAFBFF;--dim:#A9A39E;
--faint:#7F7873;--blue:#7078FF;--blue-soft:#7078FF1F;--shadow:0 1px 2px #0006}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,
"SF Pro Text","Helvetica Neue",Inter,Arial,sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:1120px;margin:0 auto;padding:28px 22px 48px}
.rounded{font-family:ui-rounded,"SF Pro Rounded",-apple-system,"Helvetica Neue",Arial,sans-serif}
header{display:flex;align-items:center;gap:14px;margin-bottom:22px}
.mark{width:44px;height:44px;border-radius:12px;flex:none;display:grid;place-items:center;color:#fff;font:700 24px ui-rounded,system-ui;
background:conic-gradient(from 210deg,#8ee6d0,#9fb4ff,#e7b6f5,#ffc6b0,#8ee6d0);box-shadow:inset 0 0 0 2px #ffffff80,var(--shadow);text-shadow:0 1px 2px #0003}
h1{font-size:26px;letter-spacing:-.02em;margin:0;line-height:1.1}.sub{color:var(--dim);font-size:13px;margin-top:2px}
.links{margin-left:auto;display:flex;gap:8px;flex-wrap:wrap}.links a,.chip{font-size:13px;color:var(--ink);text-decoration:none;
background:var(--card);border:1px solid var(--line);padding:5px 11px;border-radius:99px}.links a:hover{border-color:var(--blue)}
.tiles{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:8px}
.tile,.card{background:var(--card);border-radius:16px;box-shadow:var(--shadow);padding:16px 18px}
.label{font-size:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
.big{font-size:24px;font-weight:700;letter-spacing:-.02em;margin:4px 0 2px}.big.step{font-size:19px;line-height:1.3}.small{font-size:13px;color:var(--dim)}
.bar{height:6px;border-radius:99px;background:var(--sunk);overflow:hidden;margin-top:10px}.bar i{display:block;height:100%;
background:var(--blue);border-radius:99px;transition:width .4s}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;vertical-align:1px;background:var(--faint)}
.dot.green{background:var(--green)}.dot.red{background:var(--red)}.dot.blue{background:var(--blue)}
.pulse{animation:p 1.6s ease-in-out infinite}@keyframes p{50%{opacity:.35}}
.cols{display:grid;grid-template-columns:1.6fr 1fr;gap:18px;margin-top:18px;align-items:start}
h2{font-size:15px;margin:22px 0 10px;letter-spacing:-.01em}h2 .n{color:var(--dim);font-weight:500;margin-left:6px}
.agents{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px}
.agent h3{font-size:17px;margin:0 0 2px;letter-spacing:-.01em}.agent p{margin:8px 0;font-size:14px}
.meta{display:flex;gap:6px;flex-wrap:wrap;align-items:center;font-size:12px;color:var(--dim)}
.tag{background:var(--sunk);border-radius:99px;padding:1px 8px;color:var(--ink);font-size:12px}
.tag.blue{background:var(--blue-soft);color:var(--blue);font-weight:600}
.todo{list-style:none;margin:0;padding:0;counter-reset:t}.todo li{counter-increment:t;display:flex;gap:10px;padding:9px 0;
border-top:1px solid var(--line);font-size:14px}.todo li:first-child{border-top:0;padding-top:2px}
.todo li::before{content:counter(t);flex:none;width:22px;height:22px;border-radius:50%;background:var(--blue-soft);color:var(--blue);
font:700 12px/22px ui-rounded,system-ui;text-align:center}
.list{list-style:none;margin:0;padding:0}.list li{padding:8px 0;border-top:1px solid var(--line);font-size:14px}.list li:first-child{border-top:0;padding-top:0}
.tl{position:relative;margin:0;padding:0;list-style:none}.tl li{display:grid;grid-template-columns:52px 1fr;gap:10px;padding:7px 0;font-size:14px}
.tl .t{color:var(--dim);font-variant-numeric:tabular-nums;font-size:13px}.tl b{font-weight:600}
.build{display:grid;grid-template-columns:auto 1fr;gap:4px 10px;padding:9px 0;border-top:1px solid var(--line);font-size:13px}
.build:first-child{border-top:0;padding-top:0}.build .what{color:var(--dim);grid-column:2;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--sunk);padding:1px 6px;border-radius:6px}
details summary{cursor:pointer;color:var(--dim);font-size:14px;list-style:none}details summary::before{content:"▸ "}details[open] summary::before{content:"▾ "}
.commit{display:grid;grid-template-columns:44px 64px 1fr;gap:8px;padding:6px 0;border-top:1px solid var(--line);font-size:13px}
footer{color:var(--faint);font-size:12px;margin-top:28px;text-align:center}
.narrow{display:none}
@media(max-width:820px){.tiles{grid-template-columns:1fr}.cols{grid-template-columns:1fr}.links{margin-left:0}header{flex-wrap:wrap}
.narrow{display:block}.wide{display:none}}
"""
    h = ['<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
         f'<meta http-equiv="refresh" content="60"><title>Airc work</title><style>{css}</style></head><body><div class="wrap">']
    h.append('<header><div class="mark">A</div><div><h1 class="rounded">Airc work</h1>'
             f'<div class="sub">Built and maintained by AI · updated {e(now)}</div></div><nav class="links">'
             + ''.join(f'<a href="{e(u)}">{e(t)}</a>' for t, u in state.get('links', [])) + '</nav></header>')

    live_build = build_label(owner['latest']) if owner.get('latest') else 'unknown'
    running = building_now()
    cur = rs[0] if rs else None
    if running and cur:
        last = cur[5][0]
        idx = steps_order.index(last) + 1 if last in steps_order else 0
        pct = int(100 * idx / len(steps_order))
        build_tile = (f'<div class="label">Building</div><div class="big step rounded"><span class="dot blue pulse"></span>'
                      f'{e(step_names.get(steps_order[min(idx, len(steps_order) - 1)], "working"))}</div>'
                      f'<div class="small"><code>{e(cur[1])}</code> · {e(short(cur[2], 52))}</div><div class="bar"><i style="width:{pct}%"></i></div>')
    elif cur and cur[3] in (LABELS['WAIT'], LABELS['ENV']):
        build_tile = (f'<div class="label">Building</div><div class="big step rounded"><span class="dot"></span>{e(cur[3])}</div>'
                      '<div class="small">Nothing published. Retrying in a few minutes; UI checks need an unlocked screen.</div>')
    else:
        build_tile = ('<div class="label">Building</div><div class="big rounded"><span class="dot"></span>Idle</div>'
                      '<div class="small">A build starts about two minutes after new commits land.</div>')
    online = live.get('online')
    h.append('<section class="tiles">'
             f'<div class="tile"><div class="label">Your Mac’s feed</div><div class="big rounded">{e(live_build)}</div>'
             '<div class="small">Latest checked local feed. Airc menu → Check for Updates…</div></div>'
             f'<div class="tile">{build_tile}</div>'
             f'<div class="tile"><div class="label">Build Mac</div><div class="big rounded"><span class="dot {"green" if online else "red"}"></span>'
             f'{"Online" if online else "Offline"}</div><div class="small">{e(live.get("disk_free", "?"))} free · checked {e(str(live.get("checked", "?"))[-9:])}</div></div>'
             '</section>')

    checked = datetime.fromtimestamp(owner['checked'], timezone.utc).strftime('%d %b %H:%M UTC') if owner.get('checked') else 'unavailable'
    h.append(f'<p>Your Airc: build {e(owner.get("installed", "unknown"))} (installed) · '
             f'latest on your Mac\'s feed: {e(owner.get("latest", "unknown"))}'
             f' <span class="small">(checked {e(checked)})</span></p>')

    main, side = [], []
    ag = state.get('running', [])
    main.append(f'<h2>Agents at work<span class="n">{len(ag)}</span></h2><div class="agents">')
    for a in ag:
        main.append(f'<div class="card agent"><h3 class="rounded">{e(a["name"])}</h3><div class="meta">'
                    f'<span class="tag blue">{e(a.get("status", ""))}</span><span class="tag">{e(a.get("model", ""))}</span>'
                    f'<span>· {e(elapsed(a.get("since", "")))}</span></div><p>{e(a["what"])}</p></div>')
    main.append('</div>')
    done = state.get('done_today', [])
    if done:
        main.append(f'<h2>Finished today<span class="n">{len(done)}</span></h2><div class="card"><ul class="tl">'
                    + ''.join(f'<li><span class="t">{e(d.get("at", ""))}</span><span><b>{e(d["name"])}</b> · {e(d["what"])}</span></li>'
                              for d in done) + '</ul></div>')
    commits_html = ('<h2>Latest commits</h2><div class="card"><details><summary>Show the last 12</summary>'
                + ''.join(f'<div class="commit"><span class="small">{e(t)}</span><code>{e(sha)}</code><span>{e(sub)}</span></div>'
                          for sha, t, sub in commits()) + '</details></div>')

    todo = ''
    if state.get('owner'):
        todo = ('<h2>Waiting on you</h2><div class="card"><ol class="todo">'
                + ''.join(f'<li><span>{e(x)}</span></li>' for x in state['owner']) + '</ol></div>')
        # On a phone the to-dos come right after the tiles; on wider screens they lead the side column.
        side.append(f'<div class="wide">{todo}</div>')
    side.append('<h2>Recent builds</h2><div class="card">')
    for name, rev, subject, result, cls, _ in rs:
        color = {'ok': 'green', 'bad': 'red'}.get(cls, '')
        pulse = ' pulse blue' if result.startswith('running') else ''
        side.append(f'<div class="build"><span class="dot {color}{pulse}"></span><span><b>{e(result)}</b> · '
                    f'<span class="small">{e(name[-4:-2])}:{e(name[-2:])}</span> <code>{e(rev)}</code></span>'
                    f'<span class="what">{e(subject)}</span></div>')
        failures = []
        for log in sorted((status / 'runs' / name).glob('*.log')):
            if log.name != 'build-app.log' and not log.name.startswith('test-'):
                continue
            with log.open(errors='replace') as stream:
                failures.extend(line.strip() for line in stream if FAILED.search(line))
        if failures:
            side.append('<details><summary>Failing unit tests</summary><ul class="list">'
                        + ''.join(f'<li>{e(line)}</li>' for line in dict.fromkeys(failures)) + '</ul></details>')
    side.append('</div>')
    if state.get('queued'):
        side.append('<h2>Next in the queue</h2><div class="card"><ul class="list">'
                    + ''.join(f'<li>{e(x)}</li>' for x in state['queued']) + '</ul></div>')
    for group, items in (state.get('backlog') or {}).items():
        main.append(f'<h2>{e(group)}<span class="n">{len(items)}</span></h2><div class="card"><ul class="list">'
                    + ''.join(f'<li>{e(x)}</li>' for x in items) + '</ul></div>')
    if todo:
        h.append(f'<div class="narrow">{todo}</div>')
    main.append(commits_html)
    h.append(f'<div class="cols"><div>{"".join(main)}</div><div>{"".join(side)}</div></div>')
    h.append(f'<footer>State as of {e(state.get("updated", "?"))} · refreshes every minute</footer></div></body></html>')
    out = status / 'work.html'
    tmp = out.with_suffix('.tmp')
    tmp.write_text('\n'.join(h))
    os.replace(tmp, out)


if __name__ == '__main__':
    main()
