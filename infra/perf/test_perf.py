# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('perf_run', Path(__file__).with_name('run.py'))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

class SafetyTests(unittest.TestCase):
    def test_owned_helpers_exclude_other_browsers_and_reused_pids(self):
        def row(parent, cmd, birth='now'):
            return dict(parent=parent, command=cmd, birth=birth, cpu=0)
        before = {10:row(1,'Chrome owner','old'),11:row(1,'WebKit owner','old')}
        after = {**before,20:row(1,'/test/Airc --data-dir /isolated'),
                 21:row(1,'WebKit'),22:row(20,'Chromium helper'),23:row(1,'WebKit unrelated')}
        with patch.object(run,'processes',return_value=before):
            instance = run.Instance('/test/Airc','/isolated')
        with patch.object(run,'processes',return_value=after), patch.object(run,'responsible',lambda p:20 if p==21 else p,create=True):
            self.assertEqual(set(instance.discover()),{20,21,22})
        # Cleanup must not signal a replacement process using a previously owned PID.
        after[21] = row(1,'unrelated','later')
        with patch.object(run,'processes',return_value=after), patch.object(run,'responsible',lambda p:p,create=True):
            self.assertNotIn(21,instance.discover())
    def test_missing_observations_cannot_pass(self):
        self.assertTrue(all(b['status']=='unknown' for b in run.budgets({'airc':{'metrics':{'main_mb':1}}})))
    def test_footprint_units(self):
        with patch.object(run,'command',return_value='Physical footprint:  128.0M\n'):
            self.assertAlmostEqual(run.footprint(42),134.217728)
    def test_event_timeout(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(RuntimeError): run.event(Path(d)/'missing','workload_ready',.01)

class DiagnoseTests(unittest.TestCase):
    def test_diagnosis_files_and_stacks_only_with_malloc_logging(self):
        calls = []
        def fake(argv, **kw):
            calls.append(argv)
            class R: returncode = 0; stdout = f'{argv[0]} output'; stderr = ''
            return R()
        with tempfile.TemporaryDirectory() as d, patch.object(run.subprocess,'run',fake):
            found = run.diagnose_main(42, Path(d))
            self.assertEqual(set(found), {'vmmap','footprint','heap'})
            self.assertEqual((Path(d)/'diag-heap.txt').read_text(), 'heap output')
            self.assertTrue(all(c[-1] == '42' for c in calls))
            with patch.object(run,'DIAGNOSE_STACKS',True):
                found = run.diagnose_main(42, Path(d), '-x')
            self.assertEqual(found['malloc_history'], 'diag-x-malloc_history.txt')
            self.assertEqual(calls[-1], ['malloc_history','42','-allBySize'])
    def test_footprint_trace_peak(self):
        with patch.object(run,'process_start',return_value=100.0):
            trace = run.FootprintTrace(7)
        trace.samples = [(200, 80.0), (900, 455.3), (5000, 120.0)]
        with tempfile.TemporaryDirectory() as d:
            info = trace.save(Path(d)/'diag-trace.json')
            self.assertEqual((info['peak_mb'], info['peak_ms'], info['count']), (455.3, 900, 3))
            self.assertIn('"start_epoch": 100.0', (Path(d)/'diag-trace.json').read_text())
    def test_failing_tool_is_recorded_not_raised(self):
        def boom(argv, **kw): raise FileNotFoundError(argv[0])
        with tempfile.TemporaryDirectory() as d, patch.object(run.subprocess,'run',boom):
            self.assertTrue(all(v.startswith('error:') for v in run.diagnose_main(1, Path(d)).values()))

class Mem4Tests(unittest.TestCase):
    def test_page_load_check(self):
        self.assertTrue(run.loaded({'url':'https://en.wikipedia.org/wiki/X','title':'X - Wikipedia'}))
        for page in [{'url':'https://www.bbc.com/news','title':'bbc.com'},{'url':'chrome-error://chromewebdata/','title':'x'},
                     {'url':'https://news.ycombinator.com/','title':''},{'url':'https://a.org/','title':'https://a.org/'}]:
            self.assertFalse(run.loaded(page))
    def test_like_for_like_ratio_and_budget(self):
        def side(mb, pages, cpu=0.5): return {'metrics':{'total_mb':mb,'idle_cpu_percent':cpu},'pages_loaded':pages}
        data = {'airc':{**side(800,8),'reference_verified':True},'chrome_8':side(1000,8,1.0),'airc_30':side(3000,30),'chrome':side(3600,29)}
        data['mem4'] = run.mem4(data)
        self.assertAlmostEqual(data['mem4']['8']['ratio'], 0.8)
        self.assertTrue(data['mem4']['8']['verified'])
        self.assertFalse(data['mem4']['30']['verified'])
        mem4 = next(b for b in run.budgets(data) if b['id']=='MEM-4')
        self.assertEqual(mem4['status'],'pass')
        data['chrome_8']['pages_loaded'] = 7
        data['mem4'] = run.mem4(data)
        self.assertEqual(next(b for b in run.budgets(data) if b['id']=='MEM-4')['status'],'unknown')
    def test_idle_cpu_over_budget_fails(self):
        data = {'airc':{'metrics':{'idle_cpu_percent':2.0},'reference_verified':True}}
        self.assertEqual(next(b for b in run.budgets(data) if b['id']=='MEM-6')['status'],'fail')
        data['airc']['metrics']['idle_cpu_percent'] = 0.4
        self.assertEqual(next(b for b in run.budgets(data) if b['id']=='MEM-6')['status'],'unknown')

    def test_idle_cpu_with_animating_shown_page_is_reported_not_judged(self):
        pages = [{'shown': True, 'animations': 1, 'url': 'https://example.com/'}, {'shown': False, 'animations': 2}]
        data = {'airc':{'metrics':{'idle_cpu_percent':20.0},'reference_verified':True,'pages':pages}}
        row = next(b for b in run.budgets(data) if b['id']=='MEM-6')
        self.assertEqual(row['status'],'unknown')
        self.assertIn('idlecpu', row['reason'])
        pages[0]['animations'] = 0   # a still shown page over budget still fails
        self.assertEqual(next(b for b in run.budgets(data) if b['id']=='MEM-6')['status'],'fail')
    def test_process_kinds(self):
        self.assertEqual(run.kind('/x/Airc Helper (Renderer) --type=renderer --foo'),'renderer')
        self.assertEqual(run.kind('/x/Airc Helper --type=utility --utility-sub-type=network.mojom.NetworkService'),'utility:NetworkService')
        self.assertEqual(run.kind('/x/Airc',True),'main')

class StatusTests(unittest.TestCase):
    def test_incomplete_and_malformed_runs(self):
        import json
        from status_section import render
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            (root/'a').mkdir(); (root/'b').mkdir()
            (root/'a/results.json').write_text(json.dumps({'schema_version':1,'complete':False,'notes':['<unsafe>'],
                'airc':{'metrics':{'total_mb':100}},'budgets':[]}))
            (root/'b/results.json').write_text('{')
            output=render(root)
            self.assertIn('Incomplete / diagnostic only',output)
            self.assertIn('&lt;unsafe&gt;',output)
            self.assertNotIn('<unsafe>',output)
            self.assertIn('<svg',output)

if __name__=='__main__': unittest.main()
