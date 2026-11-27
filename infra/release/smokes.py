#!/usr/bin/env python3
"""Release smokes by change: pick, order, estimate and run the test-build smokes a release needs.

  smokes.py plan    [--from REV] [--to REV] [--extra FILE] [--allow ID=REGEX[:MAX]]… [--json OUT]   dry run
  smokes.py run     --plan PLAN.json --tier gate|tail --work NAME --out DIR [--allow ID=REGEX[:MAX]]…
  smokes.py tail-status [--status DIR]                                     the last release tail, for the lead
  smokes.py blockers    [--status DIR]                                     exit 1 if the next release must wait

The catalog (smoke-catalog.json) lists every smoke releases ran since 0.1.61 with the paths it covers. The gate
runs the core set plus every smoke whose paths, Debug check file or SnapshotRunner case changed since the last
release (--from, default: the last `Source:` line in docs/release-notes-beta.md), within a 15-min budget. HEADLINE
checks (the check is new or changed since the last release AND its own product paths changed) always run at the gate:
the budget is raised by their cost and the plan says so. A lead-ruled --allow line (an exact FAIL line, at most MAX
per run) excuses that FAIL and lowers the run's PASS want by the lines it excused; the plan/state json records it.
Everything else, timing smokes and
the slow signed-build measurements run in the release's TAIL, after LIVE, on the same test build. A red tail blocks
the next release (blockers); it never holds the release that made it. Crash/hang-class reds always stop.
See infra/release/fast-gate.md, "Changed-path smokes", and docs/release.md, "Release gates".
"""
import argparse
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CATALOG = HERE / 'smoke-catalog.json'
STATUS = Path(os.environ.get('AIRC_STATUS_DIR', Path.home() / 'arcfork/status'))
HID_MODES = {'real', 'tfg', 'pfg', 'fp'}            # the UI driver posts HID input: resets the Mac's idle clock
PREFIX = {'S/': 'apps/browser/Sources/Airc/', 'K/': 'packages/AircKit/Sources/AircKit/'}
CRITICAL = re.compile(r'\b(?:crash(?:ed|es)?|died|hung|hang|still alive|watchdog|no PID|never started|wrote no log)\b', re.I)
HOLDS = ('quiet-pending', 'relink-pending')
SSH = ['ssh', '-n', '-o', 'ConnectTimeout=20', '-o', 'ServerAliveInterval=10', 'buildmac']


def expand(pattern):
    for short, full in PREFIX.items():
        if pattern.startswith(short):
            return full + pattern[len(short):]
    return pattern


def matches(path, patterns):
    return [p for p in patterns if fnmatch.fnmatch(path, expand(p).split('#')[0])]


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True)


def last_release_source(rev):
    text = git('show', f'{rev}:docs/release-notes-beta.md')
    found = re.findall(r'^Source: `([0-9a-f]{40})`', text, re.M)
    if not found:
        raise SystemExit('no "Source:" line in docs/release-notes-beta.md; pass --from')
    return found[-1]


def debug_map(rev):
    """Debug file → scripts, from SnapshotRunner's case lines (`case "a", "b": fn()   // … (File.swift)`)."""
    runner = git('show', f'{rev}:apps/browser/Sources/Airc/Debug/SnapshotRunner.swift')
    files = git('ls-tree', '--name-only', rev, 'apps/browser/Sources/Airc/Debug/').split()
    defined = {}
    for f in files:
        if not f.endswith('.swift') or f.endswith('SnapshotRunner.swift'):
            continue
        for fn in re.findall(r'func (\w+Scenario|\w+Check)\s*\(', git('show', f'{rev}:{f}')):
            defined.setdefault(fn, f)
    out = {}
    for line in runner.splitlines():
        m = re.match(r'\s*case ((?:"[\w.-]+",?\s*)+):(.*)$', line)
        if not m:
            continue
        scripts = re.findall(r'"([\w.-]+)"', m[1])
        named = set(re.findall(r'\((\w+\.swift)\)', m[2])) | set(re.findall(r'\b(\w+Check\.swift)\b', m[2]))
        for fn in re.findall(r'(\w+)\(', m[2]):
            if fn in defined:
                named.add(Path(defined[fn]).name)
        for name in named:
            out.setdefault('apps/browser/Sources/Airc/Debug/' + name, set()).update(scripts)
    return out


def runner_cases_changed(base, rev):
    """Scripts whose SnapshotRunner case line changed (added/edited) between base and rev."""
    diff = git('diff', '-U0', base, rev, '--', 'apps/browser/Sources/Airc/Debug/SnapshotRunner.swift')
    scripts, other = set(), 0
    for line in diff.splitlines():
        if line.startswith(('+++', '---')) or not line[:1] in '+-':
            continue
        m = re.match(r'[+-]\s*case ((?:"[\w.-]+",?\s*)+):', line)
        if m:
            scripts.update(re.findall(r'"([\w.-]+)"', m[1]))
        elif line[1:].strip() and not line[1:].strip().startswith('//'):
            other += 1
    return scripts, other


def load_extra(path):
    """release074's extra-oe-smokes.txt format: engine script mode want limit tag OPEN_ENV(-) [paths=GLOB,GLOB].
    paths= names the product paths the new check covers (S/, K/ prefixes): with them changed it is a headline check."""
    cases = []
    if not path:
        return cases
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        e, sc, m, want, lim, *rest = line.split()
        paths = [p for t in rest if t.startswith('paths=') for p in t[6:].split(',') if p]
        rest = [t for t in rest if not t.startswith('paths=')]
        tag = rest[0] if rest and rest[0] != '-' else ''
        oe = rest[1] if len(rest) > 1 and rest[1] != '-' else ''
        kind = 'agents' if m == 'posted' or (m == 'real' and oe) else 'nf'
        cases.append(dict(id=f'{sc}-{m}{tag}', kind=kind, script=sc, mode=m, tag=tag, engines={e: int(want)},
                          limit=int(lim), env=[oe] if oe and kind == 'agents' else [], nf_env=[oe] if oe and kind == 'nf' else [],
                          seconds={e: 60}, paths=paths, extra=True, reason=['extra (freeze list)']))
    merged = {}
    for c in cases:
        if c['id'] in merged:
            merged[c['id']]['engines'].update(c['engines']); merged[c['id']]['seconds'].update(c['seconds'])
            merged[c['id']]['paths'] = sorted(set(merged[c['id']]['paths']) | set(c['paths']))
        else:
            merged[c['id']] = c
    return list(merged.values())


DEBUG = 'apps/browser/Sources/Airc/Debug/'


def debug_scripts(path, debug):
    """Scripts a Debug file belongs to: named on a case line, or an extension file of a named one
    (AgentMainBlank.swift → AgentMainCheck.swift's scripts)."""
    if path in debug:
        return debug[path]
    stem = Path(path).stem
    best = None
    for f, scripts in debug.items():
        root = Path(f).stem.removesuffix('Check')
        if len(root) >= 6 and stem.startswith(root) and (best is None or len(root) > len(best[0])):
            best = (root, scripts)
    return best[1] if best else set()


def catalog_cases_at(rev):
    """The catalog's cases at rev by id, or None when it had no catalog (then no case counts as changed by it)."""
    try:
        return {c['id']: c for c in json.loads(git('show', f'{rev}:infra/release/smoke-catalog.json'))['cases']}
    except (subprocess.CalledProcessError, ValueError, KeyError):
        return None


CASE_KEYS = ('script', 'scripts', 'mode', 'tag', 'env', 'nf_env', 'engines', 'data', 'after')   # not paths: a remap is no change


def headline_reason(c, new_scripts, old_cases):
    """Why a picked check counts as added or changed since the last release (None if it doesn't): on the freeze
    list (--extra, with its owner's new PASS count), a new script, or a new or edited catalog entry. An edit to an
    existing Debug check alone (a check fix) is not a headline; put the check in --extra to make it one."""
    names = {c['script'], *c.get('scripts', [])}
    if c.get('extra'):
        return 'new check (--extra)'
    if names & new_scripts:
        return 'new check'
    if old_cases is not None:
        old = old_cases.get(c['id'])
        if old is None:
            return 'new catalog entry'
        if any(old.get(k) != c.get(k) for k in CASE_KEYS):
            return 'catalog entry changed'
    return None


def select(catalog, base, rev, extra=None):
    """Gate picks: core + product paths. Test-only changes (Debug/, check scripts) go to the head of the tail."""
    changed = [p for p in git('diff', '--name-only', base, rev).split() if p]
    ignored, engine, broad, unmapped = [], [], [], []
    debug = debug_map(rev)
    by_script = {}
    for c in catalog['cases']:
        for name in [c['script'], *c.get('scripts', [])]:
            by_script.setdefault(name, []).append(c)
    picked, tail_first = {}, {}

    def pick(case, why, into=picked):
        entry = into.setdefault(case['id'], dict(case, reason=[]))
        if why not in entry['reason']:
            entry['reason'].append(why)

    for c in catalog['cases']:
        if c.get('tier') == 'core':
            pick(c, 'core')
    new_scripts = set()
    for path in changed:
        if path == DEBUG + 'SnapshotRunner.swift':
            scripts, other = runner_cases_changed(base, rev)
            for s in scripts:
                for c in by_script.get(s, []):
                    pick(c, 'case line ' + s, tail_first)
                if s not in by_script:
                    new_scripts.add(s)
            if other:
                broad.append(f'SnapshotRunner.swift ({other} harness lines: the fast gate re-applies its overlay)')
            continue
        if matches(path, catalog['ignore_paths']) and not path.startswith('infra/release/cloudkit'):
            ignored.append(path); continue
        hit = False
        if path.startswith(DEBUG) or path.startswith('scripts/tests/'):
            # test code: never in the public build, so it can't break the release; its checks still run, first in the tail
            for s in sorted(debug_scripts(path, debug)):
                for c in by_script.get(s, []):
                    pick(c, 'check ' + Path(path).name, tail_first); hit = True
                if s not in by_script and not s.startswith(('marketing', 'social')):
                    new_scripts.add(s); hit = True
            for c in catalog['cases']:
                if matches(path, c.get('paths', [])):
                    pick(c, path, tail_first); hit = True
            if not hit:
                unmapped.append(path)
            continue
        if matches(path, catalog['engine_paths']):
            engine.append(path); hit = True
            for c in catalog['cases']:
                if c.get('engine'):
                    pick(c, 'engine: ' + path)
        if matches(path, catalog['broad_paths']):
            broad.append(path); hit = True
        for c in catalog['cases']:
            if matches(path, c.get('paths', [])):
                pick(c, path); hit = True
        if not hit:
            unmapped.append(path)
    for c in load_extra(extra):
        if c['id'] in picked:
            picked[c['id']]['engines'].update(c['engines'])
            picked[c['id']]['extra'] = True
            picked[c['id']]['paths'] = sorted(set(picked[c['id']].get('paths', [])) | set(c['paths']))
        else:
            if not c['paths']:   # a new run of a catalogued check covers that check's paths
                c['paths'] = sorted({p for k in by_script.get(c['script'], []) for p in k.get('paths', [])})
            picked[c['id']] = c
        new_scripts.discard(c['script'])
    # headline checks: the check itself was added or changed since the last release AND its own product paths
    # changed. They are what the release is about, so they run before LIVE whatever the budget (plan raises it).
    old_cases = catalog_cases_at(base)
    product = [p for p in changed if p not in ignored and not p.startswith((DEBUG, 'scripts/tests/'))]
    for cid, c in picked.items():
        if c.get('tier') in ('core', 'timing'):
            continue
        why = headline_reason(c, new_scripts, old_cases)
        own = sorted({p for p in product if matches(p, c.get('paths', []))})
        if why and own:
            c['headline'] = f"{why}; own paths changed: {', '.join(Path(p).name for p in own[:3])}{' …' if len(own) > 3 else ''}"
        elif c.get('extra') and not c.get('paths'):
            c['headline_unknown'] = 'extra without paths= and no catalog entry: add paths= to tell whether it is a headline check'
    # a full run replaces its subsets
    for cid, c in list(picked.items()):
        if c.get('subset_of') in picked and not c.get('headline'):
            picked[c['subset_of']]['reason'].append(f'(covers {cid})')
            tail_first.setdefault(cid, dict(c, reason=['subset of a gate run']))
            del picked[cid]
    # posted/real twins (same script, same env): the gate runs the one with more assertions, the tail the other
    twins = {}
    for cid, c in picked.items():
        if c['kind'] in ('nf', 'agents', 'signin') and c.get('tier') != 'core' and c.get('mode') in ('posted', 'real', 'bg', 'tfg'):
            twins.setdefault((c['script'], tuple(c.get('env', [])), tuple(c.get('nf_env', [])), c.get('tag', '').replace(c.get('mode', ''), '')), []).append(cid)
    for ids in twins.values():
        if len(ids) > 1:
            keep = max(ids, key=lambda i: (bool(picked[i].get('headline')), max(picked[i]['engines'].values()), picked[i].get('mode') == 'real'))
            for i in ids:
                if i != keep:
                    tail_first.setdefault(i, dict(picked[i], reason=[f'twin of {keep}']))
                    del picked[i]
    for cid in list(tail_first):
        if cid in picked:
            del tail_first[cid]
    for c in picked.values():
        exact = sum(1 for path in changed if any('*' not in p and fnmatch.fnmatch(path, expand(p)) for p in c.get('paths', [])))
        wild = sum(1 for path in changed if matches(path, c.get('paths', [])))
        c['score'] = 3 * exact + wild + (100 if c.get('security') or c.get('must') else 0) + (50 if any(r.startswith('engine:') for r in c['reason']) else 0)
    return dict(base=base, rev=rev, changed=changed, ignored=ignored, engine=engine, broad=broad,
                unmapped=unmapped, new_scripts=sorted(new_scripts), picked=list(picked.values()),
                tail_first=list(tail_first.values()))


def runs(case):
    """One launch per engine (a bespoke group is one command for all its engines)."""
    if case['kind'] == 'group':
        yield dict(id=case['id'], case=case['id'], engine='+'.join(sorted(case['engines'])), want=sum(case['engines'].values()),
                   kind='group', script=case['script'], mode='group', tag='', env=[], nf_env=[], data=None, limit=0,
                   after=None, allow_env=None, seconds=sum(case.get('seconds', {}).values()), idle=0, tier=case.get('tier'),
                   reason=case.get('reason', []))
        return
    for engine, want in sorted(case['engines'].items()):
        yield dict(id=f"{engine}-{case['id']}", case=case['id'], engine=engine, want=want, kind=case['kind'],
                   script=case['script'], mode=case.get('mode', 'bg'), tag=case.get('tag', ''),
                   env=case.get('env', []), nf_env=case.get('nf_env', []), data=case.get('data'),
                   limit=case.get('limit', 600), after=case.get('after'), allow_env=case.get('allow_env'),
                   seconds=case.get('seconds', {}).get(engine, 60), idle=case.get('idle'),
                   tier=case.get('tier'), reason=case.get('reason', []))


def order(items, defaults):
    """Idle-hungry launches first or after HID-free time; relaunch pairs keep their order. Returns (items, model)."""
    overhead = defaults['overhead_seconds']
    def need(r):
        return r['idle'] if r['idle'] is not None else defaults['idle_by_mode'].get(r['mode'], 6)
    pending = list(items)
    done, clock, last_hid_end, waits = [], 0.0, -10 ** 6, 0.0
    names = {r['id'] for r in pending}
    while pending:
        ready = [r for r in pending if not r['after'] or f"{r['engine']}-{r['after']}" not in names
                 or f"{r['engine']}-{r['after']}" in {d['id'] for d in done}]
        idle_now = clock - last_hid_end
        # prefer a launch whose idle need is already met; among those, the hungriest; else the shortest wait
        fit = [r for r in ready if need(r) <= idle_now]
        r = max(fit, key=lambda r: (need(r), r['mode'] not in HID_MODES)) if fit else min(ready, key=lambda r: need(r) - idle_now)
        wait = max(0.0, need(r) - idle_now)
        waits += wait
        clock += wait + r['seconds'] + overhead
        if r['mode'] in HID_MODES or r['kind'] in ('signin', 'passkeyquit') and r['mode'] == 'real':
            last_hid_end = clock
        done.append(dict(r, est_wait=round(wait), est_end=round(clock)))
        pending.remove(r)
    return done, dict(total=clock, waits=waits, launches=len(done))


def plan(args):
    catalog = json.loads(CATALOG.read_text())
    rev = git('rev-parse', args.to).strip()
    base = git('rev-parse', args.base or last_release_source(rev)).strip()
    sel = select(catalog, base, rev, args.extra)
    # the gate budget: core, then security/engine picks, then the most specific changed-path picks per second
    gate_cases = sorted((c for c in sel['picked'] if c.get('tier') != 'timing'),
                        key=lambda c: (c.get('tier') != 'core', -c.get('score', 0), sum(c.get('seconds', {}).values())))
    spent, kept, over, raised = 0, [], [], []
    for c in gate_cases:
        cost = sum(c.get('seconds', {}).values()) + catalog['defaults']['overhead_seconds'] * len(c['engines'])
        if c.get('headline') and c.get('tier') != 'core' and c.get('score', 0) < 50:
            # the release's own new/changed checks: before LIVE, on top of the budget (not taken from it)
            kept.append(c); c['reason'] = ['HEADLINE ' + c['headline'], *c['reason']]
            raised.append(dict(id=c['id'], seconds=cost, why=c['headline']))
        elif c.get('tier') == 'core' or c.get('score', 0) >= 50 or not args.budget or spent + cost <= args.budget:
            kept.append(c); spent += cost
        else:
            over.append(dict(c, reason=['over the gate budget (' + '; '.join(c['reason'])[:60] + ')']))
    sel['tail_first'] = over + sel['tail_first']
    sel['picked'] = kept + [c for c in sel['picked'] if c.get('tier') == 'timing']
    gate = [r for c in kept for r in runs(c)]
    picked_ids = {c['id'] for c in sel['picked']}
    first_ids = {c['id'] for c in sel['tail_first']}
    head = [r for c in sel['tail_first'] for r in runs(c)]
    rest = [r for c in catalog['cases'] if (c['id'] not in picked_ids or c.get('tier') == 'timing') and c['id'] not in first_ids
            for r in runs(dict(c, reason=['tail']))]
    gate, gm = order(gate, catalog['defaults'])
    head, hm = order(head, catalog['defaults'])
    rest, tm = order(rest, catalog['defaults'])
    tail = head + rest
    tm = dict(total=hm['total'] + tm['total'], waits=hm['waits'] + tm['waits'])
    signed_gate = sum(s['seconds'] for s in catalog['signed'] if s['tier'] == 'release')
    signed_tail = sum(s['seconds'] for s in catalog['signed'] if s['tier'] == 'tail')
    out = dict(schema=1, made=datetime.now(timezone.utc).strftime('%FT%TZ'), base=base, rev=rev,
               changed=len(sel['changed']), ignored=sel['ignored'], engine_paths=sel['engine'], broad=sel['broad'],
               unmapped=sel['unmapped'], new_scripts=sel['new_scripts'], gate=gate, tail=tail, tail_head=len(head),
               budget=args.budget, estimate=dict(gate_smokes_s=round(gm['total']), gate_idle_waits_s=round(gm['waits']),
                             signed_release_s=signed_gate, tail_s=round(tm['total'] + signed_tail),
                             tail_idle_waits_s=round(tm['waits'])))
    out['budget_raised'] = dict(seconds=sum(x['seconds'] for x in raised), checks=raised,
                                why='headline checks (new/changed since the last release, own paths changed) run before LIVE') if raised else None
    out['headline_unknown'] = [dict(id=c['id'], why=c['headline_unknown']) for c in sel['picked'] if c.get('headline_unknown')]
    out['allow'] = [dict(target=t, regex=rx, max=mx) for t, rules in parse_allow(args.allow).items() for rx, mx in rules]
    ids = {x for r in gate + tail for x in (r['id'], r['case'])}
    out['allow_unknown'] = [a['target'] for a in out['allow'] if a['target'] not in ids]
    if args.json:
        Path(args.json).write_text(json.dumps(out, indent=1) + '\n')
    report(out, catalog)
    return 1 if sel['new_scripts'] else 0


def mmss(s):
    return f'{int(s) // 60}:{int(s) % 60:02d}'


def report(p, catalog):
    print(f"release smokes {p['base'][:8]}..{p['rev'][:8]}: {p['changed']} changed paths, {len(p['ignored'])} need no smoke")
    for label, key in (('engine', 'engine_paths'), ('broad (fast gate + core cover them)', 'broad'), ('NOT COVERED by any smoke (core + fast gate only)', 'unmapped')):
        if p[key]:
            print(f'  {label}: ' + ', '.join(p[key][:12]) + (' …' if len(p[key]) > 12 else ''))
    if p['new_scripts']:
        print('  NEW CHECKS without a catalog entry (add them to --extra with the owner\'s PASS count): ' + ', '.join(p['new_scripts']))
    br = p.get('budget_raised')
    raised = f" + {br['seconds']} s for {len(br['checks'])} headline checks" if br else ''
    print(f"\nGATE (test build, after the fast gate; budget {p['budget'] or 'none'} s{raised}): {len(p['gate'])} launches")
    for r in p['gate']:
        wait = f" (+{r['est_wait']} s idle)" if r['est_wait'] > 8 else ''
        print(f"  {mmss(r['est_end']):>6}  {r['engine']:8s} {r['script']:22s} {r['mode']}{r['tag']:12s} want {r['want']:>3}{wait}  ← {'; '.join(r['reason'])[:90]}")
    e = p['estimate']
    if br:
        print('  budget raised for headline checks (they run before LIVE): ' +
              '; '.join(f"{x['id']} {x['seconds']} s ({x['why']})" for x in br['checks']))
    for x in p.get('headline_unknown', []):
        print(f"  HEADLINE? {x['id']}: {x['why']}")
    for a in p.get('allow', []):
        print(f"  allowance (lowers the want by the lines it excuses): {a['target']} ≤ {a['max']}: {a['regex']}"
              + ('   ← NO SUCH RUN OR CASE in this plan' if a['target'] in p.get('allow_unknown', []) else ''))
    print(f"  ≈ {mmss(e['gate_smokes_s'])} min smokes ({mmss(e['gate_idle_waits_s'])} of it idle waits) + {mmss(e['signed_release_s'])} min signed-build smokes")
    print(f"\nTAIL (after LIVE, same test build; a red blocks the NEXT release): {len(p['tail'])} launches ≈ {e['tail_s'] / 3600:.1f} h "
          f"(idle waits {mmss(e['tail_idle_waits_s'])} min), incl. timing: " +
          ', '.join(sorted({r['script'] for r in p['tail'] if r['tier'] == 'timing'})) + ', ' +
          ', '.join(s['id'] for s in catalog['signed'] if s['tier'] == 'tail'))
    if p.get('tail_head'):
        print(f"  tail starts with {p['tail_head']} launches for changed checks/test code and gate twins:")
        for r in p['tail'][:p['tail_head']]:
            print(f"    {r['engine']:8s} {r['script']:22s} {r['mode']}{r['tag']:12s} ← {'; '.join(r['reason'])[:80]}")


# ---- run -------------------------------------------------------------------------------------------------------

def now():
    return datetime.now(timezone.utc).strftime('%FT%TZ')


def held(own_staging=False):
    if any((STATUS / h).exists() for h in HOLDS) or (not own_staging and (STATUS / 'release-staging').exists()):
        return True
    r = subprocess.run(SSH + ['test ! -e /tmp/owner-ui-hold.state || test "$(cat /tmp/owner-ui-hold.state)" = released'])
    return r.returncode != 0


def mac(cmd, timeout=None):
    return subprocess.run(SSH + [cmd], text=True, capture_output=True, timeout=timeout)


def remote_command(r, work):
    w = f'~/arcfork/work/{work}'
    name = r['id'] + r['tag'] if r['tag'] and not r['id'].endswith(r['tag']) else r['id']
    lim = r['limit']
    if r['kind'] == 'nf':
        env = f"NF_ENV={shlex.quote(' '.join(r['nf_env']))} " if r['nf_env'] else ''
        return name, f"cd {w} && {env}bash infra/release/smokes/nf-check.sh {r['engine']} {r['script']} {r['mode']} {lim} {name}", f'{w}/build/runs/smoke/{name}'
    if r['kind'] == 'agents':
        env = ''.join(f"OPEN_ENV{'' if i == 0 else '2'}={shlex.quote(e)} " for i, e in enumerate(r['env'][:2]))
        data = f"DATA=$HOME/arcfork/work/{work}/build/runs/data-{r['engine']}-{r['data']}-{r['mode']} " if r['data'] else ''
        run = 'real' if r['mode'] == 'real' else 'posted'
        return name, f"cd {w} && {env}{data}LIMIT={lim} bash infra/release/smokes/agents-run.sh {r['engine']} {run} {r['script']} {name}", f'{w}/build/runs/smoke/{name}/out'
    if r['kind'] == 'signin':
        return name, f"cd {w} && LIMIT={lim} bash scripts/tests/signin/run-checks.sh {r['engine']} {r['mode']} {name}", f"{w}/build/runs/signin-{r['engine']}-{r['mode']}-{name}/out"
    if r['kind'] == 'passkeyquit':
        env = ' '.join(r['env'])
        return name, f"cd {w} && {env} LIMIT={lim} bash scripts/tests/passkeyquit/run-checks.sh {r['engine']} {r['mode']} {name}", f"{w}/build/runs/passkeyquit-{r['engine']}-{r['mode']}-{name}/out"
    return name, None, None


def parse_allow(items):
    """--allow CASE_OR_RUN_ID=REGEX[:MAX] (MAX default 1) → {id: [(regex, max)]}."""
    allow = {}
    for a in items or []:
        cid, rule = a.split('=', 1)
        regex, _, mx = rule.rpartition(':') if re.search(r':\d+$', rule) else (rule, '', '1')
        if (regex, int(mx)) not in allow.get(cid, []):
            allow.setdefault(cid, []).append((regex, int(mx)))
    return allow


def judge(text, r, allow):
    """(ok, critical, passes, unexcused fails, excused fails, info). info: want_effective and the rules used.
    A lead-ruled line (allow) stands for a PASS the check didn't print, so each line it excuses lowers the want by
    one: a run whose only FAILs are excused lines is green, and any other FAIL or missing PASS stays red. A rule
    that matches more lines than its MAX excuses none of them. The catalog's allow_env (FAIL-ENV notes printed
    besides the PASS lines) excuses without changing the want."""
    lines = text.splitlines()
    p = sum(l.startswith('PASS') for l in lines)
    fails = [l for l in lines if re.match(r'(FAIL|FAIL-ENV|ENGINE-FAIL)\b', l)]
    taken, lead, used = set(), set(), []
    if r.get('allow_env'):
        a = [i for i, l in enumerate(fails) if l.startswith('FAIL-ENV') and re.search(r['allow_env']['regex'], l)]
        if len(a) <= r['allow_env']['max']:
            taken.update(a)
    for target in (r['case'], r['id']):
        for regex, mx in allow.get(target, []):
            a = [i for i, l in enumerate(fails) if i not in taken and re.search(regex, l)]
            if a:
                used.append(dict(target=target, regex=regex, max=mx, matched=len(a), excused=len(a) <= mx))
            if a and len(a) <= mx:
                taken.update(a); lead.update(a)
    want = max(0, r['want'] - len(lead))
    left = [l for i, l in enumerate(fails) if i not in taken]
    allowed = [l for i, l in enumerate(fails) if i in taken]
    critical = bool(CRITICAL.search('\n'.join(left)))
    ok = p >= want and not left
    return ok, critical, p, left, allowed, dict(want=r['want'], want_effective=want, lowered_by=len(lead), rules=used)


def run(args):
    p = json.loads(Path(args.plan).read_text())
    items = p[args.tier]
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    log = out / 'smokes.log'
    # the plan's allowances (set at the freeze) plus any given here
    allow = parse_allow([f"{a['target']}={a['regex']}:{a['max']}" for a in p.get('allow', [])] + (args.allow or []))
    groups = {}
    for line in (Path(args.groups).read_text().splitlines() if args.groups else []):
        if line.strip() and not line.startswith('#'):
            k, _, v = line.partition('\t'); groups[k.strip()] = v.strip()
    state_file = STATUS / 'release-tail.json' if args.tier == 'tail' else out / 'gate-smokes.json'
    state = dict(tier=args.tier, rev=p['rev'], work=args.work, release=args.release, started=now(), state='running',
                 results=[], reds=[], critical=[],
                 allow=[dict(target=t, regex=rx, max=mx) for t, rules in allow.items() for rx, mx in rules])
    def save():
        tmp = state_file.with_suffix('.tmp'); tmp.write_text(json.dumps(state, indent=1) + '\n'); tmp.replace(state_file)
    save()
    w = f'~/arcfork/work/{args.work}'
    mac(f'mkdir -p {w}/infra/release/smokes')
    subprocess.run(['scp', '-q', *map(str, (HERE / 'smokes').glob('*.sh')), f'buildmac:arcfork/work/{args.work}/infra/release/smokes/'], check=True)
    mac(f'bash {w}/infra/release/smokes/mac-helper.sh mark {w}/build/runs/smoke-crash-mark')
    t0 = time.time()
    with log.open('a') as L:
        for r in items:
            if args.tier == 'tail' and (STATUS / 'release-staging').exists() and not args.during_staging:
                state.update(state='yielded', reason='release-staging exists: the next release has the UI'); save()
                print(f'{now()} tail yields to release-staging', file=L); return 75
            name, cmd, remote_out = remote_command(r, args.work)
            if cmd is None:
                # A bespoke group (fixtures, fake apps, mock cloud): its release script, from --groups (id<TAB>command,
                # run here on Linux). None given = red: a selected group never silently drops out.
                gcmd = groups.get(r['case'])
                rc = subprocess.run(['bash', '-c', gcmd], stdout=L, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode if gcmd else 1
                verdict = 'PASS' if rc == 0 else 'FAIL'
                res = dict(id=r['id'], script=r['script'], verdict=verdict, rc=rc, at=now(),
                           note=gcmd or 'no --groups command for this group')
                state['results'].append(res)
                if rc:
                    state['reds'].append(r['id'])
                save(); print(f"{now()} smoke {args.tier} group {r['case']}: rc {rc} -> {verdict}", file=L, flush=True); continue
            for attempt in range(1, 16):
                while held(args.during_staging):
                    time.sleep(30)
                need = r['idle'] if r['idle'] is not None else 6
                idle = mac(f'bash {w}/infra/release/smokes/mac-helper.sh idle {need} 900').stdout.strip()
                rc = subprocess.run(SSH + [cmd], stdout=L, stderr=subprocess.STDOUT).returncode
                if rc != 75:
                    break
                print(f'{now()} lock refused ({r["id"]}), retry in 60 s', file=L, flush=True); time.sleep(60)
            d = out / args.tier / name
            d.mkdir(parents=True, exist_ok=True)
            subprocess.run(['rsync', '-az', '--exclude=home', '--exclude=Data', '--exclude=Chromium', f'buildmac:{remote_out.replace("~/", "")}/', f'{d}/'])
            text = (d / 'log.txt').read_text(errors='replace') if (d / 'log.txt').exists() else ''
            ok, critical, npass, left, allowed, info = judge(text, r, allow)
            if (d / 'hang.txt').exists():
                ok, critical = False, True; left.append('runner: still running at its limit (hang.txt sampled)')
            if not text.strip():
                ok = False; left.append('no log.txt / 0 assertions (zero-guard)')
            if r['script'] == 'cbperf':   # standing ruling: first key must PASS, the median is recorded
                ok = npass >= info['want_effective'] and 'PASS cbperf: first keystroke' in text and not [l for l in left if 'median keystroke' not in l]
            verdict = 'PASS' if ok else 'FAIL'
            res = dict(id=r['id'], script=r['script'], mode=r['mode'] + r['tag'], verdict=verdict, critical=critical, rc=rc,
                       passes=npass, want=r['want'], want_effective=info['want_effective'], fails=left[:20], allowed=allowed,
                       allowances=info['rules'], idle=idle, at=now())
            state['results'].append(res)
            if not ok:
                state['reds'].append(r['id'])
            if critical:
                state['critical'].append(r['id'])
            save()
            wanted = f"{info['want_effective']} = {r['want']} - {info['lowered_by']} allowed" if info['lowered_by'] else r['want']
            print(f"{now()} smoke {args.tier} {r['engine']} {r['script']} {r['mode']}{r['tag']}: PASS {npass} (want >= {wanted}) "
                  f"FAIL {len(left)}{' ALLOWED ' + str(len(allowed)) if allowed else ''} rc {rc} [{idle}] -> {verdict}{' CRITICAL' if critical else ''}",
                  file=L, flush=True)
            if critical and args.tier == 'gate':
                break
    crash = mac(f'bash {w}/infra/release/smokes/mac-helper.sh crashes {w}/build/runs/smoke-crash-mark')
    if crash.returncode:
        state['critical'].append('crash report: ' + crash.stdout.strip().replace('\n', ' '))
    state.update(state='complete' if not state['reds'] and not state['critical'] else 'red', ended=now(),
                 minutes=round((time.time() - t0) / 60, 1))
    save()
    with log.open('a') as L:
        print(f"{now()} {args.tier} smokes {state['state']}: {len(state['results'])} launches in {state['minutes']} min; reds {state['reds']} critical {state['critical']}", file=L)
    return 0 if state['state'] == 'complete' else 1


def tail_status(args):
    f = Path(args.status) / 'release-tail.json'
    if not f.exists():
        print('no release tail recorded'); return 0
    s = json.loads(f.read_text())
    print(json.dumps({k: s.get(k) for k in ('release', 'rev', 'state', 'started', 'ended', 'reds', 'critical', 'ruled')}, indent=1))
    return 0


def blockers(args):
    """The next release waits while the previous tail is red and not ruled, or has a crash/hang."""
    f = Path(args.status) / 'release-tail.json'
    if not f.exists():
        print('OK: no release tail recorded'); return 0
    s = json.loads(f.read_text())
    ruled = set(s.get('ruled', []))
    reds = [r for r in s.get('reds', []) if r not in ruled]
    if s.get('critical'):
        print(f"BLOCKED: {s.get('release')} tail has crash/hang-class reds: {s['critical']} (never self-ruled; lead)"); return 1
    if reds:
        print(f"BLOCKED: {s.get('release')} tail red: {reds}: fix on main, rerun, or rule it (add the id to 'ruled' with the evidence)"); return 1
    if s.get('state') in ('running', 'yielded'):
        print(f"OK with FYI: {s.get('release')} tail {s['state']} ({len(s.get('results', []))} done, no reds so far); its rest joins this release's tail")
        return 0
    print(f"OK: {s.get('release')} tail {s.get('state')}"); return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('plan'); a.add_argument('--from', dest='base'); a.add_argument('--to', default='HEAD')
    a.add_argument('--extra'); a.add_argument('--json')
    a.add_argument('--allow', action='append', help='CASE_OR_RUN_ID=REGEX[:MAX]: a lead-ruled line, stored in the plan for run')
    a.add_argument('--budget', type=int, default=900, help='gate smoke seconds (core always runs; security/engine picks too); 0 = no cap')
    b = sub.add_parser('run'); b.add_argument('--plan', required=True); b.add_argument('--tier', choices=('gate', 'tail'), required=True)
    b.add_argument('--work', required=True); b.add_argument('--out', required=True); b.add_argument('--release', default='')
    b.add_argument('--allow', action='append', help='CASE_OR_RUN_ID=REGEX[:MAX] (a lead-approved line)')
    b.add_argument('--groups', help='id<TAB>command per bespoke group (run on Linux; rc 0 = PASS)')
    b.add_argument('--during-staging', action='store_true',
                   help='the release that owns status/release-staging (its gate, or its tail before staging is removed); others wait for it')
    for n in ('tail-status', 'blockers'):
        c = sub.add_parser(n); c.add_argument('--status', default=str(STATUS))
    args = ap.parse_args()
    return dict(plan=plan, run=run, **{'tail-status': tail_status, 'blockers': blockers})[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
