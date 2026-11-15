# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('preflight', Path(__file__).resolve().parents[1] / 'scripts/ui-session-preflight.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def test_foreign_console_refused_before_mutation(self):
        with patch.object(preflight.os, 'getuid', return_value=501), \
             patch.object(preflight.os, 'stat', return_value=SimpleNamespace(st_uid=502)), \
             patch.object(preflight.subprocess, 'run') as run, patch.object(preflight.os, 'kill') as kill:
            with self.assertRaises(RuntimeError):
                preflight.prepare()
            run.assert_not_called()
            kill.assert_not_called()

    def test_only_exact_agent_notification_process_dismissed(self):
        with patch.object(preflight.os, 'getuid', return_value=501), \
             patch.object(preflight.os, 'stat', return_value=SimpleNamespace(st_uid=501)), \
             patch.object(preflight.subprocess, 'run'), \
             patch.object(preflight.subprocess, 'check_output', side_effect=[
                 '11 502 /System/UserNotificationCenter\n12 501 /System/UserNotificationCenter\n13 501 /System/Finder',
                 '501 /System/UserNotificationCenter']), patch.object(preflight.os, 'kill') as kill:
            preflight.prepare()
            kill.assert_called_once_with(12, preflight.signal.SIGTERM)

    def test_reused_pid_not_killed(self):
        with patch.object(preflight.os, 'getuid', return_value=501), \
             patch.object(preflight.os, 'stat', return_value=SimpleNamespace(st_uid=501)), \
             patch.object(preflight.subprocess, 'run'), \
             patch.object(preflight.subprocess, 'check_output', side_effect=[
                 '12 501 /System/UserNotificationCenter', '502 /System/UserNotificationCenter']), \
             patch.object(preflight.os, 'kill') as kill:
            preflight.prepare()
            kill.assert_not_called()

    def test_preflight_cannot_run_without_the_ui_lock(self):
        import fcntl
        import os
        import shutil
        import subprocess
        import sys
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'arcfork').mkdir()
            wrapper = root / 'ui-check-lock.py'
            shutil.copyfile(Path(__file__).resolve().parents[1] / 'scripts/ui-check-lock.py', wrapper)
            (root / 'ui-session-preflight.py').write_text(
                "from pathlib import Path\ndef prepare():\n Path(__file__).with_name('prepared').touch()\n")
            env = os.environ | {'HOME': str(root), 'AIRC_UI_DEDICATED_SESSION': '1',
                                'AIRC_UI_LOCK_STRICT': '1', 'AIRC_UI_LOCK_TIMEOUT': '0.1'}
            env.pop('AIRC_UI_COORDINATOR', None)
            env.pop('AIRC_UI_LOCK_BUDGET_FILE', None)
            with (root / 'arcfork/.ui-check.lock').open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                result = subprocess.run([sys.executable, str(wrapper), '/usr/bin/true'], env=env, capture_output=True)
                self.assertEqual(result.returncode, 75)
                self.assertFalse((root / 'prepared').exists())
            result = subprocess.run([sys.executable, str(wrapper), '/usr/bin/true'], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'prepared').exists())
