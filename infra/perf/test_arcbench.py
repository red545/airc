# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""arcbench.py's report (runs anywhere: python3 -m unittest infra/perf/test_arcbench.py)."""
import json, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import arcbench  # noqa: E402


class Report(unittest.TestCase):
    def test_stats(self):
        self.assertIsNone(arcbench.stats([None]))
        s = arcbench.stats([5, 1, 3, None])
        self.assertEqual((s['median'], s['min'], s['max'], s['n']), (3, 1, 5, 3))

    def test_report_and_chart(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for i, (browser, mem, frame) in enumerate([('airc', 1800, 80), ('airc', 1900, 90), ('chrome', 2000, 100)]):
                (root / f'tabs-{i}').mkdir()
                (root / f'tabs-{i}/result.json').write_text(json.dumps({
                    'case': 'tabs', 'browser': browser, 'version': '1', 'pages_loaded': 20,
                    'memory': {'total_mb': mem, 'main_mb': 200, 'renderers': 20, 'load': [1, 1, 1]},
                    'tab_switch': [{'frame_ms': frame, 'frame_done_ms': frame + 1}, {'missed': True}],
                    'new_tab': [{'focus_left_ms': 60}], 'driver_offset_ms': [20, 20],
                    'idle': {'cpu_percent': 0.5, 'load': [1, 1, 1]}, 'hidden': True}))
            (root / 'launch-0').mkdir()
            (root / 'launch-0/result.json').write_text(json.dumps({'case': 'launch', 'browser': 'chrome', 'steps': [
                {'step': 'fresh', 'first_window_ms': 700}, {'step': 'warm', 'first_window_ms': 500},
                {'step': 'link', 'first_window_ms': 500, 'page_fcp_ms': 600}]}))
            r = arcbench.report(root)
            self.assertEqual(r['airc']['memory_total_mb']['stats']['median'], 1850)
            self.assertEqual(r['airc']['tab_switch_frame_ms']['missed'], 2)
            self.assertEqual(r['airc']['tab_switch_frame_from_keydown_ms']['stats']['median'], 65)
            self.assertEqual(r['chrome']['launch_link_fcp_ms']['stats']['median'], 600)
            arcbench.svg(r, root / 'chart.svg')
            self.assertIn('<svg', (root / 'chart.svg').read_text())

    def test_arc_refuses(self):
        with self.assertRaises(SystemExit):
            arcbench.Arc().args(Path('/nonexistent'), None)


if __name__ == '__main__':
    unittest.main()
