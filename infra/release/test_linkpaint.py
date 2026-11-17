# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('linkpaint', Path(__file__).resolve().parent / 'linkpaint.py')
linkpaint = importlib.util.module_from_spec(spec); spec.loader.exec_module(linkpaint)


def rows(*paints, first=None):
    out = [{'kind': 'settle'}] + [{'kind': 'closed', 'paint_s': p} for p in paints]
    if first is not None: out.append({'kind': 'first', 'paint_s': first})
    return out


class LinkPaintVerdictTests(unittest.TestCase):
    def test_passes_within_budget_and_ignores_the_first_launch_ever(self):
        v = linkpaint.verdict(rows(0.71, 0.8, 0.95, 0.77, 1.3, first=4.6), 1.0)
        self.assertTrue(v['pass'], v)
        self.assertEqual(v['median_s'], 0.8)

    def test_fails_on_median_worst_or_missing_paint(self):
        self.assertFalse(linkpaint.verdict(rows(1.1, 1.2, 0.9), 1.0)['pass'])          # median over
        self.assertFalse(linkpaint.verdict(rows(0.7, 0.8, 2.3), 1.0)['pass'])          # one run over 2x
        self.assertFalse(linkpaint.verdict(rows(0.7, None, 0.8), 1.0)['pass'])         # no paint
        self.assertFalse(linkpaint.verdict(rows(), 1.0)['pass'])                       # nothing measured
        self.assertFalse(linkpaint.verdict(rows(5.3, 5.1, 5.7, 5.2, 5.4), 1.0)['pass'])  # 0.1.18's arcbench numbers


if __name__ == '__main__':
    unittest.main()
