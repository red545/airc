import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from checkpoint import BINARIES, Checkpoints, MAX_AGE, case_ids, write


class CheckpointTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / 'remote-build'
        for name in BINARIES:
            p = self.build / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'pinned executable')
            p.chmod(0o755)
        self.fixture = self.build / 'snapshot-home/windows-session.json'
        self.fixture.parent.mkdir()
        self.fixture.write_text('saved')
        self.store = Checkpoints(self.root / 'suite')
        self.inventory = [dict(engine='webkit', script=s) for s in ('write', 'read', 'read')]
        self.result = dict(logs='123', revision='a' * 40, engine_marker='engine\n', runner_sha='runner',
                           dry_run=False, expected=3, steps={'build-webkit': 0, 'build-chromium': 0},
                           cases=[dict(id='webkit/write-1', state='PASS')])

    def snapshot(self, result=None):
        return self.store.snapshot(str(self.build) + '/', result or self.result, {}, self.inventory, '/original', now=100)

    def ready(self):
        record = self.snapshot()
        self.store.preempted(dict(self.result, cleanup_exit=0))
        return record

    def select(self, **kwargs):
        return self.store.select(kwargs.get('engine', 'engine\n'), kwargs.get('runner', 'runner'), now=kwargs.get('now', 101))

    def test_runner_identity_allows_new_app_inventory_but_rejects_runner_changes(self):
        from checkpoint import runner_identity
        repo = self.root / 'identity-repo'
        names = ['infra/suite/run.py', 'infra/ui_gate.py', 'infra/engine-inputs.sh',
                 'scripts/build-app.sh', 'scripts/ui-session-preflight.py',
                 'scripts/check-redirect-history.py', 'scripts/ui-check-lock.py']
        for name in names:
            p = repo / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('original')
        original = runner_identity(repo)[0]
        (repo / 'scripts/build-app.sh').write_text('new app scenario on main')
        self.assertEqual(runner_identity(repo)[0], original)
        (repo / 'infra/suite/run.py').write_text('changed coordinator')
        self.assertNotEqual(runner_identity(repo)[0], original)

    def test_resume_preserves_completed_prefix_and_reruns_interrupted_case(self):
        self.ready()
        self.fixture.write_text('partial write from interrupted read')
        record, reason = self.select()
        self.assertIsNone(reason)
        self.assertEqual(record['result']['revision'], 'a' * 40)
        self.assertEqual(list(case_ids(record['inventory']))[len(record['result']['cases']):],
                         ['webkit/read-1', 'webkit/read-2'])
        self.assertEqual((self.store.directory(record) / 'build/snapshot-home/windows-session.json').read_text(), 'saved')
        self.store.activate(record)
        self.assertFalse(self.store.read()['clean_preemption'])

    def test_guard_matrix_discards_and_starts_fresh(self):
        for guard in ('engine', 'runner', 'age', 'missing', 'modified', 'unclean', 'partial-build', 'prefix'):
            with self.subTest(guard=guard):
                self.store.discard()
                self.ready()
                args = {}
                record = self.store.read()
                if guard in ('engine', 'runner'):
                    args[guard] = 'changed'
                elif guard == 'age':
                    args['now'] = 100 + MAX_AGE + 1
                elif guard in ('missing', 'modified'):
                    path = self.store.directory(record) / 'build' / BINARIES[0]
                    path.unlink() if guard == 'missing' else path.write_text('different')
                else:
                    if guard == 'unclean':
                        record['clean_preemption'] = False
                    elif guard == 'partial-build':
                        del record['result']['steps']['build-chromium']
                    else:
                        record['result']['cases'][0]['id'] = 'webkit/read-1'
                    write(self.store.pointer, record)
                selected, reason = self.select(**args)
                self.assertIsNone(selected)
                self.assertTrue(reason)
                self.assertFalse(self.store.pointer.exists())

    def test_atomic_failed_transfer_keeps_previous_state(self):
        prior = self.snapshot()
        candidate = dict(self.result, cases=[*self.result['cases'], dict(id='webkit/read-1', state='PASS')])
        self.fixture.write_text('dirty')
        with patch('checkpoint.subprocess.run', side_effect=InterruptedError('preempted')):
            with self.assertRaises(InterruptedError):
                self.snapshot(candidate)
        self.assertEqual(self.store.read()['generation'], prior['generation'])
        self.assertEqual(len(self.store.read()['result']['cases']), 1)
        self.assertEqual((self.store.directory(prior) / 'build/snapshot-home/windows-session.json').read_text(), 'saved')

    def test_signal_after_pointer_commit_keeps_new_generation(self):
        self.snapshot()
        original = write
        def interrupted(path, value):
            original(path, value)
            if path == self.store.pointer:
                raise InterruptedError('signal after rename')
        with patch('checkpoint.write', side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                self.snapshot()
        self.assertTrue(self.store.directory(self.store.read()).exists())

    def test_equal_size_same_timestamp_change_and_fixed_expiration(self):
        prior = self.snapshot()
        old_stat = self.fixture.stat()
        self.fixture.write_text('newer')
        os.utime(self.fixture, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
        current = self.snapshot()
        self.assertEqual(current['created_at'], prior['created_at'])
        self.assertEqual((self.store.directory(current) / 'build/snapshot-home/windows-session.json').read_text(), 'newer')
        self.assertFalse(self.store.directory(prior).exists())
        self.assertTrue(self.store.expire(now=100 + MAX_AGE + 1))
        self.assertFalse(self.store.pointer.exists())

    def test_complete_removes_checkpoint_so_next_run_is_fresh(self):
        self.ready()
        self.store.complete('123')
        self.assertEqual(self.select(), (None, None))
        self.assertFalse((self.store.root / '123').exists())

    def test_failed_cleanup_cannot_resume(self):
        self.snapshot()
        self.store.preempted(dict(self.result, cleanup_exit=75))
        self.assertIsNone(self.select()[0])

    def test_coordinator_resumes_pinned_revision_and_skips_builds_and_completed_cases(self):
        import json
        import run
        from checkout import OWNER
        repo = self.root / 'repo'
        repo.mkdir()
        real_run, real_output = subprocess.run, subprocess.check_output
        def git(*args):
            return real_run(['git', '-C', str(repo), *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git('init'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'Fixture')
        (repo / 'source').write_text('first')
        git('add', 'source'); git('commit', '-m', 'first')
        first = real_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        (repo / '.git/airc-suite-owner').write_text(OWNER)
        status = self.root / 'status'; status.mkdir()
        (status / 'buildmac-engine-ready').write_text('engine\n')
        calls = []; interrupted = [False]
        def remote_path(path):
            return self.root / path
        def execute(args, **kwargs):
            if args[:len(run.SSH)] == run.SSH:
                code = args[-1]
                if 'mkdir -p' in code:
                    path = code.split('mkdir -p ', 1)[1]
                    remote_path(path).mkdir(parents=True, exist_ok=True)
                elif 'shutil.rmtree' in code and 'True' in code:
                    import shutil
                    for export in (self.root / 'arcfork/work').glob('bgsuite-*'):
                        shutil.rmtree(export)
                return subprocess.CompletedProcess(args, 0)
            if args[0] == 'bash':
                return subprocess.CompletedProcess(args, 0)
            if args[0] == 'rsync':
                args = [str(remote_path(x[len('buildmac:'):])) + '/' if x.startswith('buildmac:') else x for x in args]
                # Evidence paths returned by pwd are already absolute.
            return real_run(args, **kwargs)
        def output(args, **kwargs):
            if args[:len(run.SSH)] == run.SSH:
                return str(remote_path(args[-1].split()[1])) + '\n'
            return real_output(args, **kwargs)
        def inventory(source):
            (source / 'build/snapshot-home').mkdir(parents=True)
            return [dict(engine=e, script=s, command=['fixture', str(source)]) for e, s in
                    [('webkit', 'write'), ('webkit', 'read'), ('chromium', 'read')]]
        def worker(remote, job, log, status, marker, progress):
            calls.append(job['kind'])
            build = remote_path(remote) / 'build'
            log.write_text('worker finished\n')
            if job['kind'] == 'build':
                for name in BINARIES:
                    p = build / name; p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_text('executable'); p.chmod(0o755)
                return 0
            state = build / 'snapshot-home/state'
            caseid = job['snapshot_evidence'].split('/evidence/')[1]
            if caseid == 'webkit/write-1':
                state.write_text('completed')
            elif not interrupted[0]:
                state.write_text('interrupted mutation')
                interrupted[0] = True
                raise InterruptedError('release preemption')
            else:
                self.assertEqual(state.read_text(), 'completed')
            out = Path(job['snapshot_evidence']); out.mkdir(parents=True, exist_ok=True)
            (out / 'log.txt').write_text('PASS completed\n')
            (out / 'ui-gate.json').write_text(json.dumps(dict(state='PASS', launches=[dict(state='PASS')])))
            return 0
        def invoke(revision):
            with patch.object(run, '__file__', str(repo / 'infra/suite/run.py')), patch.object(run, 'order_ready', return_value=True), \
                 patch.object(run, 'runner_identity', return_value=('stable-runner', {})), patch.object(run, 'inventory', side_effect=inventory), \
                 patch.object(run, 'worker', side_effect=worker), patch('subprocess.run', side_effect=execute), \
                 patch('subprocess.check_output', side_effect=output), patch('sys.argv', ['run.py', '--repo', str(repo), '--revision', revision,
                     '--status', str(status), '--queue', str(self.root / 'queue')]):
                return run.main()
        self.assertEqual(invoke(first), 75)
        checkpoint = Checkpoints(status / 'suite').read()
        self.assertTrue(checkpoint['clean_preemption'])
        self.assertEqual(len(checkpoint['result']['cases']), 1)
        (repo / 'source').write_text('new main')
        git('commit', '-am', 'new main')
        newest = real_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        self.assertEqual(invoke(newest), 0)
        latest = json.loads((status / 'suite/latest.json').read_text())
        self.assertEqual(latest['revision'], first)
        self.assertEqual(latest['current_main'], newest)
        self.assertEqual(latest['resume_label'], 'resumed after preemption')
        self.assertEqual(len(latest['cases']), 3)
        self.assertEqual(calls.count('build'), 2)
        self.assertEqual(calls.count('ui'), 4)  # write once, interrupted read twice, chromium once
        self.assertIsNone(Checkpoints(status / 'suite').read())
        self.assertEqual(invoke(newest), 0)
        fresh = json.loads((status / 'suite/latest.json').read_text())
        self.assertEqual(fresh['revision'], newest)
        self.assertNotIn('resume_label', fresh)
        self.assertEqual(calls.count('build'), 4)
