import tempfile
import unittest
from pathlib import Path
from run import blocked, case_outcome, critical_failure, order_ready, summarize

class SuiteTest(unittest.TestCase):
    def test_missing_log_does_not_invent_a_launch_or_hide_real_crash_evidence(self):
        self.assertEqual(case_outcome('', dict(state='PASS', launches=[]), 75), ('ENV', False))
        self.assertEqual(case_outcome('', dict(state='PASS', launches=[dict(state='PASS')]), 0), ('ENV', False))
        failed = dict(state='FAIL', launches=[dict(state='FAIL', failures=[dict(message='the app wrote no log (crashed or never started)')])])
        self.assertEqual(case_outcome('', failed, 0), ('FAIL', True))
        self.assertEqual(case_outcome('', dict(state='FAIL', launches=[dict(state='FAIL')]), 0), ('FAIL', False))

    def test_installed_oneshot_treats_yield_as_retryable_failure(self):
        import runpy
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            args = ['install.py', '--repo', str(root / 'owned'), '--remote', 'fixture.invalid/repo',
                    '--status', str(root / 'status'), '--queue', str(root / 'queue')]
            with patch('sys.argv', args), patch.object(Path, 'home', return_value=root), patch('subprocess.run'):
                runpy.run_path(str(Path(__file__).with_name('install.py')))
            unit = (root / '.config/systemd/user/airc-background-suite.service').read_text()
            self.assertIn('Restart=on-failure\n', unit)
            self.assertIn('RestartSec=60\n', unit)
            # A oneshot successful exit is never restarted, even when forced.
            self.assertNotIn('SuccessExitStatus=', unit)

    def test_paired_scenarios_keep_expectations_without_carrying_prior_reds(self):
        from remote import SnapshotEvidence
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); snapshot = root / 'shared'
            write = SnapshotEvidence(snapshot, root / 'write')
            (snapshot / 'windows-session.json').write_text('{"windows": [1, 2]}')
            (snapshot / 'log.txt').write_text('FAIL unrelated write assertion\n')
            write.archive()
            read = SnapshotEvidence(snapshot, root / 'read')
            self.assertEqual((snapshot / 'windows-session.json').read_text(), '{"windows": [1, 2]}')
            with (snapshot / 'log.txt').open('a') as log:
                log.write('PASS restored both windows\n')
            (snapshot / 'read.png').write_bytes(b'new image')
            read.archive()
            self.assertEqual((root / 'read/log.txt').read_text(), 'PASS restored both windows\n')
            self.assertTrue((root / 'read/read.png').exists())
            self.assertFalse((root / 'read/windows-session.json').exists())
            self.assertTrue((root / 'write/windows-session.json').exists())

    def test_snapshot_evidence_handles_log_replacement(self):
        from remote import SnapshotEvidence
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); snapshot = root / 'shared'; snapshot.mkdir()
            (snapshot / 'log.txt').write_text('FAIL previous case\n')
            case = SnapshotEvidence(snapshot, root / 'case')
            (snapshot / 'log.txt').write_text('PASS current case\n')
            case.archive()
            self.assertEqual((root / 'case/log.txt').read_text(), 'PASS current case\n')

    def test_refusal_and_preflight_only_pass_cannot_be_counted_as_pass(self):
        receipt = dict(state='PASS', launches=[])
        self.assertEqual(case_outcome('PASS partial assertion', receipt, 75), ('ENV', False))
        self.assertEqual(case_outcome('PASS partial assertion', receipt, 0), ('ENV', False))
        receipt['launches'] = [dict(state='PASS')]
        self.assertEqual(case_outcome('PASS complete', receipt, 0), ('PASS', False))
        self.assertEqual(case_outcome('PASS complete', receipt, 75), ('ENV', False))

    def test_outer_worker_deadline_is_critical_even_with_partial_pass_log(self):
        receipt = dict(state='PASS', launches=[])
        self.assertEqual(case_outcome('PASS first assertion', receipt, 75,
                                     '@@LOCKED@@\nworker hard deadline\n'), ('FAIL', True))

    def test_passing_crashreport_case_and_changed_assertion_are_not_crashes(self):
        receipt = dict(state='PASS', launches=[dict(script='crashreports', failures=[], state='PASS')])
        self.assertFalse(critical_failure('PASS crash report fixture\n', receipt))
        self.assertFalse(critical_failure('FAIL title changed after edit\n', receipt))

    def test_crash_hang_and_no_pid_failures_stay_critical(self):
        for text in ('FAIL app crashed', 'FAIL app still alive after timeout',
                     'ENGINE-FAIL renderer died', 'FAIL watchdog timeout',
                     'FAIL no PID / wrote no log', 'FAIL app hung', 'FAIL app hangs'):
            with self.subTest(text=text):
                self.assertTrue(critical_failure(text, {}))

    def test_receipt_failures_and_watchdog_are_critical(self):
        self.assertTrue(critical_failure('', dict(launches=[dict(watchdog={}, failures=[])])))
        receipt = dict(launches=[dict(failures=[dict(message='app crashed')])])
        self.assertTrue(critical_failure('', receipt))

    def test_unresolved_crash_survives_new_attempt_until_exact_case_passes(self):
        previous = dict(critical=['webkit/crasher-1'])
        result = dict(state='running', dry_run=False, expected=1, steps={}, cases=[], cleanup_exit=0)
        self.assertEqual(summarize(result, previous)['critical'], previous['critical'])
        result.update(state='complete', cases=[dict(id='webkit/other-1', engine='webkit', state='PASS', worker_exit=0)])
        self.assertFalse(summarize(result, previous)['qualified'])
        result['cases'] = [dict(id='webkit/crasher-1', engine='webkit', state='ENV', worker_exit=0)]
        self.assertEqual(summarize(result, previous)['critical'], previous['critical'])
        result['cases'][0]['state'] = 'PASS'
        self.assertEqual(summarize(result, previous)['critical'], [])
        self.assertTrue(result['qualified'])

    def test_order(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'queue'
            base = 'release016: 0.1.5 LIVE\nhistsugg: quiet starting; will post later\n'
            p.write_text(base)
            self.assertFalse(order_ready(p))
            p.write_text(base + 'The histsugg fixture is running. Will post QUIET CLOSED later.\ntouchpasskeys: REBUILD NOTICE\nytads: REBUILD NOTICE\n')
            self.assertFalse(order_ready(p))
            p.write_text(base + 'histsugg: QUIET CLOSED\nytads: REBUILD NOTICE\ntouchpasskeys: REBUILD NOTICE\n')
            self.assertFalse(order_ready(p))
            p.write_text(base + 'histsugg: QUIET CLOSED\ntouchpasskeys: REBUILD NOTICE\nytads: REBUILD NOTICE\n')
            self.assertTrue(order_ready(p))
    def test_priority_and_engine_change(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            for name in ('priority-build', 'quiet-pending', 'relink-pending', 'release-staging'):
                (p / name).touch(); self.assertTrue(blocked(p)); (p / name).unlink()
            self.assertTrue(blocked(p, 'abc'))
            (p / 'buildmac-engine-ready').write_text('abc')
            self.assertFalse(blocked(p, 'abc'))
    def test_incomplete_and_environment_never_qualify(self):
        base = dict(state='complete', dry_run=False, expected=2, steps={'build': 0}, cleanup_exit=0, cases=[
            dict(id='a', engine='webkit', state='PASS', worker_exit=0), dict(id='b', engine='chromium', state='PASS', worker_exit=0)])
        self.assertTrue(summarize(base, {})['qualified'])
        for worker_exit in (None, 75, 1):
            base['cases'][0]['worker_exit'] = worker_exit
            self.assertFalse(summarize(base, {})['qualified'])
        base['cases'][0]['worker_exit'] = 0
        for field, value in [('state', 'aborted'), ('dry_run', True), ('expected', 3), ('cleanup_exit', None), ('cleanup_exit', 75)]:
            self.assertFalse(summarize(dict(base, **{field: value}), {})['qualified'])
        base['cases'][1].update(state='ENV', critical=True)
        result = summarize(base, {'reds': ['a']})
        self.assertFalse(result['qualified']); self.assertEqual(result['new_reds'], ['b'])
        self.assertEqual(result['critical'], ['b'])


class WorkerTest(unittest.TestCase):
    def test_stop_and_eof_release_build_lock_and_child(self):
        import fcntl, json, os, subprocess, sys
        for stop in (b'STOP\n', b'', b'RUN\n' * 100 + b'STOP\n'):
            with tempfile.TemporaryDirectory() as d:
                home = Path(d); (home/'arcfork').mkdir()
                pidfile = home/'pid'
                job = home/'job.json'
                job.write_text(json.dumps(dict(kind='build', revision='a'*40, command=[sys.executable, '-c',
                    f'import os,time; open({str(pidfile)!r},"w").write(str(os.getpid())); time.sleep(120)'])))
                p = subprocess.Popen([sys.executable, str(Path(__file__).with_name('remote.py')), str(job)],
                                     env=dict(os.environ, HOME=d), stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                p.stdin.write(b'RUN\n'); p.stdin.flush()
                self.assertEqual(p.stdout.readline().strip(), b'@@LOCKED@@')
                p.stdin.write(b'ACK\n'); p.stdin.flush()
                import time
                until = time.monotonic()+5
                while not pidfile.exists() and time.monotonic()<until: time.sleep(.05)
                self.assertTrue(pidfile.exists())
                if stop: p.stdin.write(stop); p.stdin.flush()
                else: p.stdin.close()
                self.assertEqual(p.wait(timeout=10),75)
                with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()),0)
                with (home/'arcfork/.agent-build.lock').open() as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX|fcntl.LOCK_NB)
                p.stdout.close()
                if not p.stdin.closed: p.stdin.close()

class WorkerProgressTest(unittest.TestCase):
    def test_remote_lock_wait_is_visible_before_running_and_cleanup(self):
        import concurrent.futures, fcntl, sys, threading, time
        from unittest.mock import patch
        import run
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            remote = 'arcfork/work/bgsuite-123456'
            export = root / remote
            export.mkdir(parents=True)
            (export / 'infra').symlink_to(Path(__file__).resolve().parents[1])
            status = root / 'status'; status.mkdir()
            (status / 'buildmac-engine-ready').write_text('engine')
            # A local transport exercises the real worker/ACK protocol without a Mac.
            transport = [sys.executable, '-c',
                'import os,subprocess,sys; os.chdir(sys.argv[1]); os.environ["HOME"]=sys.argv[1]; sys.exit(subprocess.call(sys.argv[2],shell=True))', d]
            events = []; queued = threading.Event()
            def progress(waiting_on):
                events.append(waiting_on)
                if waiting_on == 'buildmac-build-lock': queued.set()
            with (root/'arcfork/.agent-build.lock').open('a') as lock, patch.object(run, 'SSH', transport):
                fcntl.flock(lock, fcntl.LOCK_EX)
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    future = pool.submit(run.worker, remote,
                        dict(kind='build', revision='a'*40, command=[sys.executable, '-c', 'print("fixture complete")']),
                        root/'worker.log', status, 'engine', progress)
                    try:
                        self.assertTrue(queued.wait(5))
                        time.sleep(.3)
                        self.assertNotIn(None, events)
                        self.assertTrue(future.done())
                    finally:
                        fcntl.flock(lock, fcntl.LOCK_UN)
                    with self.assertRaises(run.Preempted):
                        future.result(timeout=10)
            self.assertEqual(events, ['buildmac-setup', 'buildmac-build-lock', 'buildmac-cleanup'])


class CheckoutTest(unittest.TestCase):
    def test_stale_shared_tree_is_untouched_and_runner_comes_from_fetched_main(self):
        import subprocess
        from checkout import command, prepare
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); upstream = root/'upstream'; shared = root/'shared'; owned = root/'owned'
            def git(*args):
                return subprocess.check_output(['git', *map(str,args)], text=True, stderr=subprocess.DEVNULL).strip()
            git('init','-b','main',upstream)
            git('-C',upstream,'config','user.name','Fixture')
            git('-C',upstream,'config','user.email','fixture@example.invalid')
            (upstream/'old').write_text('old')
            git('-C',upstream,'add','old'); git('-C',upstream,'commit','-m','old')
            git('clone',upstream,shared)
            before = git('-C',shared,'rev-parse','HEAD')
            (shared/'old').write_text('uncommitted peer work')
            (upstream/'infra/suite').mkdir(parents=True)
            (upstream/'infra/engine-inputs.sh').write_text('echo new-engine-helper\n')
            (upstream/'infra/suite/run.py').write_text("from pathlib import Path\nimport subprocess\nsubprocess.run(['bash',str(Path(__file__).resolve().parents[1]/'engine-inputs.sh')],check=True)\n")
            git('-C',upstream,'add','infra'); git('-C',upstream,'commit','-m','new helper and runner')
            cmd = command(owned, str(upstream), [])
            self.assertEqual(subprocess.check_output(cmd,text=True).strip(),'new-engine-helper')
            self.assertEqual(git('-C',owned,'rev-parse','HEAD'),git('-C',upstream,'rev-parse','HEAD'))
            self.assertFalse((shared/'infra/engine-inputs.sh').exists())
            self.assertEqual(git('-C',shared,'rev-parse','HEAD'),before)
            self.assertEqual((shared/'old').read_text(),'uncommitted peer work')
            with self.assertRaises(RuntimeError): prepare(shared,str(upstream))
            (upstream/'infra/engine-inputs.sh').write_text('echo next-main\n')
            git('-C',upstream,'add','infra'); git('-C',upstream,'commit','-m','next main')
            self.assertEqual(subprocess.check_output(command(owned,str(upstream),[]),text=True).strip(),'next-main')

class BuildQueueTest(unittest.TestCase):
    def test_queued_build_yields_when_release_marker_appears(self):
        import fcntl, subprocess, sys, time
        with tempfile.TemporaryDirectory() as d:
            status = Path(d)
            with (status/'.agent-build.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                code = '''import sys
from pathlib import Path
from run import build_lock, Preempted
print('waiting',flush=True)
try:
 with build_lock(Path(sys.argv[1])): raise AssertionError('acquired held lock')
except (Preempted, InterruptedError): sys.exit(75)
'''
                child = subprocess.Popen([sys.executable,'-c',code,d],cwd=Path(__file__).parent,stdout=subprocess.PIPE)
                self.assertEqual(child.stdout.readline().strip(),b'waiting')
                time.sleep(.1)
                (status/'release-staging').touch()
                self.assertEqual(child.wait(timeout=3),75)
                child.stdout.close()

class DescendantTest(unittest.TestCase):
    def test_child_in_separate_session_cannot_outlive_parent_cleanup(self):
        import json, os, signal, subprocess, sys, time
        from processes import Descendants, snapshot
        with tempfile.TemporaryDirectory() as d:
            pidfile = Path(d)/'child'
            grandchild = f'import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open({str(pidfile)!r},"w").write(str(os.getpid())); time.sleep(120)'
            parent = subprocess.Popen([sys.executable,'-c',
                'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",'+repr(grandchild)+'],start_new_session=True); time.sleep(120)'],start_new_session=True)
            tree = Descendants(parent.pid)
            try:
                deadline=time.monotonic()+5
                while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.05)
                self.assertTrue(pidfile.exists())
                child=int(pidfile.read_text())
                self.assertIn(child,tree.sample())
                tree.stop()
                parent.wait(timeout=3)
                self.assertFalse(tree.sample())
                row=snapshot().get(child)
                self.assertTrue(row is None or row[1].startswith('Z'))
            finally:
                tree.stop()
                parent.wait(timeout=3)

class CleanupAcknowledgementTest(unittest.TestCase):
    def test_export_not_deleted_until_worker_acknowledges_cleanup(self):
        import subprocess, sys, time
        from run import cleanup_code
        with tempfile.TemporaryDirectory() as d:
            name='arcfork/work/bgsuite-123'
            root=Path(d)/name; root.mkdir(parents=True)
            (root/'job.json').write_text('{}')
            child=subprocess.Popen([sys.executable,'-c',cleanup_code(name,remove=True)],cwd=d)
            try:
                time.sleep(.3)
                self.assertIsNone(child.poll())
                self.assertTrue(root.exists())
                (root/'.worker-done').write_text('clean\n')
                self.assertEqual(child.wait(timeout=3),0)
                self.assertFalse(root.exists())
            finally:
                if child.poll() is None: child.kill(); child.wait()

class SchedulerStopTest(unittest.TestCase):
    def test_service_stop_escapes_worker_selector_and_revokes_remote_lease(self):
        import subprocess, sys, time
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            started, cleaned = root/'started', root/'cleaned'
            fake_ssh = root/'ssh.py'
            fake_ssh.write_text(f'''import sys
from pathlib import Path
if sys.argv[-1].startswith('cd '):
 print('@@LOCKED@@',flush=True)
 Path({str(started)!r}).touch()
 for line in sys.stdin:
  if line.strip() == 'STOP': break
 Path({str(cleaned)!r}).touch()
''')
            childcode = f'''import signal,sys
from pathlib import Path
import run
run.SSH=[sys.executable,{str(fake_ssh)!r}]
signal.signal(signal.SIGTERM,run.stop)
try:
 run.worker('arcfork/work/bgsuite-123',dict(kind='ui'),Path({str(root/'worker.log')!r}),Path({d!r}),None)
except run.Preempted: sys.exit(75)
'''
            parentcode = f'''import signal,sys
from schedule import invoke
from run import stop,Preempted
signal.signal(signal.SIGTERM,stop)
try: invoke([sys.executable,'-c',{childcode!r}])
except Preempted: sys.exit(75)
'''
            parent = subprocess.Popen([sys.executable,'-c',parentcode],cwd=Path(__file__).parent)
            try:
                deadline = time.monotonic()+5
                while not started.exists() and time.monotonic()<deadline: time.sleep(.02)
                self.assertTrue(started.exists())
                time.sleep(.2)  # The real worker is now blocked in selector.select.
                parent.terminate()
                self.assertEqual(parent.wait(timeout=3),75)
                self.assertTrue(cleaned.exists(), 'remote lease must see EOF before service stops')
            finally:
                if parent.poll() is None: parent.kill(); parent.wait()

    def test_service_stop_waits_for_child_cleanup(self):
        import os, signal, subprocess, sys, time
        with tempfile.TemporaryDirectory() as d:
            started=Path(d)/'started'; cleaned=Path(d)/'cleaned'
            childcode=f'''import signal,time
from pathlib import Path
def stop(*_):
 time.sleep(.3)
 Path({str(cleaned)!r}).touch()
 raise SystemExit(75)
signal.signal(signal.SIGTERM,stop)
Path({str(started)!r}).touch()
time.sleep(120)
'''
            parentcode=f'''import signal,sys
from schedule import invoke
def stop(*_): raise InterruptedError()
signal.signal(signal.SIGTERM,stop)
try: invoke([sys.executable,'-c',{childcode!r}])
except InterruptedError: sys.exit(75)
'''
            parent=subprocess.Popen([sys.executable,'-c',parentcode],cwd=Path(__file__).parent)
            try:
                deadline=time.monotonic()+5
                while not started.exists() and time.monotonic()<deadline: time.sleep(.05)
                self.assertTrue(started.exists())
                parent.terminate()
                self.assertEqual(parent.wait(timeout=3),75)
                self.assertTrue(cleaned.exists())
            finally:
                if parent.poll() is None: parent.kill(); parent.wait()

class FairQueueTest(unittest.TestCase):
    def test_release_cancels_a_queued_mac_case_without_launch(self):
        import fcntl, json, os, subprocess, sys, time
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root/'arcfork').mkdir()
            job = root/'job.json'
            job.write_text(json.dumps(dict(kind='ui', command=['never-launch'], revision='a'*40)))
            with (root/'arcfork/.ui-check.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                child = subprocess.Popen([sys.executable,str(Path(__file__).with_name('remote.py')),str(job)],
                    env=dict(os.environ,HOME=d),stdin=subprocess.PIPE,stdout=subprocess.PIPE)
                try:
                    child.stdin.write(b'RUN\n'); child.stdin.flush()
                    time.sleep(.6)
                    # Contention alone must refuse promptly, without a STOP.
                    self.assertEqual(child.wait(timeout=4),75)
                    self.assertNotIn(b'@@LOCKED@@',child.stdout.read())
                    self.assertTrue((root/'.worker-done').exists())
                finally:
                    if child.poll() is None: child.kill(); child.wait()
                    child.stdin.close(); child.stdout.close()

class SchedulerHoldTest(unittest.TestCase):
    def test_hold_clearance_starts_on_next_minute_without_idle_lock_probe(self):
        import fcntl,json
        from schedule import wait_ready
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); queue=root/'queue'
            queue.write_text('release016: 0.1.5 LIVE\nhistsugg: QUIET CLOSED\ntouchpasskeys: REBUILD NOTICE\nytads: REBUILD NOTICE\n')
            (root/'buildmac-engine-ready').write_text('engine')
            (root/'release-staging').touch()
            waits=[]
            def sleep(seconds):
                waits.append(seconds)
                receipt=json.loads((root/'suite/scheduler.json').read_text())
                self.assertEqual(receipt['waiting_on'], ['release-staging'])
                (root/'release-staging').unlink()
            with (root/'.agent-build.lock').open('a') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX)
                wait_ready(root,queue,sleep)
            self.assertEqual(waits,[60])
            self.assertEqual(json.loads((root/'suite/scheduler.json').read_text())['state'],'starting')

if __name__ == '__main__':
    unittest.main()
