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

    def test_release_exception_is_exact_and_fails_open(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            pin, target = '156.0.1.9', '156.0.1.10'
            entry = {'url': 'https://example.test/release', 'content_sha256': 'content'}
            review = {'pinned': pin, 'version': target, 'upstream_revision': 'commit',
                      'engine_tree': 'tree', 'decision': 'not-applicable',
                      'reason': 'Feature disabled', 'note': 'docs/review.md', 'evidence': [entry]}
            (root / 'reviewed-releases.json').write_text(json.dumps([review]))
            original = {'pinned': pin, 'extended': target,
                        'extended_releases': [{'version': target, 'hashes': {'chromium': 'commit'}}],
                        'security': {'entries': [entry], 'errors': [], 'urgency': 'review-required'}}
            import copy
            with patch.object(watch, 'HERE', root), patch.object(watch, 'reviewed_engine_tree', return_value='tree'):
                self.assertEqual(watch.release_review(copy.deepcopy(original), [target]), review)
                mutations = [
                    lambda s: s.update(pinned='156.0.1.8'),
                    lambda s: s.update(extended='156.0.1.11'),
                    lambda s: s['extended_releases'][0]['hashes'].update(chromium='moved-tag'),
                    lambda s: s['extended_releases'][0].pop('hashes'),
                    lambda s: s['security']['entries'][0].update(content_sha256='new-CVEs'),
                    lambda s: s['security']['entries'][0].update(url='https://example.test/other'),
                    lambda s: s['security']['entries'].append({'url': 'extra', 'content_sha256': 'new'}),
                    lambda s: s['security']['entries'].clear(),
                    lambda s: s['security']['errors'].append('offline'),
                    lambda s: s['security'].update(urgency='urgent'),
                ]
                for mutate in mutations:
                    state = copy.deepcopy(original)
                    mutate(state)
                    self.assertIsNone(watch.release_review(state, [target]))
                self.assertIsNone(watch.release_review(original, [target, '156.0.1.11']))
                with patch.object(watch, 'reviewed_engine_tree', return_value='changed-engine'):
                    self.assertIsNone(watch.release_review(original, [target]))
                with patch.object(watch, 'reviewed_engine_tree', side_effect=OSError('dirty engine')):
                    state = copy.deepcopy(original)
                    self.assertIsNone(watch.release_review(state, [target]))
                    self.assertTrue(state['security']['errors'])
                for malformed in ('{', '{}', '[null]'):
                    (root / 'reviewed-releases.json').write_text(malformed)
                    state = copy.deepcopy(original)
                    self.assertIsNone(watch.release_review(state, [target]))
                    self.assertTrue(state['security']['errors'])

    def test_reviewed_release_removes_brief_but_next_tag_reopens_it(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            pin, latest = '156.0.1.9', '156.0.1.10'
            (root / 'CHROMIUM_VERSION').write_text(pin)
            url = 'https://example.test/release'
            def fetch(url_requested):
                if 'fetch_releases' in url_requested:
                    return [{'version': latest, 'hashes': {'chromium': 'commit'}}]
                return {'feed': {'entry': [{'content': {'$t': latest}, 'title': {'$t': 'Release'},
                                            'link': [{'rel': 'alternate', 'href': url}]}]}}
            review = {'pinned': pin, 'version': latest, 'upstream_revision': 'commit',
                      'engine_tree': 'tree', 'decision': 'not-applicable',
                      'reason': 'Feature disabled', 'note': 'docs/review.md',
                      'evidence': [{'url': url, 'content_sha256': hashlib.sha256(latest.encode()).hexdigest()}]}
            with patch.object(watch, 'HERE', root), patch.object(watch, 'ROOT', root), \
                    patch.object(watch, 'fetch', fetch), patch.object(watch, 'reviewed_engine_tree', return_value='tree'):
                self.assertEqual(watch.main(), 0)
                self.assertTrue((root / 'pending-update.md').exists())
                (root / 'reviewed-releases.json').write_text(json.dumps([review]))
                self.assertEqual(watch.main(), 0)
                state = json.loads((root / 'state.json').read_text())
                self.assertEqual(state['gap'], 'reviewed-not-applicable')
                self.assertEqual(state['version_gap'], 'security-respin')
                self.assertEqual(state['pinned'], pin)
                self.assertFalse(state['update_required'])
                self.assertFalse((root / 'pending-update.md').exists())
                latest = '156.0.1.11'
                self.assertEqual(watch.main(), 0)
                self.assertIn(latest, (root / 'pending-update.md').read_text())
                self.assertTrue(json.loads((root / 'state.json').read_text())['update_required'])

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
