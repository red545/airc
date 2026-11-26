#!/usr/bin/env python3
"""Dedicated-host worker. A lost coordinator lease stops our exact child and app."""
import fcntl
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import signal
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ui_gate as gate
from processes import Descendants
from shutdown import ShutdownObservation
from priority import admit


class SnapshotEvidence:
    """Keep canonical cross-launch fixtures, but archive only this case's output."""
    def __init__(self, snapshot, evidence):
        self.snapshot, self.evidence = Path(snapshot), Path(evidence)
        self.snapshot.mkdir(parents=True, exist_ok=True)
        self.before = self.manifest()
        log = self.snapshot / 'log.txt'
        self.log_before = log.read_bytes() if log.exists() else b''

    def manifest(self):
        return {p.relative_to(self.snapshot): (p.stat().st_mtime_ns, p.stat().st_size)
                for p in self.snapshot.rglob('*') if p.is_file()}

    def archive(self):
        self.evidence.mkdir(parents=True, exist_ok=True)
        for name, stamp in self.manifest().items():
            if str(name) == 'log.txt' or self.before.get(name) == stamp:
                continue
            target = self.evidence / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.snapshot / name, target)
        log = self.snapshot / 'log.txt'
        if log.exists():
            after = log.read_bytes()
            new = after[len(self.log_before):] if after.startswith(self.log_before) else after
            (self.evidence / 'log.txt').write_bytes(new)


def acquire(lock, lease, patience=None):
    """Lowest priority, bounded starvation (priority.admit); the lease is renewed while waiting."""
    lease()
    try:
        admit(lock, lease, patience=patience)
    except (InterruptedError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('@@YIELD@@ ' + str(error), flush=True)
        raise InterruptedError(str(error)) from error
    lease()


def main():
    def interrupted(*_):
        raise InterruptedError('worker signal')
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    job = json.loads(Path(sys.argv[1]).read_text())
    command = job['command']
    ui = job['kind'] == 'ui'
    lockpath = Path.home() / 'arcfork' / ('.ui-check.lock' if ui else '.agent-build.lock')
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin, selectors.EVENT_READ)
    deadline = time.monotonic() + 15
    pending = bytearray()
    def line(timeout=0):
        if b'\n' not in pending and selector.select(timeout):
            chunk = os.read(sys.stdin.fileno(), 4096)
            if not chunk:
                raise InterruptedError('coordinator EOF')
            pending.extend(chunk)
        if b'\n' not in pending:
            return None
        value, _, rest = pending.partition(b'\n')
        pending[:] = rest
        return value.decode().strip()
    def lease():
        nonlocal deadline
        reply = line()
        while reply is not None:
            if reply != 'RUN':
                raise InterruptedError('coordinator cancelled')
            deadline = time.monotonic() + 15
            reply = line()
        if time.monotonic() > deadline:
            raise InterruptedError('coordinator lease expired')
    process = None
    descendants = None
    executable = None
    previous = set()
    evidence = {}
    snapshot_evidence = None
    shutdown_observation = None
    with lockpath.open('a+') as lock:
        try:
            # UI cases are about a minute each: yield to queued agents for 5 min, builds for the default 20.
            acquire(lock, lease, 300 if ui else None)
            # Require a fresh authorization after acquisition, never a queued heartbeat.
            while pending or selector.select(0):
                lease()
            print('@@LOCKED@@', flush=True)
            while True:
                reply = line(15)
                if reply is None:
                    raise InterruptedError('post-lock timeout')
                if reply == 'ACK':
                    break
                if reply != 'RUN':
                    raise InterruptedError('post-lock refusal')
            deadline = time.monotonic() + 15
            if ui:
                snapshot = Path(command[command.index('--snapshot') + 1])
                if job.get('snapshot_evidence'):
                    snapshot_evidence = SnapshotEvidence(snapshot, job['snapshot_evidence'])
                    shutdown_observation = ShutdownObservation(snapshot, job['snapshot_evidence'])
                    command[1:1] = ['--stdout', str(shutdown_observation.evidence / 'app.stdout'),
                                    '--stderr', str(shutdown_observation.stderr)]
                script = command[command.index('--script') + 1]
                executable = gate.bundle_executable(command)
                previous = gate.matching_app_pids(executable, snapshot, script)
                for i, arg in enumerate(command):
                    if arg.startswith('--remote-debugging-port='):
                        with socket.socket() as probe:
                            probe.bind(('127.0.0.1', 0))
                            command[i] = '--remote-debugging-port=' + str(probe.getsockname()[1])
                command = [x for x in command if x != '-g']
                command[1:1] = ['--env', 'AIRC_MEDIA_PROMPT_CHECKS=0', '--env', 'AIRC_UI_DEDICATED_SESSION=1', '--env', 'AIRC_LA_AS_OWNER=1']
                import runpy
                runpy.run_path('scripts/ui-session-preflight.py')['prepare']()
                if gate.preflight(Path(job['receipt'])):
                    return 75
                command = [sys.executable, 'infra/ui_gate.py', 'launch', job['receipt'], *command]
            elif shutil.disk_usage(Path.home()).free < 15 * 1024**3:
                return 75
            env = dict(os.environ, AIRC_BUILD_LOCK_FD=str(lock.fileno()), AIRC_SHIP_GATE='1',
                       AIRC_UI_DEDICATED_SESSION='1', AIRC_LA_AS_OWNER='1', AIRC_SOURCE_REV=job['revision'], AIRC_MEDIA_PROMPT_CHECKS='0', AIRC_SIGN_IDENTITY='-')
            if not ui and sys.platform == 'darwin':
                env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
                env['SDKROOT'] = subprocess.check_output(
                    ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True, timeout=15).strip()
                print('Build SDK: ' + env['SDKROOT'], flush=True)
            if sys.platform == 'darwin':
                command = ['caffeinate', *(['-d'] if ui else []), '-i', '-s', *command]
            lease()
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, env=env,
                                       start_new_session=True, pass_fds=(lock.fileno(),))
            descendants = Descendants(process.pid)
            started = time.monotonic()
            next_sample = started
            while process.poll() is None:
                if shutdown_observation is not None:
                    shutdown_observation.sample()
                if time.monotonic() >= next_sample:
                    descendants.sample()
                    next_sample = time.monotonic() + 1
                lease()
                if time.monotonic() - started > (760 if ui else 1800):
                    raise TimeoutError('worker hard deadline')
                time.sleep(.2)
            rc = process.returncode
            if ui and script == 'redirects' and rc == 0:
                original = job['command']
                profile = original[original.index('--data-dir') + 1]
                with (snapshot / 'log.txt').open('a') as out:
                    rc = subprocess.call([sys.executable, 'scripts/check-redirect-history.py', profile,
                                          str(snapshot / 'redirect-evidence.json')], stdout=out, stderr=out)
                if rc:
                    receipt = json.loads(Path(job['receipt']).read_text())
                    receipt['state'] = 'FAIL'
                    gate.save(Path(job['receipt']), receipt)
            return rc
        finally:
            try:
                # Launch Services apps are not children of open. Stop only this exact launch.
                if executable:
                    gate.stop_owned_app(executable, snapshot, script, previous, evidence)
                    gate.save(Path(job['receipt']).with_suffix('.cleanup.json'), evidence)
                    if evidence.get('samples'):
                        with (snapshot / 'log.txt').open('a') as out:
                            out.write('\nFAIL [independent] still alive after launcher; forced cleanup\n')
            finally:
                if descendants is not None:
                    descendants.stop()
                if process is not None:
                    process.wait(timeout=5)
            if snapshot_evidence is not None:
                # The app and descendants are gone; let the next agent run
                # while we copy this case's private evidence.
                fcntl.flock(lock, fcntl.LOCK_UN)
                snapshot_evidence.archive()
            if shutdown_observation is not None:
                shutdown_observation.sample()
            Path(sys.argv[1]).resolve().with_name('.worker-done').write_text('clean\n')

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (InterruptedError, TimeoutError) as error:
        print(str(error), flush=True)
        sys.exit(75)
