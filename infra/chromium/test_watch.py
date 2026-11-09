# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Offline regression checks: python3 -m unittest discover -s infra/chromium."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import watch
import status_section


class WatchTests(unittest.TestCase):
    def test_review_is_bound_to_post_content_and_pin(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            pin = '156.0.1.9'
            content = f'{pin} security fixes CVE-2026-1234'
            url = 'https://example.test/release'
            entry = {'content': {'$t': content}, 'title': {'$t': 'Release'},
                     'link': [{'rel': 'alternate', 'href': url}]}
            feed = {'feed': {'entry': [entry]}}
            review = {'url': url, 'pinned': pin,
                      'content_sha256': hashlib.sha256(content.encode()).hexdigest()}
            review_file = root / 'reviewed-posts.json'
            with patch.object(watch, 'HERE', root), patch.object(watch, 'fetch', return_value=feed):
                self.assertEqual(watch.security([pin], pin)['urgency'], 'review-required')
                review_file.write_text(json.dumps([review]))
                result = watch.security([pin], pin)
                self.assertEqual(result['urgency'], 'reviewed')
                self.assertEqual(result['entries'][0]['cves'], ['CVE-2026-1234'])
                self.assertEqual(watch.security([pin, '156.0.1.10'], pin)['urgency'], 'review-required')
                self.assertEqual(watch.security([pin], '156.0.1.8')['urgency'], 'review-required')
                entry['content']['$t'] += ' new information'
                self.assertEqual(watch.security([pin], pin)['urgency'], 'review-required')
                entry['content']['$t'] = content
                entry['link'][0]['href'] += '-new'
                self.assertEqual(watch.security([pin], pin)['urgency'], 'review-required')
                entry['link'][0]['href'] = url
                feed['feed']['entry'].append({**entry, 'link': [{'rel': 'alternate', 'href': url + '-other'}]})
                self.assertEqual(watch.security([pin], pin)['urgency'], 'review-required')
                feed['feed']['entry'] = []
                self.assertEqual(watch.security([pin], pin)['urgency'], 'review-required')

    def test_review_never_suppresses_exploit_or_fetch_error(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            pin = '156.0.1.9'
            content = f'{pin} Google is aware that an exploit for CVE-2026-1234 exists in the wild.'
            url = 'https://example.test/release'
            feed = {'feed': {'entry': [{'content': {'$t': content}, 'title': {'$t': 'Release'},
                                      'link': [{'rel': 'alternate', 'href': url}]}]}}
            review_file = root / 'reviewed-posts.json'
            review_file.write_text(json.dumps([{'url': url, 'pinned': pin,
                'content_sha256': hashlib.sha256(content.encode()).hexdigest()}]))
            with patch.object(watch, 'HERE', root), patch.object(watch, 'fetch', return_value=feed):
                result = watch.security([pin], pin)
                self.assertTrue(result['entries'][0]['reviewed'])
                self.assertEqual(result['urgency'], 'urgent')
                with patch.object(watch, 'fetch', side_effect=[feed, OSError('offline')]):
                    self.assertTrue(watch.security([pin, '156.0.1.10'], pin)['errors'])
                feed['feed']['entry'][0]['content']['$t'] = pin
                review_file.write_text(json.dumps([{'url': url, 'pinned': pin,
                    'content_sha256': hashlib.sha256(pin.encode()).hexdigest()}]))
                with patch.object(watch, 'fetch', side_effect=[feed, OSError('offline')]):
                    self.assertEqual(watch.security([pin, '156.0.1.10'], pin)['urgency'], 'review-required')
                for invalid in ('{', '{}', '[null]'):
                    review_file.write_text(invalid)
                    result = watch.security([pin], pin)
                    self.assertTrue(result['errors'])
                    self.assertEqual(result['urgency'], 'review-required')

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
