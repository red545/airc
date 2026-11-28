#!/usr/bin/env python3
"""Unit checks for smokes.py: judging, idle ordering, Debug mapping and blockers (no Mac needed)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
import smokes  # noqa: E402

DEFAULTS = {'overhead_seconds': 0, 'idle_by_mode': {'bg': 0, 'posted': 0, 'real': 6, 'tfg': 6}}


def run(id, mode, seconds, idle=None, after=None, engine='chromium'):
    return dict(id=f'{engine}-{id}', case=id, engine=engine, mode=mode, seconds=seconds, idle=idle, after=after,
                kind='nf', want=1, script=id, tag='')


class Judge(unittest.TestCase):
    def test_want_and_fails(self):
        r = dict(case='x', id='chromium-x', want=2, allow_env=None)
        self.assertTrue(smokes.judge('PASS a\nPASS b\n', r, {})[0])
        self.assertFalse(smokes.judge('PASS a\n', r, {})[0])
        ok, critical, _, left, _, _ = smokes.judge('PASS a\nPASS b\nFAIL the app crashed\n', r, {})
        self.assertFalse(ok); self.assertTrue(critical); self.assertEqual(len(left), 1)

    def test_allowances_are_bounded(self):
        r = dict(case='x', id='chromium-x', want=1, allow_env={'regex': 'covered', 'max': 1})
        self.assertTrue(smokes.judge('PASS a\nFAIL-ENV covered\n', r, {})[0])
        self.assertFalse(smokes.judge('PASS a\nFAIL-ENV covered\nFAIL-ENV covered\n', r, {})[0])
        self.assertTrue(smokes.judge('PASS a\nFAIL k i\n', r, {'x': [('k i', 1)]})[0])

    def test_lead_allowance_lowers_the_want(self):
        # agentpane2 real, 0.1.64: 222 PASS + the one ruled line = the want 223: green, and the json says why
        r = dict(case='agentpane2-real', id='chromium-agentpane2-real', want=4, allow_env=None)
        allow = smokes.parse_allow(['chromium-agentpane2-real=^FAIL needs you \\[notification\\]:1'])
        ok, critical, n, left, allowed, info = smokes.judge('PASS a\nPASS b\nPASS c\nFAIL needs you [notification]\n', r, allow)
        self.assertTrue(ok); self.assertFalse(critical); self.assertEqual(left, [])
        self.assertEqual((info['want'], info['want_effective'], info['lowered_by']), (4, 3, 1))
        self.assertEqual(info['rules'][0]['matched'], 1)
        # strict: one more missing PASS is red
        self.assertFalse(smokes.judge('PASS a\nPASS b\nFAIL needs you [notification]\n', r, allow)[0])
        # strict: any other FAIL is red
        self.assertFalse(smokes.judge('PASS a\nPASS b\nPASS c\nFAIL needs you [notification]\nFAIL other\n', r, allow)[0])
        # the allowed line passing instead: the want stays whole
        ok, _, _, _, _, info = smokes.judge('PASS a\nPASS b\nPASS c\nPASS needs you\n', r, allow)
        self.assertTrue(ok); self.assertEqual(info['want_effective'], 4)
        self.assertFalse(smokes.judge('PASS a\nPASS b\nPASS c\n', r, allow)[0])
        # over MAX: nothing is excused and the want is not lowered
        two = 'PASS a\nPASS b\nFAIL needs you [notification]\nFAIL needs you [notification]\n'
        ok, _, _, left, _, info = smokes.judge(two, r, allow)
        self.assertFalse(ok); self.assertEqual(len(left), 2); self.assertEqual(info['want_effective'], 4)
        self.assertFalse(info['rules'][0]['excused'])

    def test_allowance_rules_for_case_and_run_count_a_line_once(self):
        r = dict(case='x', id='webkit-x', want=2, allow_env={'regex': 'covered', 'max': 1})
        allow = {'x': [('dup', 1)], 'webkit-x': [('dup', 1)]}
        ok, _, _, _, allowed, info = smokes.judge('PASS a\nFAIL dup\nFAIL-ENV covered\n', r, allow)
        self.assertTrue(ok); self.assertEqual(info['lowered_by'], 1); self.assertEqual(len(allowed), 2)
        # the catalog's FAIL-ENV note excuses but does not lower the want
        ok, _, _, _, _, info = smokes.judge('PASS a\nFAIL-ENV covered\n', r, allow)
        self.assertFalse(ok); self.assertEqual(info['want_effective'], 2)

    def test_parse_allow(self):
        self.assertEqual(smokes.parse_allow(['a=^FAIL x:3', 'a=^FAIL x:3', 'b=FAIL 10:20 y']),
                         {'a': [('^FAIL x', 3)], 'b': [('FAIL 10:20 y', 1)]})


class Standing(unittest.TestCase):
    """A standing lead ruling joins every plan and run by itself and covers the case's subset runs (0.1.65's tail:
    the 05:34Z full-screen lines were allowed for agentpane2-posted/-real but not for -ux3, -needsyou, -agentfix)."""
    LINE = 'FAIL agentpane2 chromium: needs you [notification, from a full-screen window] [posted: x]'

    def rulings(self, d, lifted=None):
        f = Path(d) / 'standing.json'
        f.write_text(json.dumps(dict(rulings=[
            dict(target='chromium-agentpane2-posted', regex=r'^FAIL agentpane2 chromium: needs you \[notification', max=3,
                 ruled='lead 2026-11-27T05:34Z', why='posted only', **({'lifted': lifted} if lifted else {})),
            dict(target='y', regex='z', max=1, ruled='lead', why='w', lifted='lead: fixed')])))
        return f

    def test_subset_runs_inherit_the_parent_rule(self):
        allow = smokes.parse_allow([r'chromium-agentpane2-posted=^FAIL agentpane2 chromium: needs you \[notification:3'])
        sub = dict(case='agentpane2-posted-ux3', id='chromium-agentpane2-posted-ux3', engine='chromium', want=3,
                   allow_env=None, subset_of='agentpane2-posted')
        ok, _, _, left, allowed, info = smokes.judge(f'PASS a\nPASS b\n{self.LINE}\n', sub, allow)
        self.assertTrue(ok); self.assertEqual(left, []); self.assertEqual(info['want_effective'], 2)
        # without subset_of (as before): red
        self.assertFalse(smokes.judge(f'PASS a\nPASS b\n{self.LINE}\n', dict(sub, subset_of=None), allow)[0])
        # another engine's rule never covers it
        other = smokes.parse_allow([r'webkit-agentpane2-posted=^FAIL agentpane2 chromium: needs you:3'])
        self.assertFalse(smokes.judge(f'PASS a\nPASS b\n{self.LINE}\n', sub, other)[0])
        # a case rule reaches subsets too; still strict on other FAILs
        case = smokes.parse_allow([r'agentpane2-posted=needs you \[notification:3'])
        self.assertTrue(smokes.judge(f'PASS a\nPASS b\n{self.LINE}\n', sub, case)[0])
        self.assertFalse(smokes.judge(f'PASS a\nPASS b\n{self.LINE}\nFAIL other\n', sub, case)[0])

    def test_catalog_runs_carry_subset_of(self):
        cat = json.loads(smokes.CATALOG.read_text())
        ux3 = next(c for c in cat['cases'] if c['id'] == 'agentpane2-posted-ux3')
        self.assertEqual({r['subset_of'] for r in smokes.runs(ux3)}, {'agentpane2-posted'})

    def test_standing_file_loads_only_active_rulings(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual([a['target'] for a in smokes.standing_rulings(self.rulings(d))], ['chromium-agentpane2-posted'])
            self.assertEqual(smokes.standing_rulings(self.rulings(d, lifted='lead: fixed')), [])
            self.assertEqual(smokes.standing_rulings(Path(d) / 'none.json'), [])
            bad = Path(d) / 'bad.json'; bad.write_text(json.dumps(dict(rulings=[dict(target='x', regex='y')])))
            with self.assertRaises(SystemExit):
                smokes.standing_rulings(bad)      # no ruled/why: refused, never silently applied

    def test_repo_standing_file_is_valid(self):
        for a in smokes.standing_rulings():
            self.assertFalse(smokes.CRITICAL.search(a['regex'].replace('\\', '')), a)   # never a crash/hang line
            self.assertTrue(a['ruled'].startswith('lead'), a)
        ids = {x for c in json.loads(smokes.CATALOG.read_text())['cases'] for r in smokes.runs(c) for x in (r['id'], r['case'])}
        self.assertEqual([a['target'] for a in smokes.standing_rulings() if a['target'] not in ids], [])   # no typo'd target

    def test_plan_carries_standing_rulings(self):
        cat = dict(defaults=dict(overhead_seconds=0, idle_by_mode={}), signed=[], cases=[
            dict(id='agentpane2-posted', kind='agents', script='agentpane2', mode='posted', tier='core',
                 engines={'chromium': 9}, seconds={'chromium': 10}),
            dict(id='agentpane2-posted-ux3', kind='agents', script='agentpane2', mode='posted', tag='-ux3',
                 subset_of='agentpane2-posted', engines={'chromium': 3}, seconds={'chromium': 5})])
        sel = dict(changed=[], ignored=[], engine=[], broad=[], unmapped=[], new_scripts=[], tail_first=[],
                   picked=[dict(cat['cases'][0], reason=['core'])])
        orig = (smokes.select, smokes.git, smokes.CATALOG, smokes.STANDING)
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'cat.json'; f.write_text(json.dumps(cat)); out = Path(d) / 'plan.json'
            smokes.select, smokes.git, smokes.CATALOG, smokes.STANDING = (lambda *a: sel), (lambda *a: 'f' * 40), f, self.rulings(d)
            try:
                smokes.plan(SimpleNamespace(to='HEAD', base='b', extra=None, budget=0, json=str(out), allow=None))
            finally:
                smokes.select, smokes.git, smokes.CATALOG, smokes.STANDING = orig
            p = json.loads(out.read_text())
        self.assertEqual([(a['target'], a['standing']) for a in p['allow']], [('chromium-agentpane2-posted', 'lead 2026-11-27T05:34Z')])
        self.assertEqual(p['allow_unknown'], [])
        self.assertEqual([r['subset_of'] for r in p['tail']], ['agentpane2-posted'])

class Headline(unittest.TestCase):
    def test_reason(self):
        old = {'a-bg': dict(id='a-bg', script='a', mode='bg', engines={'chromium': 5})}
        same = dict(id='a-bg', script='a', mode='bg', engines={'chromium': 5}, paths=['S/x'])
        self.assertIsNone(smokes.headline_reason(same, set(), old))                       # unchanged check
        self.assertIsNone(smokes.headline_reason(same, set(), None))                      # no catalog at base
        self.assertIn('--extra', smokes.headline_reason(dict(same, extra=True), set(), old))
        self.assertEqual(smokes.headline_reason(same, {'a'}, old), 'new check')
        self.assertEqual(smokes.headline_reason(dict(same, engines={'chromium': 9}), set(), old), 'catalog entry changed')
        self.assertEqual(smokes.headline_reason(dict(same, id='a-real'), set(), old), 'new catalog entry')
        self.assertIsNone(smokes.headline_reason(dict(same, paths=['S/y']), set(), old))  # a path remap is no change

    def test_plan_raises_the_budget_for_headline_checks_only(self):
        cat = dict(defaults=dict(overhead_seconds=0, idle_by_mode={}), signed=[], cases=[
            dict(id='core-bg', kind='nf', script='core', mode='bg', tier='core', engines={'chromium': 1}, seconds={'chromium': 100}),
            dict(id='new-bg', kind='nf', script='new', mode='bg', engines={'chromium': 1}, seconds={'chromium': 500}),
            dict(id='old-bg', kind='nf', script='old', mode='bg', engines={'chromium': 1}, seconds={'chromium': 300}),
            dict(id='old2-bg', kind='nf', script='old2', mode='bg', engines={'chromium': 1}, seconds={'chromium': 300})])
        sel = dict(changed=['S/a'], ignored=[], engine=[], broad=[], unmapped=[], new_scripts=[], tail_first=[],
                   picked=[dict(cat['cases'][0], reason=['core']),
                           dict(cat['cases'][1], reason=['S/a'], score=1, headline='new check (--extra); own paths changed: a'),
                           dict(cat['cases'][2], reason=['S/a'], score=4), dict(cat['cases'][3], reason=['S/a'], score=3)])
        orig = (smokes.select, smokes.git, smokes.CATALOG)
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'cat.json'; f.write_text(json.dumps(cat)); out = Path(d) / 'plan.json'
            smokes.select, smokes.git, smokes.CATALOG = (lambda *a: sel), (lambda *a: 'f' * 40), f
            try:
                smokes.plan(SimpleNamespace(to='HEAD', base='b', extra=None, budget=450, json=str(out),
                                            allow=['old-bg=^FAIL x:2', 'nope=y']))
            finally:
                smokes.select, smokes.git, smokes.CATALOG = orig
            p = json.loads(out.read_text())
        gate = {r['case'] for r in p['gate']}
        self.assertEqual(gate, {'core-bg', 'new-bg', 'old-bg'})       # 100 + 300 within 450; the headline 500 on top
        self.assertIn('old2-bg', {r['case'] for r in p['tail']})
        self.assertEqual(p['budget_raised']['seconds'], 500)
        self.assertEqual([c['id'] for c in p['budget_raised']['checks']], ['new-bg'])
        self.assertEqual(p['allow'][0], dict(target='old-bg', regex='^FAIL x', max=2))
        self.assertEqual(p['allow_unknown'], ['nope'])


class Order(unittest.TestCase):
    def test_idle_hungry_after_hid_free_time(self):
        items = [run('fx', 'real', 20, idle=185), run('a', 'real', 30), run('b', 'bg', 100), run('c', 'bg', 100)]
        done, model = smokes.order(items, DEFAULTS)
        self.assertEqual(done[0]['case'], 'fx')          # idle is long at the start
        self.assertEqual(model['waits'], 0)
        items = [run('fx', 'real', 20, idle=185), run('fx2', 'real', 20, idle=185), run('b', 'bg', 100)]
        done, model = smokes.order(items, DEFAULTS)
        self.assertEqual([d['case'] for d in done], ['fx', 'b', 'fx2'])
        self.assertEqual(round(model['waits']), 85)       # 185 - 100 s of bg time

    def test_relaunch_pairs_keep_order(self):
        items = [run('rel', 'posted', 5, after='w'), run('w', 'posted', 5)]
        done, _ = smokes.order(items, DEFAULTS)
        self.assertEqual([d['case'] for d in done], ['w', 'rel'])


class Blockers(unittest.TestCase):
    def check(self, state):
        with tempfile.TemporaryDirectory() as d:
            if state is not None:
                (Path(d) / 'release-tail.json').write_text(json.dumps(state))
            return smokes.blockers(SimpleNamespace(status=d))

    def test_blockers(self):
        self.assertEqual(self.check(None), 0)
        self.assertEqual(self.check(dict(state='complete', reds=[], critical=[])), 0)
        self.assertEqual(self.check(dict(state='red', reds=['webkit-x'], critical=[])), 1)
        self.assertEqual(self.check(dict(state='red', reds=['webkit-x'], critical=[], ruled=['webkit-x'])), 0)
        self.assertEqual(self.check(dict(state='red', reds=['webkit-x'], critical=['webkit-x'], ruled=['webkit-x'])), 1)
        self.assertEqual(self.check(dict(state='yielded', reds=[], critical=[], results=[{}])), 0)


class Catalog(unittest.TestCase):
    def test_catalog_shape(self):
        c = json.loads(smokes.CATALOG.read_text())
        ids = [x['id'] for x in c['cases']]
        self.assertEqual(len(ids), len(set(ids)))
        core = [x for x in c['cases'] if x.get('tier') == 'core']
        self.assertTrue(all(set(x['engines']) == {'chromium', 'webkit'} for x in core))
        for x in c['cases']:
            self.assertIn(x['kind'], ('nf', 'agents', 'signin', 'passkeyquit', 'group'))
            self.assertTrue(set(x['engines']) <= {'chromium', 'webkit'}, x['id'])
            if x.get('subset_of'):
                self.assertIn(x['subset_of'], ids)

    def test_debug_extension_files_map(self):
        debug = {'apps/browser/Sources/Airc/Debug/AgentMainCheck.swift': {'agentmain'}}
        self.assertEqual(smokes.debug_scripts('apps/browser/Sources/Airc/Debug/AgentMainBlank.swift', debug), {'agentmain'})
        self.assertEqual(smokes.debug_scripts('apps/browser/Sources/Airc/Debug/Other.swift', debug), set())


if __name__ == '__main__':
    unittest.main()
