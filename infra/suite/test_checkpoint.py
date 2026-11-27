import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from checkpoint import BINARIES, Checkpoints, MAX_AGE, MAX_BEHIND, case_ids, write


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
                           dry_run=False, expected=3, plan=['unit-AircKit', 'build-webkit', 'build-chromium'],
                           steps={'unit-AircKit': 0, 'build-webkit': 0, 'build-chromium': 0},
                           cases=[dict(id='webkit/write-1', state='PASS')])

    def snapshot(self, result=None):
        return self.store.snapshot(str(self.build) + '/', result or self.result, {}, self.inventory, '/original', now=100)

    def ready(self):
        record = self.snapshot()
        self.store.preempted(dict(self.result, cleanup_exit=0))
        return record

    def select(self, **kwargs):
        return self.store.select(kwargs.get('engine', 'engine\n'), kwargs.get('runner', 'runner'), now=kwargs.get('now', 101),
                                 behind=kwargs.get('behind', 0))

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
        for guard in ('engine', 'runner', 'age', 'missing', 'modified', 'unclean', 'partial-build', 'prefix',
                      'behind', 'not-ancestor', 'step-order', 'failed-step', 'old-schema'):
            with self.subTest(guard=guard):
                self.store.discard()
                self.ready()
                args = {}
                record = self.store.read()
                if guard in ('engine', 'runner'):
                    args[guard] = 'changed'
                elif guard == 'behind':
                    args['behind'] = MAX_BEHIND + 1
                elif guard == 'not-ancestor':
                    args['behind'] = None
                elif guard == 'age':
                    args['now'] = 100 + MAX_AGE + 1
                elif guard in ('missing', 'modified'):
                    path = self.store.directory(record) / 'build' / BINARIES[0]
                    path.unlink() if guard == 'missing' else path.write_text('different')
                else:
                    if guard == 'unclean':
                        record['clean_preemption'] = False
                    elif guard == 'partial-build':   # cases ran, but not after every build step
                        del record['result']['steps']['build-chromium']
                    elif guard == 'step-order':
                        record['result']['steps'] = {'build-webkit': 0}
                        record['result']['cases'] = []
                    elif guard == 'failed-step':
                        record['result']['steps']['unit-AircKit'] = 1
                    elif guard == 'old-schema':
                        record['schema'] = 1
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


class StepCheckpointTest(unittest.TestCase):
    """suiteckpt: every build step is a resume point, not only the finished app builds."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / 'remote-build'
        (self.build / 'snapshot-home').mkdir(parents=True)
        self.store = Checkpoints(self.root / 'suite')
        self.inventory = [dict(engine='webkit', script='read')]
        self.plan = ['unit-AircKit', 'build-webkit', 'build-chromium']

    def result(self, steps, cases=()):
        return dict(logs='77', revision='b' * 40, engine_marker='engine\n', runner_sha='runner', dry_run=False,
                    expected=1, plan=self.plan, steps=dict(steps), cases=list(cases))

    def binaries(self, names):
        for name in names:
            p = self.build / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(name.encode()); p.chmod(0o755)

    def checkpoint(self, result):
        record = self.store.snapshot(str(self.build) + '/', result, {}, self.inventory, '/original', now=100)
        self.store.preempted(dict(result, cleanup_exit=0, yields=2, last_yield=dict(reason='priority-build', at=100)))
        return record

    def select(self, behind=0):
        return self.store.select('engine\n', 'runner', now=101, behind=behind)

    def test_export_only_checkpoint_resumes_with_pinned_inventory(self):
        self.checkpoint(self.result({}))
        record, reason = self.select()
        self.assertIsNone(reason)
        self.assertEqual(record['result']['steps'], {})
        self.assertEqual(record['result']['yields'], 2)
        self.assertEqual(record['build_hashes'], {})

    def test_after_webkit_build_resumes_and_verifies_only_built_binaries(self):
        from checkpoint import PRODUCTS
        webkit = PRODUCTS['build-webkit'][1]
        self.binaries(webkit)
        first = self.checkpoint(self.result({'unit-AircKit': 0, 'build-webkit': 0}))
        self.assertEqual(sorted(first['build_hashes']), sorted(webkit))
        record, reason = self.select()
        self.assertIsNone(reason)
        # Chromium build finishes on resume: the WebKit bundle is linked, not copied again.
        self.binaries(PRODUCTS['build-chromium'][1])
        self.store.activate(record)
        second = self.store.snapshot(str(self.build) + '/', self.result(
            {'unit-AircKit': 0, 'build-webkit': 0, 'build-chromium': 0}), {}, self.inventory, '/original')
        self.assertEqual(sorted(second['build_hashes']), sorted(BINARIES))
        self.assertEqual(second['build_hashes'][webkit[0]], first['build_hashes'][webkit[0]])
        self.assertFalse(self.store.directory(first).exists())

    def test_tampered_webkit_bundle_after_partial_build_discards(self):
        from checkpoint import PRODUCTS
        self.binaries(PRODUCTS['build-webkit'][1])
        record = self.checkpoint(self.result({'unit-AircKit': 0, 'build-webkit': 0}))
        (self.store.directory(record) / 'build' / PRODUCTS['build-webkit'][1][0]).write_text('other')
        self.assertEqual(self.select(), (None, 'pinned build missing or changed'))

    def test_main_distance_limit(self):
        self.checkpoint(self.result({}))
        self.assertIsNotNone(self.select(behind=MAX_BEHIND)[0])
        self.store.preempted(dict(self.result({}), cleanup_exit=0))
        self.assertIn('main moved', self.select(behind=MAX_BEHIND + 1)[1])

    def test_unconfirmed_remote_cleanup_stays_resumable_with_pending_cleanup(self):
        result = self.result({})
        self.store.snapshot(str(self.build) + '/', result, {}, self.inventory, '/original', now=100)
        self.store.preempted(dict(result, cleanup_exit=75), cleanup_pending='arcfork/work/bgsuite-77')
        record, reason = self.select()
        self.assertIsNone(reason)
        self.assertEqual(record['cleanup_pending'], 'arcfork/work/bgsuite-77')

    def test_status_line(self):
        from run import status_line
        line = status_line(dict(state='aborted', revision='c' * 40, last_step='build-chromium', plan=self.plan,
                                steps={'unit-AircKit': 0, 'build-webkit': 0}, cases=[], expected=251, yields=3,
                                last_yield=dict(reason='priority marker while waiting for build lock', at=0)))
        self.assertEqual(line, 'aborted · rev cccccccc · step build-chromium · builds 2/3 · cases 0/251 · '
                               'last yield: priority marker while waiting for build lock (1970-01-01T00:00Z, 3 total)')
        running = status_line(dict(state='running', revision='c' * 40, current_step='webkit/read-1', plan=self.plan,
                                   steps=dict.fromkeys(self.plan, 0), cases=[{}] * 5, expected=251,
                                   waiting_on='buildmac-ui-lock'))
        self.assertEqual(running, 'running · rev cccccccc · step webkit/read-1 · builds 3/3 · cases 5/251 · '
                                  'waiting on buildmac-ui-lock')

    def test_main_distance(self):
        import run
        repo = self.root / 'repo'; repo.mkdir()
        git = ['git', '-C', str(repo)]
        def g(*args):
            return subprocess.run(git + list(args), check=True, capture_output=True, text=True).stdout.strip()
        g('init', '-q'); g('config', 'user.email', 'fixture@example.invalid'); g('config', 'user.name', 'Fixture')
        revs = []
        for i in range(3):
            (repo / 'f').write_text(str(i)); g('add', 'f'); g('commit', '-qm', str(i)); revs.append(g('rev-parse', 'HEAD'))
        self.assertEqual(run.main_distance(git, revs[0], revs[2]), 2)
        g('checkout', '-q', '--orphan', 'other'); g('commit', '-qm', 'rewritten')
        self.assertIsNone(run.main_distance(git, revs[0], g('rev-parse', 'HEAD')))


class StepResumeCoordinatorTest(unittest.TestCase):
    """End to end through run.main(): a yield during the second app build resumes at that build,
    on the pinned revision, after main moved; a main too far ahead starts fresh."""
    def harness(self):
        import json
        import run
        from checkout import OWNER
        from checkpoint import PRODUCTS
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        repo = root / 'repo'; (repo / 'packages/AircKit').mkdir(parents=True)
        real_run, real_output = subprocess.run, subprocess.check_output
        def git(*args):
            return real_run(['git', '-C', str(repo), *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def head():
            return real_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        git('init'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'Fixture')
        (repo / 'packages/AircKit/Package.swift').write_text('// fixture')
        git('add', '.'); git('commit', '-m', 'first')
        first = head()
        (repo / '.git/airc-suite-owner').write_text(OWNER)
        status = root / 'status'; status.mkdir()
        (status / 'buildmac-engine-ready').write_text('engine\n')
        calls = []; yield_at = ['build-chromium']; ssh_down = [False]; cleanups = []
        remote_path = lambda path: root / path
        def execute(args, **kwargs):
            if args[:len(run.SSH)] == run.SSH:
                code = args[-1]
                if ssh_down[0] is True:
                    raise subprocess.TimeoutExpired(args, 30)
                if 'worker cleanup' in code:
                    cleanups.append('remove' if 'shutil.rmtree' in code and 'True' in code else 'wait')
                if 'mkdir -p' in code:
                    remote_path(code.split('mkdir -p ', 1)[1]).mkdir(parents=True, exist_ok=True)
                elif 'shutil.rmtree' in code and 'True' in code:
                    import shutil
                    for export in (root / 'arcfork/work').glob('bgsuite-*'):
                        shutil.rmtree(export)
                return subprocess.CompletedProcess(args, 0)
            if args[0] == 'bash':
                return subprocess.CompletedProcess(args, 0)
            if args[0] == 'rsync':
                args = [str(remote_path(x[len('buildmac:'):])) + '/' if x.startswith('buildmac:') else x for x in args]
            return real_run(args, **kwargs)
        def output(args, **kwargs):
            if args[:len(run.SSH)] == run.SSH:
                return str(remote_path(args[-1].split()[1])) + '\n'
            return real_output(args, **kwargs)
        def inventory(source):
            (source / 'build/snapshot-home').mkdir(parents=True)
            return [dict(engine='webkit', script='read', command=['fixture', str(source)])]
        def worker(remote, job, log, status, marker, progress):
            command = job['command']
            name = ('build-' + command[-1]) if job['kind'] == 'build' and command[0] == 'bash' else \
                   ('unit-AircKit' if job['kind'] == 'build' else 'ui')
            calls.append(name)
            log.write_text('worker finished\n')
            if name in yield_at:
                yield_at.remove(name)
                raise run.Preempted('priority marker while waiting for build lock')
            if name == 'build-' + str(ssh_down[0]):   # buildmac drops mid-step
                ssh_down[0] = True
                raise subprocess.TimeoutExpired(['ssh'], 30)
            build = remote_path(remote) / 'build'
            for binary in PRODUCTS.get(name, (None, ()))[1]:
                p = build / binary; p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('executable ' + name); p.chmod(0o755)
            if name == 'ui':
                # Both bundles came back from the checkpoint into the fresh export.
                self.assertTrue((build / 'Airc.app/Contents/MacOS/Airc').exists())
                self.assertTrue((build / 'Airc-Chromium.app/Contents/MacOS/Airc').exists())
                out = Path(job['snapshot_evidence']); out.mkdir(parents=True, exist_ok=True)
                (out / 'log.txt').write_text('PASS completed\n')
                (out / 'ui-gate.json').write_text(json.dumps(dict(state='PASS', launches=[dict(state='PASS')])))
            return 0
        def invoke(revision):
            with patch.object(run, '__file__', str(repo / 'infra/suite/run.py')), patch.object(run, 'order_ready', return_value=True), \
                 patch.object(run, 'runner_identity', return_value=('stable-runner', {})), patch.object(run, 'inventory', side_effect=inventory), \
                 patch.object(run, 'worker', side_effect=worker), patch('subprocess.run', side_effect=execute), \
                 patch('subprocess.check_output', side_effect=output), patch('sys.argv', ['run.py', '--repo', str(repo), '--revision', revision,
                     '--status', str(status), '--queue', str(root / 'queue')]):
                return run.main()
        return dict(invoke=invoke, first=first, git=git, head=head, repo=repo, status=status, calls=calls,
                    yield_at=yield_at, ssh_down=ssh_down, cleanups=cleanups)

    def test_yield_mid_build_resumes_at_that_step_on_pinned_revision(self):
        import json
        h = self.harness()
        invoke, first, git, head, repo, status, calls, yield_at = (h[k] for k in (
            'invoke', 'first', 'git', 'head', 'repo', 'status', 'calls', 'yield_at'))
        self.assertEqual(invoke(first), 75)
        store = Checkpoints(status / 'suite')
        self.assertEqual(store.read()['result']['steps'], {'unit-AircKit': 0, 'build-webkit': 0})
        latest = json.loads((status / 'suite/latest.json').read_text())
        self.assertIn('step build-chromium · builds 2/3 · cases 0/1 · last yield: priority marker', latest['status_line'])
        (repo / 'f').write_text('new main'); git('add', 'f'); git('commit', '-m', 'main moved')
        newest = head()
        self.assertEqual(invoke(newest), 0)
        self.assertEqual(calls, ['unit-AircKit', 'build-webkit', 'build-chromium', 'build-chromium', 'ui'])
        latest = json.loads((status / 'suite/latest.json').read_text())
        self.assertEqual((latest['revision'], latest['current_main'], latest['commits_behind_main']), (first, newest, 1))
        self.assertEqual((latest['state'], latest['yields']), ('complete', 1))
        self.assertTrue(latest['qualified'])
        # A checkpoint too far behind main is dropped: the next run starts fresh on main.
        calls.clear(); yield_at.append('build-webkit')
        self.assertEqual(invoke(newest), 75)
        (repo / 'f').write_text('newer'); git('commit', '-am', 'newer')
        with patch('checkpoint.MAX_BEHIND', 0):
            self.assertEqual(invoke(head()), 0)
        latest = json.loads((status / 'suite/latest.json').read_text())
        self.assertEqual(latest['revision'], head())
        self.assertIn('main moved 1 commits', latest['checkpoint_discarded'])
        self.assertEqual(calls, ['unit-AircKit', 'build-webkit', 'unit-AircKit', 'build-webkit', 'build-chromium', 'ui'])


    def test_buildmac_drop_with_unconfirmed_cleanup_resumes_after_cleanup(self):
        import json
        h = self.harness()
        h['yield_at'].clear()
        h['ssh_down'][0] = 'webkit'   # SSH times out during build-webkit and stays down for cleanup
        self.assertEqual(h['invoke'](h['first']), 75)
        latest = json.loads((h['status'] / 'suite/latest.json').read_text())
        self.assertEqual((latest['state'], latest['cleanup_exit'], latest['transient_errors']), ('aborted', 75, 2))
        self.assertIn('last yield: transient', latest['status_line'])
        record = Checkpoints(h['status'] / 'suite').read()
        self.assertTrue(record['clean_preemption'])
        self.assertTrue(record['cleanup_pending'].startswith('arcfork/work/bgsuite-'))
        self.assertEqual(record['result']['steps'], {'unit-AircKit': 0})
        h['ssh_down'][0] = False; h['cleanups'].clear()
        self.assertEqual(h['invoke'](h['first']), 0)
        self.assertEqual(h['cleanups'][0], 'remove')   # pending cleanup runs before the new export
        self.assertEqual(h['calls'], ['unit-AircKit', 'build-webkit', 'build-webkit', 'build-chromium', 'ui'])
        self.assertEqual(json.loads((h['status'] / 'suite/latest.json').read_text())['state'], 'complete')


class PanelTest(unittest.TestCase):
    def test_status_page_shows_status_line(self):
        import json
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        from suite_status import panel
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'suite').mkdir()
            (Path(d) / 'suite/latest.json').write_text(json.dumps(dict(state='aborted', status_line='aborted · cases 3/251 <x>')))
            self.assertIn('<code>aborted · cases 3/251 &lt;x&gt;</code>', panel(d))
