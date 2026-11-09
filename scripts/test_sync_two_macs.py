# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
from pathlib import Path
import unittest
import json
import tempfile
import types
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load('sync-two-macs')
host = load('sync-test-host')
build_lock = load('sync-test-build-lock')


class SafetyTests(unittest.TestCase):
    def test_busy_build_host_returns_without_starting_or_waiting(self):
        import fcntl
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'arcfork').mkdir()
            with (root / 'arcfork/.agent-build.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                with patch.object(build_lock.Path, 'home', return_value=root), patch.object(build_lock.subprocess, 'Popen') as popen:
                    self.assertEqual(build_lock.main(), 75)
                    popen.assert_not_called()

    def test_window_is_exact_and_not_daily(self):
        for now in (runner.START - 1, runner.END, runner.START + 86400):
            with self.assertRaises(RuntimeError):
                runner.guard('mac-manual', now)
        runner.guard('mac-manual', runner.START)
        runner.guard('mac-manual', runner.END - .001)
        runner.guard('buildmac', runner.START - 86400)

    def test_no_old_alias_or_arbitrary_destination(self):
        for name in ('mac', 'localhost', 'other', ''):
            with self.assertRaises(ValueError):
                runner.guard(name, runner.START)

    def test_no_ssh_process_created_outside_window(self):
        with patch.object(runner.time, 'time', return_value=runner.START - 1), patch.object(runner.subprocess, 'run') as run:
            with self.assertRaises(RuntimeError):
                runner.ssh('mac-manual', 'true')
            run.assert_not_called()

    def test_pid_selection_excludes_owner_and_shells(self):
        listing = f'''101 {host.APP}/Contents/MacOS/Airc --data-dir test
102 /Applications/Airc.app/Contents/MacOS/Airc
103 /bin/sh -c {host.APP}/Contents/MacOS/Airc
104 {host.ROOT}/Other.app/Contents/MacOS/Airc
105 {host.APP}/Contents/Frameworks/Airc Helper.app/Contents/MacOS/Airc Helper
'''
        with patch.object(host.subprocess, 'check_output', return_value=listing):
            self.assertEqual(host.own_pids(), [101, 105])

    def test_reset_preserves_uncleaned_key_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / 'data-A/synctest'
            data.mkdir(parents=True)
            (data / 'groups.json').write_text(json.dumps(['test-group']))
            (data / 'zone.json').write_text(json.dumps('AircSidebarTestOld'))
            receipt_key = 'AircSidebarTestOld:test-group'
            with patch.object(host, 'ROOT', root), patch.object(host, 'own_pids', return_value=[]):
                with self.assertRaises(RuntimeError):
                    host.reset_data()
                self.assertTrue(data.exists())
                (root / 'cleanup.json').write_text(json.dumps({receipt_key: {'keyGone': True,
                    'zoneGone': False, 'subscriptionGone': True}}))
                with self.assertRaises(RuntimeError):
                    host.reset_data()
                self.assertTrue(data.exists())
                (root / 'cleanup.json').write_text(json.dumps({receipt_key: {'keyGone': True,
                    'zoneGone': True, 'subscriptionGone': True}}))
                host.reset_data()
                self.assertFalse(data.exists())

    def test_zone_without_group_still_requires_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / 'data-A/synctest'
            data.mkdir(parents=True)
            (data / 'zone.json').write_text(json.dumps('AircSidebarTestEmpty'))
            with patch.object(host, 'ROOT', root), patch.object(host, 'own_pids', return_value=[]):
                with self.assertRaises(RuntimeError):
                    host.reset_data()
                (root / 'cleanup.json').write_text(json.dumps({'AircSidebarTestOther:': {
                    'keyGone': True, 'zoneGone': True, 'subscriptionGone': True}}))
                with self.assertRaises(RuntimeError):
                    host.reset_data()
                (root / 'cleanup.json').write_text(json.dumps({'AircSidebarTestEmpty:': {
                    'keyGone': True, 'zoneGone': True, 'subscriptionGone': True}}))
                host.reset_data()
                self.assertFalse(data.exists())

    def test_reset_failure_never_cleans_previous_run_with_new_zone(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = runner.Run(types.SimpleNamespace(output=Path(temporary), dry_run=True))
            with patch.object(runner, 'ssh', side_effect=RuntimeError('Uncleaned previous zone')), \
                    patch.object(run, 'cleanup_cloud') as cleanup, patch.object(run, 'exercise') as exercise:
                self.assertEqual(run.run(), 1)
                cleanup.assert_not_called()
                exercise.assert_not_called()

    def test_exited_launcher_never_waits_for_mailbox_or_startup(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = runner.Run(types.SimpleNamespace(output=Path(temporary), dry_run=True))
            run.running['A'] = (types.SimpleNamespace(poll=lambda: 75, returncode=75), None)
            with patch.object(runner, 'ssh') as ssh:
                with self.assertRaises(RuntimeError):
                    run.command('A', 'disable')
                with self.assertRaises(RuntimeError):
                    run.wait('A', 'launched', lambda state: True)
                ssh.assert_not_called()

    def test_persisted_progress_exports_only_completion_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sync = root / 'data-B/Sync'
            sync.mkdir(parents=True)
            (sync / 'sync-state.json').write_text(json.dumps(dict(lastSynced=815953339.678791,
                outbox=[{'sealed': 'not-for-export'}], enabled=True, account='not-for-export')))
            with patch.object(host, 'ROOT', root):
                self.assertEqual(host.progress('B'), dict(lastSynced=1794260539.678791,
                    pendingUploads=1, enabled=True))
                self.assertEqual(host.progress('A'), {})
                with self.assertRaises(ValueError):
                    host.progress('../../try')

    def test_expected_offline_observation_passes_but_cleanup_errors_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            for error in (False, True):
                run = runner.Run(types.SimpleNamespace(output=Path(temporary), dry_run=True))
                def cleanup():
                    if error:
                        run.event('cleanup-discovery-error', error='Keychain unavailable')
                with patch.object(runner, 'ssh'), patch.object(run, 'clock_sample'), \
                        patch.object(run, 'exercise', side_effect=lambda: run.event('offline-error', role='B')), \
                        patch.object(run, 'cleanup_cloud', side_effect=cleanup), patch.object(run, 'collect'):
                    self.assertEqual(run.run(), int(error))

    def test_incomplete_laptop_install_never_launches_cleanup_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = runner.Run(types.SimpleNamespace(output=Path(temporary), dry_run=False))
            run.laptop_owned = True
            answer = dict(keyGone=True, zoneGone=True, subscriptionGone=True)
            with patch.object(run, 'read', return_value=[]), patch.object(run, 'launch') as launch, \
                    patch.object(run, 'command', return_value=answer), patch.object(run, 'quit'):
                run.cleanup_cloud()
                launch.assert_called_once_with('A')

    def test_unregister_timeout_still_removes_only_task_folder(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'task'
            app = root / 'Airc-SyncTest.app'
            app.mkdir(parents=True)
            with patch.object(host, 'ROOT', root), patch.object(host, 'APP', app), \
                    patch.object(host, 'stop_own'), patch.object(host, 'own_pids', return_value=[]), \
                    patch.object(host.subprocess, 'run', side_effect=host.subprocess.TimeoutExpired('lsregister', 15)):
                with self.assertRaises(RuntimeError):
                    host.cleanup()
                self.assertFalse(root.exists())
                self.assertTrue(Path(temporary).exists())

    def test_guardian_removes_bundle_even_if_cloud_cleanup_raises(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(host, 'ROOT', Path(temporary)), patch.object(host, 'window_check'), \
                    patch.object(host.time, 'time', return_value=100), patch.object(host.signal, 'signal'), \
                    patch.object(host, 'emergency_cloud_cleanup', side_effect=RuntimeError('Cloud timeout')), \
                    patch.object(host, 'cleanup') as cleanup:
                with self.assertRaises(RuntimeError):
                    host.guardian(101)
                cleanup.assert_called_once()

    def test_quiet_window_prevents_app_launch(self):
        import types
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'quiet-pending').touch()
            run = runner.Run(types.SimpleNamespace(output=root / 'output', dry_run=True))
            with patch.object(runner, 'STATUS', root), patch.object(runner.subprocess, 'Popen') as popen:
                with self.assertRaises(RuntimeError):
                    run.launch('A')
                popen.assert_not_called()

    def test_launch_refuses_real_zone_and_traversal_before_any_process(self):
        with patch.object(host.subprocess, 'Popen') as popen:
            for role, zone in (('A', 'AircSidebar'), ('../../try', 'AircSidebarTest123')):
                with self.assertRaises(ValueError):
                    host.launch(role, zone, runner.START)
            popen.assert_not_called()


if __name__ == '__main__':
    unittest.main()
