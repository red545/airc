# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
from datetime import datetime
import json
import os
import plistlib
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import ui_gate
from run_result import state
import work_page

LOCK = [dict(start='2026-01-01T12:00:00Z', end='2026-01-01T12:01:00Z', seconds=60)]


class KeyboardNavigationTests(unittest.TestCase):
    def test_restores_console_preference_when_check_fails(self):
        read = subprocess.CompletedProcess([], 0, '0\n', '')
        with patch.dict(os.environ, AIRC_UI_DEDICATED_SESSION='1'), patch.object(ui_gate.subprocess, 'run', return_value=read) as run:
            with self.assertRaisesRegex(RuntimeError, 'check failed'):
                with ui_gate.keyboard_navigation('arcimport2'):
                    raise RuntimeError('check failed')
            self.assertEqual(run.call_args_list[-1].args[0],
                             ['defaults', 'write', '-g', 'AppleKeyboardUIMode', '-int', '0'])

    def test_restores_absent_preference_after_success(self):
        missing = subprocess.CompletedProcess([], 1, '', 'does not exist')
        with patch.dict(os.environ, AIRC_UI_DEDICATED_SESSION='1'), patch.object(ui_gate.subprocess, 'run', return_value=missing) as run:
            with ui_gate.keyboard_navigation('arcimport2'):
                pass
            self.assertEqual(run.call_args_list[-1].args[0], ['defaults', 'delete', '-g', 'AppleKeyboardUIMode'])

    def test_never_changes_other_sessions_or_unrelated_checks(self):
        with patch.object(ui_gate.subprocess, 'run') as run:
            with patch.dict(os.environ, AIRC_UI_DEDICATED_SESSION='0'):
                with ui_gate.keyboard_navigation('arcimport2'):
                    pass
            with patch.dict(os.environ, AIRC_UI_DEDICATED_SESSION='1'):
                with ui_gate.keyboard_navigation('parityk05'):
                    pass
            run.assert_not_called()


class ClassifierTests(unittest.TestCase):
    def test_real_failure_without_lock_is_red(self):
        for line in ('FAIL click library.media.photo.png: not on screen', 'FAIL unit: expected 2, got 3',
                     'FAIL events: timed out after 240 s with 158 steps left'):
            self.assertEqual(ui_gate.classify(line)['state'], 'FAIL')

    def test_drawing_failures_while_locked_are_env_with_evidence(self):
        text = '\n'.join(('FAIL click library.download.fixture: not on screen',
                          'FAIL no sheet to press Cancel on', 'FAIL the sheet has no Delete Space button',
                          'FAIL events: timed out after 240 s with 158 steps left',
                          'FAIL webkitmedia: timed out after 240 s with 38 steps left'))
        result = ui_gate.classify(text, LOCK)
        self.assertEqual(result['state'], 'ENV')
        self.assertEqual(len(result['failures']), 5)
        self.assertTrue(all(f['kind'] == 'FAIL-ENV' and f['locks'] == LOCK for f in result['failures']))

    def test_independent_failures_win_over_lock(self):
        for line in ('FAIL [independent] model invariant', 'ENGINE-FAIL profile isolation',
                     'FAIL-INDEPENDENT serialized state mismatch', 'FAIL unit-level assertion: wrong value', 'FAIL unit: bad count', 'FAIL model: wrong state',
                     'FAIL events: the app wrote no log (crashed or never started)',
                     'FAIL native fullscreen: still alive', 'FAIL watchdog: app hung', 'FAIL no PID after launch',
                     'FAIL app died during exit', 'FAIL app hung during exit', 'FAIL crash during exit'):
            self.assertEqual(ui_gate.classify(line, LOCK)['state'], 'FAIL', line)

    def test_lock_without_failures_is_not_green(self):
        self.assertEqual(ui_gate.classify('PASS painted', LOCK)['state'], 'ENV')
        self.assertEqual(ui_gate.classify('PASS painted')['state'], 'PASS')
        self.assertEqual(ui_gate.classify('screen locked false\nFAIL bad', legacy=True)['state'], 'FAIL')

    def test_unlocked_failure_before_later_lock_in_same_scenario_stays_red(self):
        first = datetime.fromisoformat(LOCK[0]['start'].replace('Z', '+00:00')).timestamp()
        text = f'UI-FAIL-STATE {first - 1} unlocked\nFAIL click target: not on screen'
        self.assertEqual(ui_gate.classify(text, LOCK)['state'], 'FAIL')
        # A timeout after an interrupted drawing phase is still inconclusive, even after unlock.
        text = f'UI-FAIL-STATE {first + 61} unlocked\nFAIL events: timed out after 240 s'
        self.assertEqual(ui_gate.classify(text, LOCK)['state'], 'ENV')
        # The app can observe a brief lock between the outer sampler's observations.
        text = f'UI-FAIL-STATE {first} locked\nFAIL click target: not on screen'
        result = ui_gate.classify(text)
        self.assertEqual(result['state'], 'ENV')
        self.assertEqual(result['failures'][0]['locks'][0]['seconds'], 0)

    def test_other_interference_is_not_green(self):
        self.assertEqual(ui_gate.classify('FAIL-ENV clipboard changed by another app')['state'], 'ENV')
        self.assertEqual(ui_gate.classify('FAIL-ENV click blocked (the screen is locked)')['state'], 'ENV')

    def test_legacy_unknown_failure_not_excused(self):
        self.assertEqual(ui_gate.classify('screen locked true\nFAIL incorrect serialization', legacy=True)['state'], 'FAIL')

    def test_replay_recorded_runs(self):
        # Optional external evidence: never commit the owner's raw logs or identity.
        root = os.environ.get('AIRC_LOCKGATE_REPLAY_RUNS')
        if not root:
            self.skipTest('set AIRC_LOCKGATE_REPLAY_RUNS to the local status/runs folder')
        for name in ('2026-11-07_1321', '2026-11-07_1356'):
            text = (Path(root) / name / 'build-app.log').read_text()
            result = ui_gate.classify(text, legacy=True)
            self.assertEqual(result['state'], 'ENV', name)
            self.assertTrue(result['failures'])
            self.assertTrue(all(f['kind'] == 'FAIL-ENV' for f in result['failures']))
            print(f'{name}: ENV; {len(result["failures"])} environmental failures; historical timing unavailable')

    def test_ioreg_plist_and_missing_session(self):
        for locked in (False, True):
            payload = plistlib.dumps([{'IOConsoleUsers': [{'CGSSessionScreenIsLocked': locked}]}])
            with patch.object(ui_gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, payload)):
                self.assertIs(ui_gate.screen_locked(), locked)
        with patch.object(ui_gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, b'<plist><array/></plist>')):
            with self.assertRaises(ValueError):
                ui_gate.screen_locked()

    def test_lock_intervals_survive_unlock_and_main_thread_stalls(self):
        observation = ui_gate.Observation()
        with patch.object(ui_gate, 'screen_locked', side_effect=[False, True, True, False, True]), \
                patch.object(ui_gate.time, 'time', side_effect=[100, 101, 105, 106, 110]):
            for _ in range(5):
                observation.sample()
        evidence = observation.evidence()
        self.assertEqual(len(evidence), 2)
        self.assertEqual(evidence[0]['seconds'], 4)
        self.assertEqual(evidence[0]['start'], ui_gate.utc(101))
        self.assertEqual(evidence[0]['end'], ui_gate.utc(105))
        self.assertEqual(evidence[1]['seconds'], 0)

    def test_preflight_no_launch_while_locked(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ui_gate, 'screen_locked', return_value=True), \
                patch.object(ui_gate, 'run_bounded') as call:
            path = Path(temp) / 'ui-gate.json'
            self.assertEqual(ui_gate.preflight(path), 75)
            self.assertEqual(json.loads(path.read_text())['state'], 'WAIT')
            call.assert_not_called()

    def test_lock_during_ui_lock_wait(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ui_gate, 'screen_locked', return_value=False):
            path = Path(temp) / 'ui-gate.json'
            ui_gate.preflight(path)
            with patch.object(ui_gate, 'screen_locked', return_value=True), \
                    patch.dict(os.environ, AIRC_SHIP_GATE='1'), patch.object(ui_gate, 'run_bounded') as call:
                self.assertEqual(ui_gate.launch(path, ['open']), 75)
                call.assert_not_called()
            self.assertEqual(json.loads(path.read_text())['state'], 'WAIT')

    def test_midrun_then_unlocked_real_failure_stays_red(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ui_gate, 'screen_locked', return_value=False):
            folder = Path(temp)
            path = folder / 'ui-gate.json'
            ui_gate.preflight(path)
            command = ['open', '--script', 'events', '--snapshot', temp]
            def write_log(*args, **kwargs):
                with (folder / 'log.txt').open('a') as log:
                    log.write('[events]\nFAIL click target: not on screen\n')
                return 0, None
            with patch.object(ui_gate, 'run_bounded', side_effect=write_log):
                with patch.object(ui_gate, 'screen_locked', side_effect=[False, True]):
                    self.assertEqual(ui_gate.launch(path, command), 0)
                self.assertEqual(json.loads(path.read_text())['state'], 'ENV')
                self.assertEqual(ui_gate.launch(path, command), 0)
                data = json.loads(path.read_text())
                self.assertEqual(data['state'], 'FAIL')
                self.assertEqual([x['state'] for x in data['launches']], ['ENV', 'FAIL'])

    def test_probe_failure_cannot_publish(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ui_gate, 'screen_locked', side_effect=TimeoutError):
            path = Path(temp) / 'ui-gate.json'
            self.assertEqual(ui_gate.preflight(path), 75)
            self.assertEqual(json.loads(path.read_text())['state'], 'ENV')

    def test_exit_75_requires_gate_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            run = Path(temp)
            (run / 'steps.tsv').write_text('build-app\t75\t10\n')
            self.assertEqual(state(run), 'FAIL')
            (run / 'ui-gate.json').write_text('{"state":"PASS"}')
            self.assertEqual(state(run), 'FAIL')
            (run / 'ui-gate.json').write_text('{"state":"ENV"}')
            self.assertEqual(state(run), 'ENV')
            with (run / 'steps.tsv').open('a') as output:
                output.write('test-AircKit\t75\t10\n')
            self.assertEqual(state(run), 'FAIL')

    def test_wait_status_and_package_failure_precedence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run = root / 'runs' / '2026-01-01_1200'
            run.mkdir(parents=True)
            (run / 'steps.tsv').write_text('mac-online\t0\t1\nbuild-app\t75\t10\npublish-dev\t3\t0\n')
            (run / 'ui-gate.json').write_text('{"state":"WAIT"}')
            self.assertEqual(state(run), 'WAIT')
            with patch.object(work_page, 'published_revs', return_value={}):
                self.assertEqual(work_page.runs(root)[0][3], 'waiting: screen locked')
            subprocess.run([sys.executable, str(Path(__file__).with_name('status.py')), temp], check=True, capture_output=True)
            page = (root / 'index.html').read_text()
            self.assertIn('waiting: screen locked', page)
            self.assertIn('runs/2026-01-01_1200/ui-gate.json', page)
            self.assertNotIn('❌', page)
            self.assertNotIn('✅', page)
            with (run / 'steps.tsv').open('a') as output:
                output.write('test-AircKit\t1\t3\n')
            self.assertEqual(state(run), 'FAIL')


class BundleExecutableTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / 'Synthetic Airc.app'
        (self.bundle / 'Contents').mkdir(parents=True)
        (self.bundle / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleExecutable': 'Synthetic Airc'}))
        self.executable = (self.bundle / 'Contents/MacOS/Synthetic Airc').resolve()

    def test_preview_env_and_redirect_paths_are_not_bundles(self):
        command = ['/usr/bin/open', '--env', 'AIRC_SHARING_BASE=https://synthetic-preview.vercel.app',
                   '--stdout', '/synthetic/output.app', '--stderr', '/synthetic/error.app',
                   '-g', '-n', '-W', '--env', 'OTHER=/synthetic/other.app', str(self.bundle),
                   '--args', '--script', 'events', '--fixture', '/synthetic/fixture.app']
        self.assertEqual(ui_gate.bundle_executable(command), self.executable)

    def test_explicit_application_operand_forms(self):
        for prefix in ([], ['--'], ['-a'], ['--application']):
            with self.subTest(prefix=prefix):
                self.assertEqual(ui_gate.bundle_executable(
                    ['open', '-n', '-W', *prefix, str(self.bundle)]), self.executable)

    def test_app_arguments_and_non_open_commands_are_not_scanned(self):
        self.assertIsNone(ui_gate.bundle_executable(['open', '--args', str(self.bundle)]))
        self.assertIsNone(ui_gate.bundle_executable(['python3', 'check.py', str(self.bundle)]))

    def test_missing_values_and_ambiguous_options_refuse(self):
        for arguments in (['--env'], ['--stdout'], ['-a'], ['--'], ['--unknown', str(self.bundle)],
                          ['https://synthetic.invalid', str(self.bundle)]):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                ui_gate.bundle_executable(['open', *arguments])

    def test_executable_cannot_escape_bundle(self):
        (self.bundle / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleExecutable': '../../unrelated'}))
        with self.assertRaisesRegex(ValueError, 'invalid bundle executable'):
            ui_gate.bundle_executable(['open', str(self.bundle)])


class WatchdogTests(unittest.TestCase):
    def test_budget_can_only_be_shortened(self):
        with patch.dict(os.environ, AIRC_UI_LAUNCH_TIMEOUT='9999'):
            self.assertEqual(ui_gate.launch_budget('events'), 270)
            self.assertEqual(ui_gate.launch_budget('perf'), 690)
        with patch.dict(os.environ, AIRC_UI_LAUNCH_TIMEOUT='5'):
            self.assertEqual(ui_gate.launch_budget('events'), 5)
        for value in ['nan', 'inf', '0', '-1']:
            with patch.dict(os.environ, AIRC_UI_LAUNCH_TIMEOUT=value), self.assertRaises(ValueError):
                ui_gate.launch_budget('events')

    def test_process_identity_requires_executable_and_launch_arguments(self):
        executable = Path('/synthetic/App.app/Contents/MacOS/App')
        snapshot = Path('/synthetic/evidence with spaces')
        rows = f'41 {executable}\n42 {executable}\n43 /synthetic/Other.app/Contents/MacOS/App\n'
        commands = {41: f'{executable} --snapshot {snapshot} --script events',
                    42: f'{executable} --snapshot /synthetic/other --script events'}
        def arguments(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, commands[int(command[3])])
        with patch.object(ui_gate.subprocess, 'check_output', return_value=rows), \
                patch.object(ui_gate.subprocess, 'run', side_effect=arguments):
            self.assertEqual(ui_gate.matching_app_pids(executable, snapshot, 'events'), {41})

    def test_sample_then_signal_only_new_owned_pid(self):
        active = {41, 42}
        order = []
        def sample(command, **kwargs):
            order.append(('sample', int(command[1])))
            return subprocess.CompletedProcess(command, 0)
        def kill(pid, sig):
            order.append(('signal', pid, sig))
            active.remove(pid)
        evidence = {}
        with patch.object(ui_gate, 'matching_app_pids', side_effect=lambda *args: set(active)), \
                patch.object(ui_gate.subprocess, 'run', side_effect=sample), patch.object(ui_gate.os, 'kill', side_effect=kill):
            ui_gate.stop_owned_app(Path('/synthetic/App'), Path('/synthetic'), 'events', {41}, evidence)
        self.assertEqual(order, [('sample', 42), ('signal', 42, signal.SIGTERM)])
        self.assertEqual(active, {41})

    def test_identity_is_rechecked_after_sampling(self):
        # The observed app exited during sampling; never signal a reused PID.
        with patch.object(ui_gate, 'matching_app_pids', side_effect=[{42}, set(), set(), set(), set()]), \
                patch.object(ui_gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(ui_gate.os, 'kill') as kill:
            ui_gate.stop_owned_app(Path('/synthetic/App'), Path('/synthetic'), 'events', set(), {})
            kill.assert_not_called()

    def test_blocked_child_is_bounded_and_prior_failure_survives(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, AIRC_UI_LAUNCH_TIMEOUT='0.1'):
            root = Path(temp)
            (root / 'log.txt').write_text('[earlier]\nFAIL earlier assertion\n')
            started = time.monotonic()
            code, evidence = ui_gate.run_bounded([sys.executable, '-c', 'import time; time.sleep(60)'], root, 'watchdog')
            self.assertEqual(code, 124)
            self.assertLess(time.monotonic() - started, 8)
            self.assertEqual(evidence['timeout_seconds'], 0.1)
            log = (root / 'log.txt').read_text()
            self.assertIn('FAIL earlier assertion', log)
            self.assertIn('launcher hard timeout', log)
            self.assertEqual(ui_gate.classify(log, LOCK)['state'], 'FAIL')


class ShipLoopTests(unittest.TestCase):
    def exercise_loop(self, states):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            infra, commands, status = root / 'infra', root / 'bin', root / 'status'
            infra.mkdir(); commands.mkdir(); status.mkdir()
            for name in ('ship-loop.sh', 'run_result.py'):
                (infra / name).write_bytes(Path(__file__).with_name(name).read_bytes())
            # A fixed HEAD, no nightly reservation, and fast sleeps. All files and locks
            # are in this fixture; no real Mac, git working tree or live status is touched.
            fixtures = {
                'git': '#!/bin/sh\ncase "$3" in rev-parse) echo fixturehead;; log) echo 0;; esac\n',
                'date': '#!/bin/sh\nif [ "$2" = +%H%M ]; then echo 1200; else /bin/date "$@"; fi\n',
                'sleep': '#!/usr/bin/env python3\nimport time\ntime.sleep(0.02)\n',
            }
            for name, text in fixtures.items():
                path = commands / name
                path.write_text(text); path.chmod(0o755)
            nightly = infra / 'nightly.sh'
            nightly.write_text("""#!/usr/bin/env python3
import json, os
from pathlib import Path
status = Path(os.environ['AIRC_STATUS_DIR'])
count = status / 'count'
n = int(count.read_text()) + 1 if count.exists() else 1
states = json.loads(os.environ['AIRC_TEST_STATES'])
state = states[min(n - 1, len(states) - 1)]
run = status / 'runs' / f'{n:04d}'
run.mkdir(parents=True)
rc = 0 if state == 'PASS' else 1 if state == 'FAIL' else 75
(run / 'steps.tsv').write_text(f'mac-online\\t0\\t1\\nbuild-app\\t{rc}\\t1\\n')
(run / 'ui-gate.json').write_text(json.dumps(dict(state=state)))
count.write_text(str(n))
""")
            nightly.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
                       AIRC_STATUS_DIR=str(status), AIRC_SHIP_QUIET='0', AIRC_TEST_STATES=json.dumps(states))
            process = subprocess.Popen(['bash', str(infra / 'ship-loop.sh')], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    log = (status / 'ship-loop.log').read_text() if (status / 'ship-loop.log').exists() else ''
                    count = int((status / 'count').read_text() or '0') if (status / 'count').exists() else 0
                    if count >= len(states) and 'finished:' in log:
                        break
                    time.sleep(0.02)
                else:
                    self.fail('ship loop did not finish fixture: ' + log)
                time.sleep(0.15)
                self.assertEqual(int((status / 'count').read_text()), len(states))
                return log
            finally:
                process.terminate()
                process.communicate(timeout=5)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'ship loop runs on Linux (flock)')
    def test_same_head_retries_env_and_wait_then_stops_on_pass(self):
        log = self.exercise_loop(['ENV', 'WAIT', 'PASS'])
        self.assertEqual(log.count('retrying in three minutes'), 2)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'ship loop runs on Linux (flock)')
    def test_same_head_does_not_retry_red(self):
        log = self.exercise_loop(['FAIL'])
        self.assertNotIn('retrying in three minutes', log)


if __name__ == '__main__':
    unittest.main()
