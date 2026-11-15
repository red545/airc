import datetime
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import sys
import uuid
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('proof', Path(__file__).with_name('update-proof.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class DefaultsIsolationTests(unittest.TestCase):
    def exercise(self, present, fail):
        date = datetime.datetime(2026, 1, 2, 3, 4, 5)
        state = {'unrelated': 'before'}
        if present:
            state[proof.KEY] = date
        def run(command, **kwargs):
            if command[1] == 'export':
                return subprocess.CompletedProcess(command, 0, plistlib.dumps(state))
            if command[1] == 'delete':
                del state[proof.KEY]
            elif command[1] == 'write':
                state[proof.KEY] = datetime.datetime.strptime(command[-1], '%Y-%m-%d %H:%M:%S +0000')
            return subprocess.CompletedProcess(command, 0)
        with tempfile.TemporaryDirectory() as tmp, patch.object(proof.subprocess, 'run', side_effect=run):
            try:
                with proof.isolated_check('test.bundle', tmp):
                    self.assertNotIn(proof.KEY, state)
                    state[proof.KEY] = datetime.datetime(2026, 2, 3)
                    state['unrelated'] = 'changed by child'
                    if fail:
                        raise RuntimeError('failed download')
            except RuntimeError:
                if not fail:
                    raise
            self.assertEqual(state.get(proof.KEY), date if present else None)
            self.assertEqual(state['unrelated'], 'changed by child')
            self.assertTrue((Path(tmp) / 'sparkle-defaults-restored.plist').exists())
    def test_restore_existing_on_success(self): self.exercise(True, False)
    def test_restore_existing_on_failure(self): self.exercise(True, True)
    def test_remove_new_on_success(self): self.exercise(False, False)
    def test_remove_new_on_failure(self): self.exercise(False, True)
    def test_snapshot_failure_never_mutates(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(proof.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)) as run:
            with self.assertRaises(RuntimeError):
                with proof.isolated_check('test.bundle', tmp): self.fail('must not launch')
            self.assertEqual(run.call_count, 1)

@unittest.skipUnless(sys.platform == 'darwin', 'requires real macOS cfprefsd')
class MacDefaultsIntegrationTests(unittest.TestCase):
    def test_child_failure_restores_date_and_preserves_unrelated_change(self):
        domain = 'org.airc.update-proof-test.' + uuid.uuid4().hex
        try:
            subprocess.run(['defaults', 'write', domain, proof.KEY, '-date',
                            '2026-01-02 03:04:05 +0000'], check=True)
            with tempfile.TemporaryDirectory() as tmp:
                child = subprocess.run([sys.executable, str(Path(proof.__file__)),
                    '--domain', domain, '--evidence', tmp, '--', sys.executable, '-c',
                    "import subprocess,sys; d=sys.argv[1]; "
                    "assert subprocess.run(['defaults','read',d,'SULastCheckTime'],capture_output=True).returncode != 0; "
                    "subprocess.run(['defaults','write',d,'unrelated','retained'],check=True); sys.exit(7)", domain])
                self.assertEqual(child.returncode, 7)
                state = proof.read_domain(domain)
                self.assertEqual(state[proof.KEY], datetime.datetime(2026, 1, 2, 3, 4, 5))
                self.assertEqual(state['unrelated'], 'retained')
        finally:
            subprocess.run(['defaults', 'delete', domain], capture_output=True)

if __name__ == '__main__': unittest.main()
