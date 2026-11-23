# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('perf_aggregate', Path(__file__).with_name('aggregate.py'))
agg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agg)


def result(stamp, airc_mb, chrome_mb, launch, cpu=0.2, pages=8, **extra):
    side = lambda mb, more=None: {'metrics': {'total_mb': mb, 'main_mb': mb / 6, 'idle_cpu_percent': cpu, **(more or {})},
                                  'pages_loaded': pages, 'errors': []}
    return {'schema_version': 1, 'timestamp': stamp, 'engine': 'chromium', 'notes': ['single', 'other'],
            'airc': {**side(airc_mb, {'interactive_ms': launch, 'leak_ratio': 1.0}), 'reference_verified': True},
            'chrome_8': side(chrome_mb), **extra}


class AggregateTests(unittest.TestCase):
    def write(self, d, name, data):
        path = Path(d) / f'{name}.json'
        path.write_text(json.dumps(data))
        return str(path)

    def test_medians_spread_and_budgets(self):
        with tempfile.TemporaryDirectory() as d:
            runs = [self.write(d, f'r{i}', result(f't{i}', mb, 600, launch)) for i, (mb, launch) in
                    enumerate([(500, 900), (540, 1200), (520, 800)])]
            data = agg.aggregate(runs)
            self.assertEqual(data['airc']['metrics']['total_mb'], 520)
            self.assertEqual(data['airc']['spread']['total_mb'], {'min': 500, 'max': 540, 'n': 3})
            self.assertAlmostEqual(data['ratios']['total_mb'], 520 / 600)
            launch = next(b for b in data['budgets'] if b['id'] == 'launch')
            self.assertEqual((launch['status'], launch['value']), ('pass', 900))
            self.assertTrue(data['complete'])
            # Foreground timings decide the timing budgets.
            front = self.write(d, 'f', result('f', 1, 1, 1100))
            launch = next(b for b in agg.aggregate(runs, [front])['budgets'] if b['id'] == 'launch')
            self.assertEqual(launch['status'], 'fail')
            self.assertIn('background 900', launch['reason'])

    def test_missing_page_or_value_is_not_filled(self):
        with tempfile.TemporaryDirectory() as d:
            a = result('a', 500, 600, 900)
            b = result('b', 500, 600, 900, pages=7)
            del b['airc']['metrics']['total_mb']
            data = agg.aggregate([self.write(d, 'a', a), self.write(d, 'b', b)])
            self.assertEqual(data['airc']['spread']['total_mb']['n'], 1)
            self.assertEqual(data['airc']['pages_loaded'], 7)
            self.assertFalse(data['mem4']['8']['verified'])
            self.assertFalse(data['complete'])

    def test_on_screen_launch_is_left_out(self):
        with tempfile.TemporaryDirectory() as d:
            runs = [result(f't{i}', 500, mb, 900) for i, mb in enumerate([600, 700, 800])]
            runs[0]['chrome_8']['hidden_for_sample'] = False
            data = agg.aggregate([self.write(d, f'r{i}', r) for i, r in enumerate(runs)])
            self.assertEqual(data['chrome_8']['metrics']['total_mb'], 750)
            self.assertEqual(data['excluded_on_screen']['chrome_8'], 1)
            self.assertFalse(data['runs'][0]['chrome_8']['hidden_for_sample'])

    def test_status_renders_aggregate(self):
        sys.path.insert(0, str(Path(__file__).parents[1]))
        from perf import status_section
        with tempfile.TemporaryDirectory() as d:
            runs = [self.write(d, f'r{i}', result(f't{i}', 500 + i, 600, 900)) for i in range(3)]
            data = agg.aggregate(runs, ab=[f'mcp_off={runs[0]}'])
            out = Path(d) / 'status/perf/x'; out.mkdir(parents=True); (Path(d) / 'status/runs').mkdir()
            (out / 'results.json').write_text(json.dumps(data))
            page = status_section.render(Path(d) / 'status/runs')
            self.assertIn('Complete', page)
            self.assertIn('(500.00–502.00)', page)
            self.assertIn('mcp_off', page)
            self.assertIn('perf/x/results.json', page)

    def test_baseline_before_after(self):
        sys.path.insert(0, str(Path(__file__).parents[1]))
        from perf import status_section
        with tempfile.TemporaryDirectory() as d:
            old = agg.aggregate([self.write(d, f'o{i}', result(f'o{i}', 600, 600, 5000)) for i in range(3)])
            base = self.write(d, 'base', old)
            runs = [self.write(d, f'r{i}', result(f't{i}', 480, 600, 900)) for i in range(3)]
            data = agg.aggregate(runs, baseline=f'13 Nov={base}')
            self.assertEqual(data['baseline']['metrics']['airc']['total_mb'], 600)
            self.assertEqual(data['baseline']['budgets']['launch']['status'], 'fail')
            self.assertEqual(data['airc']['metrics']['total_mb'], 480)   # today's medians untouched
            out = Path(d) / 'status/perf/x'; out.mkdir(parents=True); (Path(d) / 'status/runs').mkdir()
            (out / 'results.json').write_text(json.dumps(data))
            page = status_section.render(Path(d) / 'status/runs')
            self.assertIn('13 Nov → today', page)
            self.assertIn('600.00 → 480.00', page)
            self.assertIn('1.00 → 0.80', page)       # Airc/Chrome ratio before → after
            self.assertIn('fail (5000.00) → pass (900.00)', page)
            other = dict(old, engine='webkit')
            with self.assertRaises(SystemExit):
                agg.aggregate(runs, baseline=f'x={self.write(d, "wk", other)}')


if __name__ == '__main__':
    unittest.main()
