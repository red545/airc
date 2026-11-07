# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from diagnostic_hygiene import archive
from owner_versions import owner_versions
from xctest_summary import summarize
import work_page


class InfraTests(unittest.TestCase):
    def test_hygiene(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, dest, work = root/'reports', root/'archive', root/'work'
            source.mkdir()
            def report(name, bundle, app='Airc', path='', body_id=''):
                (source/name).write_text(json.dumps(dict(bundleID=bundle, app_name=app)) + '\n' +
                    json.dumps(dict(procPath=path, bundleInfo=dict(CFBundleIdentifier=body_id))))
            report('test.ips', 'org.airc.Airc.test')
            report('webkit.ips', 'org.airc.Airc.test.webkit')
            report('scratch.ips', 'org.airc.crashvis')
            report('renamed.ips', '', 'AircProbe', str(work/'probe/AircProbe.app/Contents/MacOS/AircProbe'))
            report('owner.ips', 'org.airc.Airc.dev', 'AircProbe', str(work/'p/A.app/Contents/MacOS/AircProbe'))
            report('public.ips', 'com.aircbrowser.Airc')
            report('conflict.ips', 'org.airc.Airc.test', body_id='org.airc.Airc.dev')
            report('unknown.ips', 'org.airc.Airc.testing')
            report('redacted.ips', '', 'AircProbe', '/Users/USER/*/AircProbe.app/Contents/MacOS/AircProbe')
            (source/'broken.ips').write_text('invalid')
            dest.mkdir()
            (dest/'test.ips').write_text('existing')
            self.assertEqual(archive(source, dest, work), dict(moved=4, kept=5, unreadable=1))
            self.assertTrue((source/'owner.ips').exists())
            self.assertEqual((dest/'test.ips').read_text(), 'existing')
            self.assertEqual(len(list(dest.glob('*.ips'))), 5)

    def test_summary(self):
        failure = "Test Case '-[AircKitTests.StoreTests testRestore]' failed (0.001 seconds)."
        lines = ['noise'] * 100 + [failure] + ['Executed 10 tests'] * 20
        self.assertEqual(list(summarize(lines)), [failure] + ['Executed 10 tests'] * 3)

    def test_cache_success_and_offline(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch('owner_versions.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '{"installed":"123","latest":"456"}')) as ssh:
                self.assertEqual(owner_versions(Path(temp))['installed'], '123')
                self.assertEqual(owner_versions(Path(temp))['latest'], '456')
                self.assertEqual(ssh.call_count, 1)
        with tempfile.TemporaryDirectory() as temp:
            with patch('owner_versions.subprocess.run', side_effect=subprocess.TimeoutExpired('ssh', 20)) as ssh:
                owner_versions(Path(temp))
                owner_versions(Path(temp))
                self.assertEqual(ssh.call_count, 1)

    def test_page(self):
        with tempfile.TemporaryDirectory() as temp:
            status = Path(temp)
            run = status/'runs/2026-11-07_0123'
            run.mkdir(parents=True)
            (run/'steps.tsv').write_text('test-AircKit\t1\t3\nbuild-app\t1\t3\n')
            failure = "Test Case '-[AircKitTests.StoreTests testRestore]' failed (0.001 seconds)."
            (run/'test-AircKit.log').write_text(failure)
            with patch('sys.argv', ['work_page.py', '--status', str(status), '--state', str(status/'missing')]), \
                 patch.object(work_page, 'owner_versions', return_value=dict(installed='123', latest='456')), \
                 patch.object(work_page, 'building_now', return_value=False):
                work_page.main()
            page = (status/'work.html').read_text()
            self.assertIn('Your Airc: build 123 (installed)', page)
            self.assertIn("latest on your Mac's feed: 456", page)
            self.assertIn('testRestore', page)


if __name__ == '__main__':
    unittest.main()
