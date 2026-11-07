# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-feed.py'))
i = importlib.util.module_from_spec(spec)
spec.loader.exec_module(i)


class InstallFeed(unittest.TestCase):
    def test_path_change_keeps_valid_configured_interpreter(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            executable = p/'python'
            executable.touch()
            executable.chmod(0o755)
            tail = ['server.py', 'feed', '3483']
            agent = p/'agent.plist'
            agent.write_bytes(plistlib.dumps(dict(ProgramArguments=[str(executable), *tail])))
            self.assertEqual(i.interpreter(agent, tail), str(executable))
            executable.unlink()
            self.assertEqual(i.interpreter(agent, tail), i.sys.executable)

    @patch.object(i.time, 'sleep')
    @patch.object(i.subprocess, 'run')
    def test_bootstrap_retries_and_reports_exhaustion(self, run, sleep):
        fail = subprocess.CompletedProcess([], 5, '', 'Input/output error')
        ok = subprocess.CompletedProcess([], 0, '', '')
        run.side_effect = [fail, ok]
        i.bootstrap('gui/test', Path('agent'), attempts=2)
        self.assertEqual(run.call_count, 2)
        run.side_effect = [fail, fail]
        with self.assertRaisesRegex(RuntimeError, 'bootstrap failed.*exit 5.*Input/output error'):
            i.bootstrap('gui/test', Path('agent'), attempts=2)

    def test_coordinator_surfaces_redirected_remote_failure(self):
        root = Path(__file__).resolve().parents[2]
        rev = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            for name, body in {
                'scp': 'exit 0',
                'ssh': f'case "$*" in *plutil*) echo {rev};; *) echo "local-feed: failed: injected bootstrap failure" >&2; exit 5;; esac',
            }.items():
                tool = p/name
                tool.write_text('#!/bin/bash\n'+body+'\n')
                tool.chmod(0o755)
            env = {**os.environ, 'PATH': str(p)+os.pathsep+os.environ['PATH'],
                   'AIRC_UPDATES_CONFIG': '/dev/null', 'AIRC_UPDATES_DIR': str(p/'feed'),
                   'AIRC_ARTIFACTS_DIR': str(p/'evidence')}
            note = p/'notes.txt'
            note.write_text('Operator explanation: checks remain gated.')
            result = subprocess.run(['bash', str(root/'infra/updates/publish.sh'), 'arcfork/work/proof', str(note)],
                                    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            import json
            metadata = next((p/'evidence/release/dev-channel').glob('publish.*/source.json'))
            self.assertTrue(json.loads(metadata.read_text())['notes'].startswith(note.read_text()))
            self.assertEqual(result.returncode, 5)
            self.assertIn('failed during Mac local publication', result.stdout)
            self.assertIn('local-feed: failed: injected bootstrap failure', result.stdout)
            result = subprocess.run(['bash', str(root/'infra/updates/publish.sh'), '../invalid'],
                                    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 2)
            self.assertIn('failed during validating remote checkout path', result.stdout)


if __name__ == '__main__':
    unittest.main()
