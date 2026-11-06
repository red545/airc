# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Offline regression checks: python3 -m unittest discover -s infra/chromium."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import watch
import status_section


class WatchTests(unittest.TestCase):
    def test_numeric_gap(self):
        self.assertEqual(watch.classify('156.0.1.9', '156.0.1.10'), 'security-respin')
        self.assertEqual(watch.classify('156.0.1.9', '158.0.1.1'), 'new-major')
        self.assertEqual(watch.classify('156.0.1.9', '154.0.1.1'), 'ahead-of-feed')
        with self.assertRaises(ValueError):
            watch.version('156.0.1.9;true')

    def test_brief_lifecycle_and_failure(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'CHROMIUM_VERSION').write_text('156.0.1.9')
            latest = '156.0.1.10'
            def fetch(url):
                if 'fetch_releases' in url:
                    return [{'version': latest}]
                return {'feed': {'entry': [{'content': {'$t': f'{latest} CVE-2026-1234 exploited in the wild'},
                        'title': {'$t': 'Release'}, 'link': [{'rel': 'alternate', 'href': 'https://example.test/release'}]}]}}
            with patch.object(watch, 'HERE', root), patch.object(watch, 'ROOT', root), patch.object(watch, 'fetch', fetch):
                self.assertEqual(watch.main(), 0)
                self.assertIn('urgent', (root / 'pending-update.md').read_text())
                self.assertEqual(json.loads((root / 'state.json').read_text())['security']['urgency'], 'urgent')
                (root / 'CHROMIUM_VERSION').write_text(latest)
                self.assertEqual(watch.main(), 0)
                self.assertFalse((root / 'pending-update.md').exists())
                (root / 'pending-update.md').write_text('stale dispatch')
                with patch.object(watch, 'fetch', side_effect=OSError('offline')):
                    self.assertEqual(watch.main(), 1)
                self.assertFalse((root / 'pending-update.md').exists())
                self.assertFalse(json.loads((root / 'state.json').read_text())['ok'])

    def test_status_escapes_and_marks_stale(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'state.json').write_text(json.dumps({'pinned': '<script>', 'checked': '2000-01-01T00:00:00+00:00'}))
            with patch.object(status_section, '__file__', str(p / 'status_section.py')):
                rendered = status_section.render()
            self.assertIn('STALE', rendered)
            self.assertIn('&lt;script&gt;', rendered)
            self.assertNotIn('<script>', rendered)


if __name__ == '__main__':
    unittest.main()
