# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Exercise the entrypoint hold before any real signing-host access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReleaseHoldTests(unittest.TestCase):
    def run_entrypoint(self, hold, dry):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/sh\necho signing-preflight-reached\nexit 77\n')
            ssh.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       AIRC_RELEASE_CONFIG=str(root / 'absent.env'),
                       AIRC_MAC_HOST='buildmac', AIRC_PUBLISH_HOLD='0', AIRC_PREPARATION='0',
                       AIRC_RELEASE_SCRIPT_LOADED='0')
            env[hold] = '1'
            return subprocess.run(['bash', str(Path(__file__).with_name('release.sh'))]
                                  + (['--dry-run'] if dry else []), env=env,
                                  capture_output=True, text=True)

    def test_holds_refuse_regular_staging_before_signing(self):
        for hold in ('AIRC_PUBLISH_HOLD', 'AIRC_PREPARATION'):
            with self.subTest(hold=hold):
                result = self.run_entrypoint(hold, False)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Public release held', result.stderr)
                self.assertNotIn('signing-preflight-reached', result.stdout)

    def test_dry_staging_reaches_signing_without_clearing_holds(self):
        for hold in ('AIRC_PUBLISH_HOLD', 'AIRC_PREPARATION'):
            with self.subTest(hold=hold):
                result = self.run_entrypoint(hold, True)
                self.assertEqual(result.returncode, 77)
                self.assertIn('signing-preflight-reached', result.stdout)


if __name__ == '__main__':
    unittest.main()
