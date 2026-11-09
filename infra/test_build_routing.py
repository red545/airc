# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Publication holds and real lock refusal must be side-effect free."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from infra.dry_ship_result import REQUIRED, failures

ROOT = Path(__file__).resolve().parents[1]


def green_ui(path):
    path.with_name('ui-gate.json').write_text(json.dumps(dict(state='PASS', launches=[
        dict(script='fixture', state='PASS', failures=[], errors=[], locks=[])])))


class RoutingTests(unittest.TestCase):
    def test_publication_holds_before_creating_directories(self):
        for flag in ('AIRC_PREPARATION', 'AIRC_PUBLISH_HOLD', 'AIRC_SCRATCH_PUBLISH_ROOT'):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as tmp:
                env = dict(os.environ, AIRC_UPDATES_CONFIG='/dev/null',
                           AIRC_UPDATES_DIR=tmp+'/feed', AIRC_ARTIFACTS_DIR=tmp+'/evidence')
                env[flag] = '1'
                result = subprocess.run(['bash', str(ROOT/'infra/updates/publish.sh')],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(Path(tmp, 'feed').exists())
                self.assertFalse(Path(tmp, 'evidence').exists())

    def test_public_release_hold_precedes_signing_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, AIRC_RELEASE_CONFIG='/dev/null', AIRC_PUBLISH_HOLD='1',
                       AIRC_ARTIFACTS_DIR=tmp+'/evidence')
            result = subprocess.run(['bash', str(ROOT/'scripts/release/release.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('Public release held', result.stderr)
            self.assertFalse(Path(tmp, 'evidence').exists())

    def test_preparation_rejects_active_remote_before_side_effects(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, AIRC_UPDATES_CONFIG='/dev/null', AIRC_PREPARATION='1',
                       AIRC_DEV_CHANNEL='0', AIRC_STATUS_DIR=tmp+'/status',
                       AIRC_NIGHTLY_REMOTE='arcfork/nightly')
            result = subprocess.run(['bash', str(ROOT/'infra/nightly.sh'), '--ship'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertFalse(Path(tmp, 'status').exists())

    def test_incomplete_or_red_ledger_never_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'steps.tsv'
            green_ui(path)
            lines = [name + '\t0\t1' for name in sorted(REQUIRED)]
            path.write_text('\n'.join(lines) + '\n')
            self.assertEqual(failures(path), [])
            path.write_text('\n'.join(line for line in lines if not line.startswith('build-app\t')) + '\n')
            self.assertIn('missing step: build-app', failures(path))
            path.write_text('\n'.join(lines).replace('build-app\t0', 'build-app\t1') + '\n')
            self.assertIn('failed step: build-app', failures(path))
            path.write_text('')
            self.assertTrue(failures(path))

    def test_environment_failures_cannot_hide_behind_pass_aggregate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'steps.tsv'
            path.write_text(''.join(name + '\t0\t1\n' for name in REQUIRED))
            self.assertIn('missing or malformed UI acceptance evidence', failures(path))
            green_ui(path)
            gate_path = path.with_name('ui-gate.json')
            gate = json.loads(gate_path.read_text())
            gate['launches'][0]['failures'] = [dict(kind='FAIL-ENV', message='window not key')]
            gate_path.write_text(json.dumps(gate))
            self.assertIn('UI acceptance not green: fixture', failures(path))
            gate['launches'] = []
            gate_path.write_text(json.dumps(gate))
            self.assertIn('no UI acceptance launches', failures(path))

    def test_compile_lock_can_be_released_before_ui(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp)
            code = ('import fcntl, os; from pathlib import Path; '
                    'fcntl.flock(int(os.environ["AIRC_BUILD_LOCK_FD"]), fcntl.LOCK_UN); '
                    'f=(Path.home()/"arcfork/.agent-build.lock").open("a"); '
                    'fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)')
            result = subprocess.run([sys.executable, str(ROOT/'scripts/build-lock.py'),
                                     'bash', '-c', 'exec "$@"', 'lock-proof', sys.executable, '-c', code],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_ship_budget_cannot_bypass_strict_ui_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home/'arcfork').mkdir()
            (home/'budget').write_text('300')
            with (home/'arcfork/.ui-check.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                env = dict(os.environ, HOME=tmp, AIRC_UI_LOCK_STRICT='1', AIRC_UI_LOCK_PROCEED='1',
                           AIRC_UI_LOCK_TIMEOUT='0', AIRC_UI_LOCK_BUDGET_FILE=str(home/'budget'))
                result = subprocess.run([sys.executable, str(ROOT/'scripts/ui-check-lock.py'),
                                         sys.executable, '-c', 'raise SystemExit(42)'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 75, result.stdout+result.stderr)
                self.assertIn('timeout, refusing', result.stdout)

    def test_full_acceptance_waits_per_launch_without_bypassing_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home/'arcfork').mkdir()
            (home/'budget').write_text('300')
            with (home/'arcfork/.ui-check.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                env = dict(os.environ, HOME=tmp, AIRC_UI_LOCK_STRICT='1', AIRC_UI_LOCK_PER_LAUNCH='1',
                           AIRC_UI_LOCK_TIMEOUT='2', AIRC_UI_LOCK_BUDGET_FILE=str(home/'budget'))
                process = subprocess.Popen([sys.executable, str(ROOT/'scripts/ui-check-lock.py'),
                                            sys.executable, '-c', 'raise SystemExit(42)'],
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    time.sleep(0.25)
                    self.assertIsNone(process.poll(), 'must wait for the held lock')
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 42, stdout+stderr)
                    self.assertIn('acquired', stdout)
                    self.assertEqual((home/'budget').read_text(), '300')
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()


if __name__ == '__main__':
    unittest.main()
