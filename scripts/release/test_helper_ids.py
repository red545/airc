#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import pathlib
import plistlib
import tempfile
import unittest

import helper_ids


class HelperIdsTest(unittest.TestCase):
    def test_helper_names_follow_the_app(self):
        self.assertEqual(helper_ids.helper_id('com.aircbrowser.Airc', 'org.airc.browser.helper'),
                         'com.aircbrowser.Airc.helper')
        self.assertEqual(helper_ids.helper_id('com.aircbrowser.Airc', 'org.airc.browser.helper.renderer'),
                         'com.aircbrowser.Airc.helper.renderer')
        # A test copy's helper, re-stamped after the published identity comes back (prepare-mac.sh).
        self.assertEqual(helper_ids.helper_id('com.aircbrowser.Airc', 'org.airc.Airc.test.helper'),
                         'com.aircbrowser.Airc.helper')

    def test_alerts_and_lookalikes_keep_their_ids(self):
        self.assertIsNone(helper_ids.helper_id('com.aircbrowser.Airc',
                                               'org.airc.browser.framework.AlertNotificationService'))
        self.assertIsNone(helper_ids.helper_id('com.aircbrowser.Airc', 'org.airc.browser.helpers'))

    def test_rewrites_bundle_plists_idempotently(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = pathlib.Path(tmp) / 'Airc.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.aircbrowser.Airc'}))
            helpers = app / 'Contents/Frameworks/Airc Framework.framework/Versions/1.0/Helpers'
            ids = {'Airc Helper.app': 'org.airc.browser.helper',
                   'Airc Helper (Renderer).app': 'org.airc.browser.helper.renderer',
                   'Airc Helper (Alerts).app': 'org.airc.browser.framework.AlertNotificationService'}
            for name, bundle_id in ids.items():
                (helpers / name / 'Contents').mkdir(parents=True)
                (helpers / name / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id}))
            (app / 'Contents/Frameworks/Airc Framework.framework/Versions/Current').symlink_to('1.0')
            self.assertEqual(len(helper_ids.follow_app(app)), 2)
            self.assertEqual(helper_ids.follow_app(app), [])

            def read(name):
                return plistlib.loads((helpers / name / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
            self.assertEqual(read('Airc Helper.app'), 'com.aircbrowser.Airc.helper')
            self.assertEqual(read('Airc Helper (Renderer).app'), 'com.aircbrowser.Airc.helper.renderer')
            self.assertEqual(read('Airc Helper (Alerts).app'), 'org.airc.browser.framework.AlertNotificationService')


if __name__ == '__main__':
    unittest.main()
