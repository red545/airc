#!/usr/bin/env python3
"""Low-priority background qualification of an immutable origin/main export."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from inventory import inventory
from checkpoint import Checkpoints, runner_identity, case_ids
from shutdown import apply_policy, gate_inputs
from priority import admit, deferred, progressed

HOLD = ('release-staging', 'quiet-pending', 'relink-pending', 'priority-build')
CRITICAL = re.compile(r'\b(?:crash(?:ed|es|ing)?|died|hung|hang(?:s|ing)?|still alive|watchdog|no PID|never started|wrote no log|hard timeout)\b', re.I)
TRANSIENT_LIMIT = 5   # SSH/rsync failures per campaign that still resume (buildmac offline, network)
SSH = ['ssh', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3', 'buildmac']


class Preempted(Exception):
    """Cancellation must escape selectors' special InterruptedError handling."""


def stop(*_):
    raise Preempted('scheduler stopped')


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)


def order_ready(queue):
    text = queue.read_text()
    # Completion notices, never a plan saying these words. Scope to post-0.1.5 handoff.
    text = text[text.index('release016: 0.1.5 LIVE'):]
    heading = r'(?mi)^(?:#{1,3}\s+)?(?:\d{4}-\d{2}-\d{2}[^\n]*?\s+)?'
    closed = re.search(heading + r'histsugg\b[^\n]*(?:QUIET CLOSED|quiet done)', text)
    if not closed:
        return False
    after = text[closed.end():]
    first = re.search(heading + r'touchpasskeys\b[^\n]*(?:DONE.*REBUILD|REBUILD.*DONE|REBUILD NOTICE)', after)
    return bool(first and re.search(heading + r'ytads\b[^\n]*(?:DONE.*REBUILD|REBUILD.*DONE|REBUILD NOTICE)', after[first.end():]))


def blocked(status, marker=None):
    return any((status / x).exists() for x in HOLD) or (marker is not None and
        (not (status / 'buildmac-engine-ready').exists() or (status / 'buildmac-engine-ready').read_text() != marker))


@contextmanager
def build_lock(status):
    with (status / '.agent-build.lock').open('a') as lock:
        try:
            if blocked(status):
                raise InterruptedError('priority before build lock')
            def tick():
                if blocked(status):
                    raise InterruptedError('priority marker while waiting for build lock')
            admit(lock, tick)
            if blocked(status):
                raise InterruptedError('priority changed after build lock')
            progressed(status)   # admitted: the starvation clock restarts
        except InterruptedError as error:
            deferred(status, str(error))
            raise Preempted(str(error)) from error
        yield


def worker(remote, job, log, status, marker, progress=lambda waiting_on: None):
    progress('buildmac-setup')
    payload = json.dumps(job)
    setup = 'from pathlib import Path; import sys; p=Path(' + repr(remote) + '); (p/".worker-done").unlink(missing_ok=True); (p/"job.json").write_text(sys.stdin.read())'
    subprocess.run(SSH + ['python3 -c ' + shlex.quote(setup)], input=payload, text=True, check=True, timeout=30)
    progress('buildmac-ui-lock' if job['kind'] == 'ui' else 'buildmac-build-lock')
    process = subprocess.Popen(SSH + [f'cd {remote} && python3 infra/suite/remote.py job.json'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    cancelled = False
    yielded = None
    buffered = b''
    heartbeat_at = 0.0
    with log.open('w') as out:
        try:
            while process.poll() is None:
                cancelled |= blocked(status, marker)
                if cancelled or time.monotonic() >= heartbeat_at:
                    try:
                        process.stdin.write(b'STOP\n' if cancelled else b'RUN\n')
                        process.stdin.flush()
                    except BrokenPipeError:
                        pass
                    heartbeat_at = time.monotonic() + 1
                for key, _ in selector.select(1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    out.write(chunk.decode(errors='replace')); out.flush()
                    buffered += chunk
                    while b'\n' in buffered:
                        line, _, buffered = buffered.partition(b'\n')
                        if line.startswith(b'@@YIELD@@'):
                            yielded = line.decode(errors='replace')
                        if line.startswith(b'@@LOCKED@@'):
                            cancelled |= blocked(status, marker)
                            try:
                                process.stdin.write(b'STOP\n' if cancelled else b'ACK\n'); process.stdin.flush()
                                progress('coordination-marker' if cancelled else None)
                            except BrokenPipeError:
                                pass
            tail = process.stdout.read().decode(errors='replace')
            out.write(tail)
            remainder = buffered.decode(errors='replace') + tail
            if '@@YIELD@@' in remainder:
                yielded = remainder[remainder.index('@@YIELD@@'):].splitlines()[0]
        finally:
            process.stdin.close()  # EOF revokes remote lease even on interruption.
            try:
                process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(timeout=10)
    progress('buildmac-cleanup')
    subprocess.run(SSH + ['python3 -c ' + shlex.quote(cleanup_code(remote))], check=True, timeout=60)
    if yielded or cancelled:
        reason = yielded or 'yielded to coordination marker'
        deferred(status, reason)
        raise Preempted(reason)
    return process.returncode



def cleanup_code(remote, remove=False):
    if not re.fullmatch(r'arcfork/work/bgsuite-[0-9]+', remote):
        raise ValueError('not an owned suite export')
    return """from pathlib import Path
import shutil,time
p=Path(%r)
deadline=time.monotonic()+45
while p.exists() and (p/'job.json').exists() and not (p/'.worker-done').exists():
 if time.monotonic()>deadline: raise RuntimeError('worker cleanup was not acknowledged')
 time.sleep(.2)
if %r and p.exists():
 shutil.rmtree(p)
 assert not p.exists(), 'owned export survived cleanup'
""" % (remote, remove)


def summarize(result, previous):
    apply_policy(result)
    reds = []
    counts = {}
    for engine in ('webkit', 'chromium'):
        cases = [c for c in result['cases'] if c['engine'] == engine]
        counts[engine] = {state: sum(c['state'] == state for c in cases) for state in ('PASS', 'FAIL', 'ENV')}
        for case in cases:
            if case['state'] != 'PASS':
                reds.append(case['id'])
    result['counts'] = counts
    result['reds'] = reds
    result['new_reds'] = sorted(set(reds) - set(previous.get('reds', [])))
    # Starting or aborting a newer attempt cannot hide an unresolved crash.
    # Only a passing rerun of that exact case clears its warning.
    unresolved = set(previous.get('critical', []))
    for case in result['cases']:
        if case.get('critical'):
            unresolved.add(case['id'])
        elif case['state'] == 'PASS':
            unresolved.discard(case['id'])
    result['critical'] = sorted(unresolved)
    # Fail closed: no implicit approvals, skipped/ENV/partial runs cannot qualify.
    result['qualified'] = (result['state'] == 'complete' and not result['dry_run'] and not reds and not unresolved
                           and result.get('cleanup_exit') == 0
                           and all(c.get('gate_worker_exit', c.get('worker_exit')) == 0 for c in result['cases'])
                           and len(result['cases']) == result['expected'] and all(x == 0 for x in result['steps'].values()))
    return result


def status_line(result):
    """One line for latest.json and the status page: where the run is and why it last stopped."""
    running = result.get('state') == 'running'
    step = result.get('current_step') if running else result.get('last_step', result.get('current_step'))
    plan = result.get('plan') or []
    rev = f"rev {str(result.get('revision', '?'))[:8]}"
    if result.get('commits_behind_main'):
        rev += f" (pinned, main +{result['commits_behind_main']})"
    parts = [str(result.get('state', '?')), rev, f'step {step}']
    if plan:
        parts.append(f"builds {len(result.get('steps', {}))}/{len(plan)}")
    parts.append(f"cases {len(result.get('cases', []))}/{result.get('expected', 0)}")
    if running and result.get('waiting_on'):
        parts.append('waiting on ' + str(result['waiting_on']))
    last = result.get('last_yield')
    if last:
        when = time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(last['at']))
        parts.append(f"last yield: {last['reason']} ({when}, {result.get('yields', 1)} total)")
    return ' · '.join(parts)


def main_distance(git, pinned, main):
    """Commits main is ahead of the pinned revision; None if it is no longer an ancestor."""
    if subprocess.run(git + ['merge-base', '--is-ancestor', pinned, main],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        return None
    return int(subprocess.check_output(git + ['rev-list', '--count', f'{pinned}..{main}'], text=True))


def critical_failure(text, receipt):
    # Names/paths such as "crashreports" and ordinary assertions containing
    # "changed" are not evidence that an app crashed or hung.
    failures = [line for line in text.splitlines() if line.startswith(('FAIL ', 'FAIL-ENV ', 'ENGINE-FAIL '))]
    for launch in receipt.get('launches', []):
        if launch.get('watchdog') is not None:
            return True
        failures.extend(failure.get('message', '') for failure in launch.get('failures', []))
    return bool(CRITICAL.search('\n'.join(failures)))


def case_outcome(text, receipt, worker_exit, worker_text=''):
    critical = critical_failure(text, receipt) or 'worker hard deadline' in worker_text.splitlines()
    raw_failure = any(line.startswith(('FAIL ', 'FAIL-ENV ', 'ENGINE-FAIL ')) for line in text.splitlines())
    if raw_failure or worker_exit not in (0, 75) or critical or receipt.get('state') == 'FAIL':
        return 'FAIL', critical
    # A successful preflight is not a completed launch. In particular, a
    # refused worker or an outer deadline can leave that initial PASS behind.
    if worker_exit == 75 or not receipt.get('launches') or not text.strip():
        return 'ENV', critical
    state = receipt.get('state', 'ENV')
    return (state if state in ('PASS', 'FAIL') else 'ENV'), critical


def main():
    signal.signal(signal.SIGTERM, stop)
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', type=Path, required=True)
    ap.add_argument('--revision', required=True)
    ap.add_argument('--status', type=Path, required=True)
    ap.add_argument('--queue', type=Path, required=True)
    ap.add_argument('--dry-run', action='store_true', help='Run first three inventory cases per engine; never qualify')
    a = ap.parse_args()
    from checkout import OWNER
    if a.repo.resolve() != Path(__file__).resolve().parents[2] or (a.repo / '.git/airc-suite-owner').read_text() != OWNER:
        ap.error('run.py must execute from its exclusively owned checkout')
    a.status.mkdir(parents=True, exist_ok=True)
    with (a.status / '.bgsuite.lock').open('a') as singleton:
        try:
            fcntl.flock(singleton, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 75
        try:
            if blocked(a.status) or not order_ready(a.queue):
                print('held: post-release order or priority markers'); return 75
        except (ValueError, FileNotFoundError):
            return 75
        git = ['git', '-C', str(a.repo)]
        rev = subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()
        if rev != a.revision:
            raise RuntimeError('owned checkout moved after scheduler pin')
        marker = (a.status / 'buildmac-engine-ready').read_text()
        suite = a.status / 'suite'
        latest = suite / 'latest.json'
        previous = json.loads(latest.read_text()) if latest.exists() else {}
        checkpoints = Checkpoints(suite)
        runner_sha, runner_files = runner_identity(a.repo)
        current_main = rev
        resumed = discarded = None
        if not a.dry_run and checkpoints.read():
            pinned = (checkpoints.read().get('result') or {}).get('revision', '')
            behind = (main_distance(git, pinned, current_main)
                      if re.fullmatch(r'[0-9a-f]{40}', str(pinned)) else None)
            resumed, discarded = checkpoints.select(marker, runner_sha, behind=behind)
        if resumed:
            rev = resumed['result']['revision']
            # The owned clone fetches main first; a valid checkpoint alone pins
            # the source/build/inventory to its earlier revision.
            subprocess.run(git + ['cat-file', '-e', rev + '^{commit}'], check=True)
            previous = resumed['previous']
            result = dict(resumed['result'])
            result.update(state='running', resumed_after_preemption=True,
                          resume_label='resumed after preemption',
                          resume_count=result.get('resume_count', 0) + 1,
                          current_main=current_main,
                          commits_behind_main=main_distance(git, rev, current_main))
            result.pop('ended', None)
            result.pop('cleanup_exit', None)
            result.pop('reason', None)
            attempt = result['logs']
            checkpoints.activate(resumed)
        else:
            attempt = str(time.time_ns())
            result = dict(revision=rev, started=time.time(), state='running', dry_run=a.dry_run,
                          expected=0, cases=[], steps={}, engine_marker=marker, logs=attempt,
                          current_step='source-export', waiting_on=None, step_started=time.time(), waiting_since=None,
                          runner_sha=runner_sha, runner_sha256=runner_files, plan=[], yields=0)
            if discarded:
                result['checkpoint_discarded'] = discarded
        subprocess.run(['bash', '-c', 'source "$1/infra/engine-inputs.sh"; engine_inputs_diff "$1" "$2" "$3"',
                        'engine-check', str(a.repo), marker.split()[0], rev], check=True)
        dest = suite / rev
        logs = dest / attempt
        logs.mkdir(parents=True, exist_ok=True)
        segment = logs / 'segments' / str(time.time_ns())
        segment.mkdir(parents=True)
        remote = 'arcfork/work/bgsuite-' + attempt
        source = Path(tempfile.mkdtemp(prefix='bgsuite-', dir=a.status))
        def publish():
            result['updated_at'] = time.time()
            summarize(result, previous)
            result['status_line'] = status_line(result)
            save(logs / 'summary.json', result)
            save(dest / 'summary.json', result)
            save(latest, result)
            if result['qualified']:
                save(suite / 'qualified.json', result)
                save(suite / 'last-green.json', result)
        def progress(step, waiting_on=None):
            if result['current_step'] != step:
                result['step_started'] = time.time()
            if result['current_step'] != step or result['waiting_on'] != waiting_on:
                result['waiting_since'] = time.time() if waiting_on else None
            result.update(current_step=step, waiting_on=waiting_on)
            publish()
        try:
            if resumed and resumed.get('cleanup_pending'):
                # The last attempt could not confirm its Mac worker stopped. Finish that
                # cleanup first; while it still fails this is a bounded transient yield.
                progress('source-export', 'buildmac-cleanup')
                subprocess.run(SSH + ['python3 -c ' + shlex.quote(cleanup_code(resumed['cleanup_pending'], remove=True))],
                               check=True, timeout=60)
            archive = subprocess.Popen(git + ['archive', rev], stdout=subprocess.PIPE)
            subprocess.run(['tar', '-x', '-C', str(source)], stdin=archive.stdout, check=True)
            archive.stdout.close()
            if archive.wait():
                raise RuntimeError('archive failed')
            cases = resumed['inventory'] if resumed else inventory(source)
            inventory_source = resumed['inventory_source'] if resumed else str(source)
            if a.dry_run:
                cases = [c for engine in ('webkit', 'chromium') for c in [x for x in cases if x['engine'] == engine][:3]]
            result['expected'] = len(cases)
            save(logs / 'inventory.json', cases)
            publish()
            steps = [(f'unit-{p.parent.name}', ['swift', 'test', '--package-path', str(p.parent.relative_to(source))])
                     for p in sorted((source / 'packages').glob('*/Package.swift'))]
            steps += [(f'build-{e}', ['bash', 'scripts/build-app.sh', '--no-test', '--engine', e]) for e in ('webkit', 'chromium')]
            if resumed and result['plan'] != [name for name, _ in steps]:
                raise RuntimeError('pinned build plan differs from its checkpoint')
            result['plan'] = [name for name, _ in steps]
            if blocked(a.status, marker):
                raise InterruptedError('held before export')
            progress('source-export', 'buildmac-transfer')
            # Never overwrite a surviving export from an unacknowledged worker.
            subprocess.run(SSH + [f'test ! -e {remote} && mkdir -p {remote}'], check=True, timeout=30)
            subprocess.run(['rsync', '-az', '--exclude=/build/', str(source) + '/', 'buildmac:' + remote + '/'], check=True, timeout=180)
            remote_root = subprocess.check_output(SSH + [f'cd {remote} && pwd'], text=True, timeout=30).strip()
            subprocess.run(SSH + [f'mkdir -p {remote}/build/snapshot-home'], check=True, timeout=30)
            restore = checkpoints.directory(resumed) / 'build' if resumed else source / 'build/snapshot-home'
            restore_target = remote + '/build/' if resumed else remote + '/build/snapshot-home/'
            # A checkpoint can carry both app bundles (~0.6 GB).
            subprocess.run(['rsync', '-az', str(restore) + '/', 'buildmac:' + restore_target], check=True, timeout=1800)
            def checkpoint(step):
                # Every finished step or case is a resume point, keyed by the pinned
                # revision, engine marker and runner (checkpoint.select guards them).
                if not a.dry_run:
                    progress(step, 'checkpoint-copy')
                    checkpoints.snapshot('buildmac:' + remote + '/build/', result, previous, cases, inventory_source)
            if not resumed:
                checkpoint('source-export')   # pins revision + inventory before any build
            for name, command in steps:
                if name in result['steps']:
                    continue   # done before a yield; its products came back from the checkpoint
                if blocked(a.status, marker):
                    raise InterruptedError('held before build')
                progress(name, 'linux-build-lock')
                with build_lock(a.status):
                    rc = worker(remote, dict(kind='build', command=command, revision=rev), logs / (name + '.log'), a.status, marker,
                                lambda waiting_on: progress(name, waiting_on))
                result['steps'][name] = rc
                publish()
                if rc:
                    raise RuntimeError(name + ' failed')
                checkpoint(name)
            completed = len(result['cases'])
            for i, (case, caseid) in enumerate(zip(cases, case_ids(cases))):
                if i < completed:
                    continue
                if blocked(a.status, marker):
                    raise InterruptedError('held before case')
                # Preserve evidence from an interrupted launch before rerunning it.
                for old in (logs / f'case-{i:03}.log', logs / caseid):
                    if old.exists():
                        archived = segment / 'interrupted' / old.relative_to(logs)
                        archived.parent.mkdir(parents=True, exist_ok=True)
                        old.rename(archived)
                progress(caseid, 'buildmac-setup')
                out = remote_root + '/evidence/' + caseid
                command = [s.replace(inventory_source, remote_root) for s in case['command']]
                # Canonical write/read scenarios exchange fixtures in --snapshot.
                # Keep that shared directory; the worker archives each case's delta.
                subprocess.run(SSH + ['mkdir -p ' + shlex.quote(out)], check=True, timeout=30)
                rc = worker(remote, dict(kind='ui', command=command, revision=rev,
                            snapshot_evidence=out, receipt=out + '/ui-gate.json'),
                            logs / f'case-{i:03}.log', a.status, marker,
                            lambda waiting_on: progress(caseid, waiting_on))
                progress(caseid, 'evidence-copy')
                local = logs / caseid
                local.mkdir(parents=True)
                subprocess.run(['rsync', '-az', 'buildmac:' + out + '/', str(local) + '/'], check=True, timeout=90)
                receipt = json.loads((local / 'ui-gate.json').read_text()) if (local / 'ui-gate.json').exists() else {}
                text = (local / 'log.txt').read_text(errors='replace') if (local / 'log.txt').exists() else ''
                worker_text = (logs / f'case-{i:03}.log').read_text(errors='replace')
                observation = local / 'shutdown.json'
                events = json.loads(observation.read_text())['events'] if observation.exists() else []
                policy_receipt, policy_rc = gate_inputs(receipt, rc, events, case['engine'])
                state, critical = case_outcome(text, policy_receipt, policy_rc, worker_text)
                assertions = {kind: sum(line.startswith(kind + ' ') for line in text.splitlines()) for kind in ('PASS', 'FAIL', 'FAIL-ENV', 'ENGINE-PASS', 'ENGINE-FAIL', 'SKIP')}
                finished = dict(assertions=assertions, id=caseid, engine=case['engine'], script=case['script'],
                                state=state, critical=critical, worker_exit=rc, gate_worker_exit=policy_rc,
                                shutdown_events=events)
                if not a.dry_run:
                    progress(caseid, 'checkpoint-copy')
                    candidate = dict(result, cases=[*result['cases'], finished])
                    apply_policy(candidate)
                    checkpoints.snapshot('buildmac:' + remote + '/build/', candidate, previous, cases, inventory_source)
                progressed(a.status)
                result['cases'].append(finished)
                publish()
                # A case-level environment refusal remains red but must not
                # discard the remaining inventory. Coordination cancellation
                # raises from worker() and still aborts the entire attempt.
            result['state'] = 'complete'
        except (Preempted, InterruptedError, BlockingIOError) as error:
            result.update(state='aborted', reason=str(error))
            result['yields'] = result.get('yields', 0) + 1
            result['last_yield'] = dict(reason=str(error), at=time.time(), step=result['current_step'])
        except subprocess.SubprocessError as error:
            # buildmac asleep or the network dropped: resume from the checkpoint
            # (bounded, so a deterministic transfer failure still ends as an error).
            result['transient_errors'] = result.get('transient_errors', 0) + 1
            if result['transient_errors'] > TRANSIENT_LIMIT:
                result.update(state='error', reason=str(error))
            else:
                result.update(state='aborted', reason='transient: ' + str(error)[:300])
                result['yields'] = result.get('yields', 0) + 1
                result['last_yield'] = dict(reason=result['reason'], at=time.time(), step=result['current_step'])
        except Exception as error:
            result.update(state='error', reason=str(error))
        finally:
            result['last_step'] = result['current_step']
            try:
                progress('cleanup', 'buildmac-cleanup')
            except OSError:
                pass  # Receipt storage failure must never prevent remote cleanup.
            try:
                # A disconnected SSH process can exit before its Mac descendants stop.
                # Wait for exact-PID cleanup acknowledgement before collecting/removing.
                subprocess.run(SSH + ['python3 -c ' + shlex.quote(cleanup_code(remote))], check=True, timeout=60)
                subprocess.run(['rsync', '-az', 'buildmac:' + remote + '/evidence/', str(segment / 'remote-evidence') + '/'], timeout=90)
                subprocess.run(SSH + ['python3 -c ' + shlex.quote(cleanup_code(remote, remove=True))], check=True, timeout=60)
                result['cleanup_exit'] = 0
            except (subprocess.SubprocessError, OSError) as error:
                result.update(cleanup_exit=75, cleanup_error=str(error))
                result['transient_errors'] = result.get('transient_errors', 0) + 1
                # A yielded run whose Mac side could not be confirmed stopped stays
                # resumable: the next attempt finishes this cleanup before it exports.
                if result['state'] != 'aborted' or result['transient_errors'] > TRANSIENT_LIMIT:
                    result['state'] = 'error'
            shutil.rmtree(source)
            result['ended'] = time.time()
            result.update(current_step=result['state'], waiting_on=None, waiting_since=None)
            publish()
            save(segment / 'summary.json', result)
            if not a.dry_run:
                if result['state'] == 'aborted':
                    checkpoints.preempted(result, cleanup_pending=remote if result['cleanup_exit'] else None)
                elif result['state'] == 'complete':
                    checkpoints.complete(attempt)
        return 0 if result['state'] == 'complete' else 75

if __name__ == '__main__':
    sys.exit(main())
