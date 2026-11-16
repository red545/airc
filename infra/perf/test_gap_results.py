# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import unittest
from gap_results import budgets


class Acceptance(unittest.TestCase):
    def data(self, action, row, samples=1):
        return {'requested_runs': 3, 'requested_samples': samples,
                'runs': {action: [dict(row, guard=[{'hid_idle_s': 400}]) for _ in range(3)]}}

    def row(self, data, key):
        return next(r for r in budgets(data) if r['id'] == key)

    def test_empty_and_asleep_are_not_passes(self):
        self.assertTrue(all(r['status'] == 'unknown' for r in budgets({})))
        d = self.data('swipe', {'refresh_hz': None, 'swipe_120hz': {'runs': 1, 'frames': 0, 'missed_vsyncs': 0}})
        self.assertEqual(self.row(d, 'swipe')['status'], 'unknown')

    def test_zero_samples_cannot_pass(self):
        d = self.data('feedback', {'display_frames': True, 'refresh_hz': 120, 'feedback_pressed': 0,
                                  'feedback': {'frames': [], 'presented_samples_ms': []}}, samples=0)
        self.assertEqual(self.row(d, 'feedback')['status'], 'unknown')

    def test_sixty_hz_does_not_certify_120(self):
        d = self.data('swipe', {'refresh_hz': 60, 'swipe_120hz': {'runs': 1, 'frames': 30, 'missed_vsyncs': 30}})
        self.assertEqual(self.row(d, 'swipe')['status'], 'unknown')
        for r in d['runs']['swipe']: r['refresh_hz'] = 120
        self.assertEqual(self.row(d, 'swipe')['status'], 'fail')

    def test_local_failure_decides_composite_without_presentation(self):
        d = self.data('cbkey', {'local_results': [{'tab_found': True, 'history_found': True, 'history_before_commit': False, 'history_ms': 12}]})
        self.assertEqual(self.row(d, 'command')['status'], 'fail')

    def test_partial_timer_scope_never_certifies_global_absence(self):
        d = self.data('idle', {'cpu_percent': .2, 'timers': {'count': 0}})
        self.assertEqual(self.row(d, 'MEM-6')['status'], 'unknown')
        for r in d['runs']['idle']: r['timers']['count'] = 1
        self.assertEqual(self.row(d, 'MEM-6')['status'], 'fail')

    def test_active_sample_is_rejected(self):
        d = self.data('idle', {'cpu_percent': 2})
        d['runs']['idle'][0]['guard'][0]['hid_idle_s'] = 10
        self.assertEqual(self.row(d, 'MEM-6')['status'], 'unknown')

    def test_tail_is_not_hidden_by_median(self):
        d = self.data('sidebar', {'sidebar_hide_samples_ms': [105, 120], 'sidebar_show_samples_ms': [105, 105]}, samples=2)
        self.assertEqual(self.row(d, 'sidebar-toggle')['status'], 'fail')

class TimerCensus(unittest.TestCase):
    def test_modes_deduplicate_timers_and_unknown_format_stays_unknown(self):
        from gaps import census
        timer = '<CFRunLoopTimer 0xabc [allocator]>{interval = 0.5, tolerance = 0}'
        result = census({'runloop': 'timers = (' + timer + timer + ')'})
        self.assertEqual(result['count'], 1)
        self.assertEqual(result['positive_interval_count'], 1)
        self.assertIsNone(census({'runloop': 'unsupported format'})['count'])


if __name__ == '__main__': unittest.main()
