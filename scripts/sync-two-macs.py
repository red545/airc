#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""One-night qualification. --dry-run uses only the build host, serializing two data folders.
Never copy a group key: the second host must receive it through iCloud Keychain.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

START = dt.datetime(2026, 11, 10, 1, 30, tzinfo=dt.timezone.utc).timestamp()
END = dt.datetime(2026, 11, 10, 3, 30, tzinfo=dt.timezone.utc).timestamp()
REMOTE = 'arcfork/work/synctest'
STATUS = Path(__file__).resolve().parents[2] / 'status'


def guard(host, now=None):
    if host not in ('buildmac', 'mac-manual'):
        raise ValueError('Unapproved SSH host')
    now = time.time() if now is None else now
    if host == 'mac-manual' and not START <= now < END:
        raise RuntimeError('Laptop access outside owner window refused')


def ssh(host, command, *, data=None, timeout=45, check=True):
    guard(host)
    return subprocess.run(['ssh', '-oBatchMode=yes', '-oConnectTimeout=10', host, command], input=data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=check)


class Run:
    def __init__(self, args):
        self.args = args
        self.out = args.output
        self.out.mkdir(parents=True, exist_ok=True)
        self.zone = 'AircSidebarTest' + ('Dry' if args.dry_run else 'TwoMac') + uuid.uuid4().hex[:12]
        self.hosts = {'A': 'buildmac', 'B': 'buildmac' if args.dry_run else 'mac-manual',
                      'R': 'buildmac' if args.dry_run else 'mac-manual'}
        self.running = {}
        self.groups = set()
        self.deadline = time.time() + 1600
        self.results = []
        self.cleaning = False
        self.guardian = None
        self.guardian_log = None
        self.laptop_owned = False
        self.laptop_ready = False
        self.laptop_removed = False
        self.prepared = False

    def event(self, step, **values):
        entry = dict(step=step, time=time.time(), **values)
        self.results.append(entry)
        (self.out / 'results.json').write_text(json.dumps(self.results, indent=2) + '\n')
        print(json.dumps(entry), flush=True)

    def clock_sample(self, host):
        before = time.time()
        result = ssh(host, "python3 -c 'import time; print(time.time())'")
        after = time.time()
        remote = float(result.stdout)
        self.event('clock-sample', host=host, offset=remote - (before + after) / 2,
                   uncertainty=(after - before) / 2)

    def read(self, role, name):
        result = ssh(self.hosts[role], 'cat ' + shlex.quote(f'{REMOTE}/data-{role}/synctest/{name}'), check=False)
        if result.returncode:
            return None
        value = json.loads(result.stdout)
        if name == 'state.json':
            # Keep the UI timestamp visible, but qualify uploads from the engine's durable completion record.
            progress = ssh(self.hosts[role], f'python3 {REMOTE}/sync-test-host.py progress {role}')
            value['persisted'] = json.loads(progress.stdout)
        return value

    def command(self, recipient, name, *, timeout=80, **values):
        role = recipient
        if role in self.running and self.running[role][0].poll() is not None:
            raise RuntimeError(f'{role}: launcher has exited before {name}')
        ident = uuid.uuid4().hex
        payload = json.dumps(dict(id=ident, command=name, **values)).encode()
        path = f'{REMOTE}/data-{role}/synctest/command.json'
        ssh(self.hosts[role], f'cat > {path}.tmp && mv {path}.tmp {path}', data=payload)
        started = time.monotonic()
        until = min(time.monotonic() + timeout, time.monotonic() + self.deadline - time.time() - 10)
        while time.monotonic() < until:
            response = self.read(role, 'response.json')
            if response and response.get('id') == ident:
                if not response.get('ok'):
                    raise RuntimeError(f'{role} {name}: {response}')
                return response
            time.sleep(0.5)
        raise TimeoutError(f'{role} command {name}')

    def wait(self, role, label, predicate, timeout=90):
        started = time.monotonic()
        while time.monotonic() - started < timeout and time.time() < self.deadline - (15 if self.cleaning else 180):
            if label == 'launched' and self.running[role][0].poll() is not None:
                raise RuntimeError(f'{role}: launcher exited ({self.running[role][0].returncode}); inspect SSH/UI-lock log')
            state = self.read(role, 'state.json')
            if state and predicate(state):
                self.event(label, role=role, seconds=round(time.monotonic() - started, 3), state=state)
                if state.get('group'):
                    self.groups.add(state['group'])
                return state
            time.sleep(1)
        raise TimeoutError(f'{role}: {label}')

    def launch(self, role):
        host = self.hosts[role]
        guard(host)
        if host == 'buildmac' and (STATUS / 'quiet-pending').exists():
            raise RuntimeError('Build host reserved for quiet measurements; retry later')
        if any(self.hosts[r] == host for r in self.running):
            raise RuntimeError('Never overlap UI checks on one display')
        deadline = min(self.deadline, time.time() + 1600)
        prefix = 'SYNC_TEST_LAPTOP=1 ' if host == 'mac-manual' else ''
        launch_id = uuid.uuid4().hex
        command = prefix + f'python3 {REMOTE}/sync-test-host.py launch {role} {self.zone} {deadline} {launch_id} {"cleanup" if self.cleaning else "test"}'
        log = (self.out / f'ssh-{role}-{int(time.time())}.log').open('wb')
        self.running[role] = (subprocess.Popen(['ssh', '-oBatchMode=yes', '-oConnectTimeout=10', host, command], stdout=log, stderr=log), log)
        self.wait(role, 'launched', lambda s: s.get('launch') == launch_id, timeout=150)

    def quit(self, role):
        if role not in self.running:
            return
        process, log = self.running[role]
        try:
            if process.poll() is None:
                self.command(role, 'quit', timeout=8)
            process.wait(timeout=25)
        except Exception as e:
            self.event('quit-error', role=role, error=str(e))
        finally:
            try:
                if process.poll() is None:
                    ssh(self.hosts[role], f'python3 {REMOTE}/sync-test-host.py stop')
                    process.wait(timeout=15)
            finally:
                log.close()
                if process.poll() is not None:
                    del self.running[role]

    def switch(self, old, new):
        if self.args.dry_run:
            self.quit(old)
            self.launch(new)
            self.command(new, 'enable')

    def cleanup_cloud(self):
        self.cleaning = True
        for role in ('A', 'B', 'R'):
            if not self.args.dry_run and role != 'A' and not self.laptop_ready:
                continue
            try:
                self.groups.update(self.read(role, 'groups.json') or [])
                if role in self.running and self.running[role][0].poll() is None:
                    self.command(role, 'disable')
            except Exception as e:
                self.event('cleanup-discovery-error', role=role, error=str(e))
        for role in list(self.running):
            try:
                self.quit(role)
            except Exception as e:
                self.event('cleanup-error', role=role, error=str(e))
        # Keep enough time for both verifications; cleanup never enables sync or recreates a zone.
        for role in (('A', 'B') if self.args.dry_run else ('B', 'A')):
            if not self.args.dry_run and role == 'B' and not self.laptop_ready:
                continue
            try:
                self.launch(role)
                for group in sorted(self.groups) or ['']:
                    answer = self.command(role, 'cleanup', group=group)
                    self.event('cleanup', role=role, group=group, result=answer)
                    if not all(answer[k] for k in ('keyGone', 'zoneGone', 'subscriptionGone')):
                        raise RuntimeError('Cleanup verification failed')
                self.quit(role)
                if role == 'B' and not self.args.dry_run:
                    self.collect(('B', 'R'))
                    self.remove_laptop()
            except Exception as e:
                self.event('cleanup-error', role=role, error=str(e))
                if role in self.running:
                    try:
                        self.quit(role)
                    except Exception as quit_error:
                        self.event('cleanup-error', role=role, error=str(quit_error))

    def collect(self, roles=('A', 'B', 'R')):
        for role in roles:
            if role != 'A' and self.laptop_removed:
                continue
            if not self.args.dry_run and role != 'A' and not self.laptop_owned:
                continue
            try:
                for name in ('events.jsonl', 'key-events.jsonl', 'groups.json', 'zone.json', 'state.json', 'first-sync-merge.png', 'first-sync-replace.png'):
                    result = ssh(self.hosts[role], f'cat {REMOTE}/data-{role}/synctest/{name}', check=False)
                    if result.returncode == 0:
                        (self.out / f'{role}-{name}').write_bytes(result.stdout)
                for name in ('cleanup.json', f'app-{role}.log', f'launch-{role}.log'):
                    result = ssh(self.hosts[role], f'cat {REMOTE}/{name}', check=False)
                    if result.returncode == 0:
                        (self.out / f'{role}-{name}').write_bytes(result.stdout)
            except Exception as e:
                self.event('collection-error', role=role, error=str(e))

    def exercise(self):
        self.launch('A')
        self.command('A', 'seed', role='A')
        self.command('A', 'enable')
        first = self.wait('A', 'first-upload', lambda s: s['status'] == 'upToDate' and bool(s['group']))
        if self.args.dry_run:
            self.quit('A')
        self.launch('B')
        self.command('B', 'seed', role='B')
        self.command('B', 'enable')
        self.wait('B', 'key-and-first-sync-screen', lambda s: s['status'] == 'choosing' and s['firstSyncSheet']
                  and 'Sync Test Shared' in s['firstSyncSpaces'], timeout=240)
        self.command('B', 'merge')
        self.wait('B', 'merge-duplicates-and-backup', lambda s: s['status'] == 'upToDate' and s['backup'] and s['group'] == first['group']
                  and sum(x['name'] == 'Sync Test Shared' for x in s['spaces']) == 2)
        # The seed A item resolves which independently-created, same-named Space to edit.
        edited = self.command('B', 'edit', role='B', space='Sync Test Shared', delete='Delete Target')
        self.event('local-edit', role='B', at=edited['at'])
        self.wait('B', 'B-edits-uploaded', lambda s: s['status'] == 'upToDate'
                  and s['persisted'].get('lastSynced', 0) > edited['at'] and s['persisted'].get('pendingUploads') == 0)
        self.switch('B', 'A')
        self.wait('A', 'B-to-A-arrival', lambda s: any(x['name'] == 'Sync Test B' for x in s['spaces'])
                  and any(x['title'] == 'Pin B' and x['parent'] in
                          {f['id'] for f in s['items'] if f['title'] == 'Folder B'} for x in s['items'])
                  and not any(x['title'] == 'Delete Target' for x in s['items']), timeout=700)
        edited = self.command('A', 'edit', role='A', space='Sync Test B', delete='Seed A')
        self.event('local-edit', role='A', at=edited['at'])
        self.wait('A', 'A-edits-uploaded', lambda s: s['status'] == 'upToDate'
                  and s['persisted'].get('lastSynced', 0) > edited['at'] and s['persisted'].get('pendingUploads') == 0)
        self.switch('A', 'B')
        self.wait('B', 'A-to-B-arrival', lambda s: any(x['name'] == 'Sync Test A' for x in s['spaces'])
                  and any(x['title'] == 'Pin A' and x['parent'] in
                          {f['id'] for f in s['items'] if f['title'] == 'Folder A'} for x in s['items'])
                  and not any(x['title'] == 'Seed A' for x in s['items']), timeout=700)
        self.command('B', 'offline')
        self.command('B', 'rename-conflict', value='Conflict B')
        # Let the normal local-edit scheduler encounter the injected failure. Awaiting a Sync Now command
        # would block this test mailbox's heartbeat while the production transport performs its retries.
        self.wait('B', 'offline-error', lambda s: s['status'].startswith('retrying'))
        self.switch('B', 'A')
        edited = self.command('A', 'delete-conflict')
        self.wait('A', 'delete-uploaded', lambda s: s['status'] == 'upToDate'
                  and s['persisted'].get('lastSynced', 0) > edited['at'] and s['persisted'].get('pendingUploads') == 0)
        self.switch('A', 'B')
        self.command('B', 'online')
        self.wait('B', 'delete-wins-over-offline-rename', lambda s: s['status'] == 'upToDate'
                  and not any(x['name'].startswith('Conflict') for x in s['spaces']))
        self.quit('B')
        self.launch('R')
        self.command('R', 'seed', role='B')
        self.command('R', 'enable')
        self.wait('R', 'replace-first-sync-screen', lambda s: s['status'] == 'choosing' and s['firstSyncSheet'])
        self.command('R', 'replace')
        self.wait('R', 'replace-no-extra-space-and-backup', lambda s: s['status'] == 'upToDate' and s['backup']
                  and sum(x['name'] == 'Sync Test Shared' for x in s['spaces']) == 1
                  and sum(x['title'] == 'Seed B' for x in s['items']) == 1)
        self.quit('R')

    def install_laptop(self):
        # All compression/signing/preparation happens before the window. Only one signed bundle is copied.
        if not self.args.bundle_tar or not self.args.bundle_tar.is_file():
            raise RuntimeError('Prepared signed bundle archive required')
        guard('mac-manual')
        if time.time() > END - 600:
            raise RuntimeError('Insufficient window for safe testing and cleanup')
        self.deadline = min(time.time() + 1600, END - 60)
        ssh('mac-manual', f'test ! -e {REMOTE} && mkdir -p {REMOTE}')
        self.laptop_owned = True
        # Install the tiny guardian first; if transfer fails, it still removes the partial bundle.
        for name in ('sync-test-host.py', 'ui-check-lock.py'):
            ssh('mac-manual', f'cat > {REMOTE}/{name}', data=Path(__file__).with_name(name).read_bytes())
        self.guardian_log = (self.out / 'laptop-guardian.log').open('wb')
        guard('mac-manual')
        self.guardian = subprocess.Popen(['ssh', '-oBatchMode=yes', '-oConnectTimeout=10', 'mac-manual',
            f'SYNC_TEST_LAPTOP=1 python3 {REMOTE}/sync-test-host.py guardian {self.deadline}'],
            stdout=self.guardian_log, stderr=self.guardian_log)
        ready_until = time.monotonic() + 20
        while time.monotonic() < ready_until:
            if self.guardian.poll() is not None:
                raise RuntimeError('Laptop guardian did not start')
            if 'guardian-ready' in (self.out / 'laptop-guardian.log').read_text():
                break
            time.sleep(0.2)
        else:
            raise RuntimeError('Laptop guardian readiness timed out')
        # Pipe the prebuilt archive through ssh only; never use the blocked old alias.
        with self.args.bundle_tar.open('rb') as archive:
            guard('mac-manual')
            subprocess.run(['ssh', '-oBatchMode=yes', '-oConnectTimeout=10', 'mac-manual',
                            f'tar -xzf - -C {REMOTE}'], stdin=archive, check=True, timeout=180)
        ssh('mac-manual', f'codesign --verify --deep --strict {REMOTE}/Airc-SyncTest.app', timeout=60)
        self.laptop_ready = True
        self.event('laptop-bundle-copied', signatureVerified=True)

    def remove_laptop(self):
        if self.laptop_removed:
            return
        if self.guardian:
            ssh('mac-manual', f'touch {REMOTE}/session-quit')
            self.guardian.wait(timeout=60)
            self.guardian_log.close()
            if self.guardian.returncode != 0:
                ssh('mac-manual', f'python3 {REMOTE}/sync-test-host.py cleanup')
            result = ssh('mac-manual', f'test ! -e {REMOTE} && echo task-folder-gone', check=False)
            self.event('laptop-idle-cleanup', guardianExit=self.guardian.returncode,
                       taskFolderGone=result.returncode == 0)
            self.laptop_removed = result.returncode == 0
            if self.guardian.returncode != 0 or not self.laptop_removed:
                raise RuntimeError('Laptop cleanup failed')
        elif self.laptop_owned:
            # Failure while transferring the tiny helper: no app has been launched yet.
            ssh('mac-manual', "python3 -c 'from pathlib import Path; import shutil; shutil.rmtree(Path.home() / \"arcfork/work/synctest\")'")
            self.laptop_removed = True

    def run(self):
        self.event('start', zone=self.zone, dryRun=self.args.dry_run)
        try:
            ssh('buildmac', f'python3 {REMOTE}/sync-test-host.py reset-data')
            self.prepared = True
            if not self.args.dry_run:
                self.install_laptop()
            for host in sorted(set(self.hosts.values())):
                self.clock_sample(host)
            self.exercise()
            self.event('checks-completed')
        except Exception as e:
            self.event('FAIL', error=str(e))
        finally:
            try:
                if self.prepared:
                    try:
                        self.cleanup_cloud()
                    except Exception as e:
                        self.event('cleanup-error', error=str(e))
                    finally:
                        self.collect()
            finally:
                if not self.args.dry_run:
                    try:
                        self.remove_laptop()
                    except Exception as e:
                        self.event('cleanup-error', role='laptop', error=str(e))
        # "offline-error" is an expected successful observation, not a runner failure.
        return int(any(r['step'] == 'FAIL' or 'error' in r for r in self.results))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle-tar', type=Path)
    args = parser.parse_args()
    if not args.dry_run:
        guard('mac-manual')
        if not args.bundle_tar:
            raise SystemExit('--bundle-tar is required for the two-host run')
    return Run(args).run()


if __name__ == '__main__':
    raise SystemExit(main())
