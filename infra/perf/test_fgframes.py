# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('fgframes', Path(__file__).with_name('fgframes.py'))
fgframes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fgframes)


def record(engine, action, presented, frames, arm='', **extra):
    key = fgframes.BUDGETS[action][0]
    return {'engine': engine, 'action': action, 'arm': arm, 'load_before': [9.5, 9, 9],
            'frames': {key: {'presented_samples_ms': presented, 'frames': frames, 'work_samples_ms': [1.0] * len(presented),
                             'commit_samples_ms': [2.0] * len(presented)}}, **extra}


class SummaryTest(unittest.TestCase):
    def test_groups_by_engine_action_and_arm(self):
        rows = fgframes.summarize([
            record('webkit', 'switch', [7.8, 15.9], [1, 2]),
            record('webkit', 'switch', [7.8, 7.8], [1, 1]),
            record('webkit', 'switch', [24.0], [3], arm='old'),
            record('chromium', 'newspace', [7.9, 16.0], [1, 2]),
        ])
        by = {(r['engine'], r['action'], r['arm']): r for r in rows}
        new = by[('webkit', 'switch', '')]
        self.assertEqual((new['launches'], new['n'], new['next_vsync'], new['within_budget']), (2, 4, 3, 4))
        self.assertEqual(new['first_per_launch'], [7.8, 7.8])
        self.assertEqual(by[('webkit', 'switch', 'old')]['within_budget'], 0)
        self.assertEqual(by[('chromium', 'newspace', '')]['within_budget'], 1)   # 16.0 > 8.3
        self.assertIn('webkit', fgframes.table(rows))

    def test_errors_and_probe_runs_do_not_count(self):
        rows = fgframes.summarize([record('webkit', 'cbfirst', [7.8], [1], error='outer timeout'),
                                   record('webkit', 'cbfirst', [30.0], [4], probe=True)])
        self.assertEqual(rows, [])


if __name__ == '__main__':
    unittest.main()
