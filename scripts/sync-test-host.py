#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Bounded launch/cleanup for the isolated sync test. Never selects processes by app name."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path.home() / 'arcfork/work/synctest'
APP = ROOT / 'Airc-SyncTest.app'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def own_pids():
    lines = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    # Match the executable prefix, not a shell/SSH command mentioning our path.
    prefixes = (str(APP) + '/Contents/',)
    return [int(p) for line in lines if len(parts := line.strip().split(None, 1)) == 2
            for p, command in [parts] if command.startswith(prefixes)]


def stop_own():
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in own_pids():
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(2)
    if own_pids():
        raise RuntimeError('Own test processes remain')


def window_check(deadline):
    if os.environ.get('SYNC_TEST_LAPTOP') == '1':
        now = dt.datetime.now(dt.timezone.utc)
        start = dt.datetime(2026, 11, 10, 1, 30, tzinfo=dt.timezone.utc)
        end = dt.datetime(2026, 11, 10, 3, 30, tzinfo=dt.timezone.utc)
        if not start <= now < end or deadline > end.timestamp() - 60:
            raise RuntimeError('Outside owner laptop window')


def launch(role, zone, deadline, launch_id="", mode="test"):
    if mode not in ("test", "cleanup"):
        raise ValueError("Invalid mode")
    if launch_id and not re.fullmatch(r"[a-f0-9]{32}", launch_id):
        raise ValueError("Invalid launch identifier")
    if not re.fullmatch(r'[A-Z][A-Za-z0-9-]*', role) or not re.fullmatch(r'AircSidebarTest[A-Za-z0-9-]+', zone):
        raise ValueError('Invalid test identifiers')
    deadline = float(deadline)
    window_check(deadline)
    if not time.time() < deadline <= time.time() + 1650:
        raise ValueError('Deadline exceeds bounded activity')
    data = ROOT / ('data-' + role)
    control = data / 'synctest'
    control.mkdir(parents=True, exist_ok=True)
    zone_file = control / 'zone.json'
    if zone_file.exists() and json.loads(zone_file.read_text()) != zone:
        raise RuntimeError('Existing data belongs to another test zone; clean up before reuse')
    zone_file.write_text(json.dumps(zone))
    (data / 'home/Library').mkdir(parents=True, exist_ok=True)
    for name in ('command.json', 'response.json', 'state.json', 'pid.json'):
        (control / name).unlink(missing_ok=True)
    # A vanished controller cannot let the launcher run beyond the deadline.
    lock_timeout = 120
    env = dict(os.environ, AIRC_UI_LOCK_STRICT='1', AIRC_UI_LOCK_TIMEOUT=str(lock_timeout), AIRC_SYNC_DEVICE_NAME='Test Mac ' + role)
    args = ['python3', str(ROOT / 'ui-check-lock.py'), 'open', '-g', '-n', '-W', '--env', 'CFFIXED_USER_HOME=' + str(data / 'home'),
            '--env', 'AIRC_SYNC_DEVICE_NAME=Test Mac ' + role, '--env', 'AIRC_TELEMETRY_ENABLED=0',
            '--stderr', str(ROOT / ('app-' + role + '.log')), str(APP), '--args',
            '--data-dir', str(data), '--skip-onboarding', '--automated', '--script', 'icloudsync-real-' + role.lower(),
            '--sync-test-launch', launch_id, '--sync-two-macs', '--sync-cloudkit-test-zone', zone, '--sync-test-deadline', str(deadline - 45)]
    if mode == 'cleanup':
        args.append('--sync-test-cleanup')
    with (ROOT / ('launch-' + role + '.log')).open('w') as log:
        process = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT)
        started = time.time()
        try:
            while process.poll() is None and time.time() < deadline:
                heartbeat = control / 'state.json'
                stalled = heartbeat.exists() and time.time() - heartbeat.stat().st_mtime > 60
                never_started = not heartbeat.exists() and time.time() - started > lock_timeout + 90
                if stalled or never_started:
                    print('FAIL: test heartbeat stalled; stopping only this bundle', file=log, flush=True)
                    break
                time.sleep(1)
            if process.poll() is None:
                stop_own()
                process.terminate()
                process.wait(timeout=10)
        finally:
            stop_own()
    return process.returncode


def emergency_cloud_cleanup(deadline):
    """Best effort before exact-PID termination; report every result, never claim an error is absence."""
    for directory in ROOT.glob('data-*/synctest'):
        try:
            pid = json.loads((directory / 'pid.json').read_text())['pid']
            if pid not in own_pids():
                print(json.dumps(dict(guardianCleanupError='App unavailable', role=directory.parent.name)), flush=True)
                continue
            groups_file = directory / 'groups.json'
            groups = json.loads(groups_file.read_text()) if groups_file.exists() else []
            for group in groups or ['']:
                ident = 'guardian-' + group
                temp = directory / 'command.guardian'
                temp.write_text(json.dumps(dict(id=ident, command='cleanup', group=group)))
                temp.replace(directory / 'command.json')
                for _ in range(30):
                    if time.time() >= deadline - 15:
                        return
                    try:
                        response = json.loads((directory / 'response.json').read_text())
                        if response.get('id') == ident:
                            print(json.dumps(dict(guardianCleanup=response)), flush=True)
                            break
                    except (OSError, ValueError):
                        pass
                    time.sleep(1)
        except (OSError, ValueError, KeyError) as error:
            print(json.dumps(dict(guardianCleanupError=type(error).__name__)), flush=True)


def guardian(deadline):
    deadline = float(deadline)
    window_check(deadline)
    if not time.time() < deadline <= time.time() + 1650:
        raise ValueError('Invalid guardian deadline')
    interrupted = False
    def stop(signum, frame):
        nonlocal interrupted
        interrupted = True
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, stop)
    print('guardian-ready', flush=True)
    try:
        while time.time() < deadline - 90 and not interrupted and not (ROOT / 'session-quit').exists():
            time.sleep(1)
    finally:
        try:
            if not (ROOT / 'session-quit').exists():
                emergency_cloud_cleanup(deadline)
        finally:
            cleanup()


def reset_data():
    import shutil
    if own_pids():
        raise RuntimeError('Test app still running')
    for data in ROOT.glob('data-*'):
        if not data.is_dir() or data.is_symlink():
            raise RuntimeError('Unexpected data path')
        # Never discard the only record of a key that still needs deletion.
        groups = data / 'synctest/groups.json'
        receipt = ROOT / 'cleanup.json'
        zone_file = data / 'synctest/zone.json'
        if groups.exists() or zone_file.exists():
            if not zone_file.exists():
                raise RuntimeError('Missing zone provenance; preserve old data for manual cleanup')
            zone = json.loads(zone_file.read_text())
            group_ids = json.loads(groups.read_text()) if groups.exists() else []
            expected = {zone + ':' + group for group in group_ids or ['']}
            evidence = json.loads(receipt.read_text()) if receipt.exists() else {}
            if not expected.issubset(evidence) or not all(all(evidence[g].get(k) is True for k in
                    ('keyGone', 'zoneGone', 'subscriptionGone')) for g in expected):
                raise RuntimeError('Cloud cleanup receipt missing; preserve data and clean up first')
        shutil.rmtree(data)


def progress(role):
    """Read committed test-engine progress without exporting account identifiers or sealed payloads."""
    if role not in ('A', 'B', 'R'):
        raise ValueError('Invalid test role')
    path = ROOT / ('data-' + role) / 'Sync/sync-state.json'
    if not path.exists():
        return {}
    state = json.loads(path.read_text())
    # SyncEngine uses JSONEncoder's default Date representation: seconds since 2001-01-01.
    last = state.get('lastSynced')
    return dict(lastSynced=last + 978307200 if last is not None else 0,
                pendingUploads=len(state.get('outbox', [])), enabled=state.get('enabled', False))


def cleanup():
    # Only literal task-owned roots, no Application Support, caches, owner bundles or system-wide mutations.
    import shutil
    stop_own()
    unregistered = True
    try:
        if APP.exists():
            subprocess.run([LSREGISTER, '-u', str(APP)], check=True, capture_output=True, timeout=15)
    except subprocess.SubprocessError:
        unregistered = False
    finally:
        shutil.rmtree(ROOT)
    print(json.dumps({'ownProcesses': len(own_pids()), 'taskFolderGone': not ROOT.exists(), 'bundleUnregistered': unregistered}))
    if not unregistered:
        raise RuntimeError('Task files removed, but bundle unregister was not verified')


if __name__ == '__main__':
    if sys.argv[1] == 'guardian':
        guardian(sys.argv[2])
    elif sys.argv[1] == 'launch':
        sys.exit(launch(*sys.argv[2:]))
    elif sys.argv[1] == 'cleanup':
        cleanup()
    elif sys.argv[1] == 'reset-data':
        reset_data()
    elif sys.argv[1] == 'progress':
        print(json.dumps(progress(sys.argv[2])))
    elif sys.argv[1] == 'stop':
        stop_own()
