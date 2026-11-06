# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import unittest
from entitlement_policy import LIBRARY_VALIDATION as KEY, library_validation_error

class PolicyTest(unittest.TestCase):
    def test_only_exact_cdm_helpers_accept_the_exception(self):
        prefix = 'Contents/Frameworks/Airc Framework.framework/Versions/156.0.8078.88/Helpers/'
        for helper in ('Airc Helper', 'Airc Helper (Aperitif)'):
            path = prefix+helper+'.app/Contents/MacOS/'+helper
            self.assertIsNone(library_validation_error(path, {KEY: True}))
            self.assertIsNotNone(library_validation_error(path, {}))
        for path in ('Contents/MacOS/Airc', prefix+'Airc Helper (Renderer).app/Contents/MacOS/Airc Helper (Renderer)',
                     prefix+'Airc Helper (GPU).app/Contents/MacOS/Airc Helper (GPU)',
                     prefix+'Airc Helper (Aperitif Renderer).app/Contents/MacOS/Airc Helper (Aperitif Renderer)',
                     'Contents/Frameworks/Other.framework/Airc Helper.app/Contents/MacOS/Airc Helper',
                     prefix+'Airc Helper.app/Contents/MacOS/another-binary',
                     prefix+'Airc Helper.app/Contents/Frameworks/plugin.dylib'):
            with self.subTest(path=path):
                self.assertIsNotNone(library_validation_error(path, {KEY: True}))
                self.assertIsNone(library_validation_error(path, {}))

if __name__ == '__main__': unittest.main()
