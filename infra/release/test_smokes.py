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
        ok, critical, _, left, _ = smokes.judge('PASS a\nPASS b\nFAIL the app crashed\n', r, {})
        self.assertFalse(ok); self.assertTrue(critical); self.assertEqual(len(left), 1)

    def test_allowances_are_bounded(self):
        r = dict(case='x', id='chromium-x', want=1, allow_env={'regex': 'covered', 'max': 1})
        self.assertTrue(smokes.judge('PASS a\nFAIL-ENV covered\n', r, {})[0])
        self.assertFalse(smokes.judge('PASS a\nFAIL-ENV covered\nFAIL-ENV covered\n', r, {})[0])
        self.assertTrue(smokes.judge('PASS a\nFAIL k i\n', r, {'x': [('k i', 1)]})[0])


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
