#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Install and verify the fixed loopback feed, preserving a working interpreter."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
import uuid


def atomic_write(path, data):
    if path.exists() and path.read_bytes() == data:
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temp = Path(stream.name)
        stream.write(data)
    try:
        temp.chmod(0o644)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def interpreter(agent, tail):
    # Login shells and plain SSH have different PATHs. Never unload a healthy
    # service just because sys.executable changed from one invocation to another.
    if agent.exists():
        old = plistlib.loads(agent.read_bytes()).get('ProgramArguments', [])
        if len(old) == len(tail) + 1 and old[1:] == tail and os.access(old[0], os.X_OK):
            return old[0]
    return sys.executable


def bootstrap(domain, agent, attempts=10):
    for attempt in range(attempts):
        result = subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], capture_output=True, text=True)
        if result.returncode == 0:
            return
        # bootout can finish before launchd has removed the old registration.
        if attempt + 1 < attempts:
            print(f'local-feed: bootstrap attempt {attempt + 1} failed (exit {result.returncode}); retrying', flush=True)
            time.sleep(1)
    reason = ' '.join(result.stderr.strip().splitlines())
    raise RuntimeError(f'launchctl bootstrap failed (exit {result.returncode}): {reason}')


def install(root, proof=False):
    home = Path.home()
    label, port = 'org.airc.devfeed', 3483
    if proof:
        home = home/'arcfork/work/localupdates-followup'
        label, port = 'org.airc.localupdates.repro', 3493
    service = home/'arcfork/tools/devfeed'
    feed = home/'arcfork/updates-local'
    service.mkdir(parents=True, exist_ok=True)
    feed.mkdir(parents=True, exist_ok=True)
    atomic_write(service/'server.py', (root/'infra/updates/server.py').read_bytes())
    agent = home/f'Library/LaunchAgents/{label}.plist'
    agent.parent.mkdir(parents=True, exist_ok=True)
    tail = [str(service/'server.py'), str(feed), str(port)]
    data = dict(Label=label, ProgramArguments=[interpreter(agent, tail), *tail],
                RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
                StandardOutPath=str(service/'stdout.log'), StandardErrorPath=str(service/'stderr.log'))
    encoded = plistlib.dumps(data)
    domain = 'gui/' + str(os.getuid())
    loaded = subprocess.run(['launchctl', 'print', domain+'/'+label], capture_output=True).returncode == 0
    if not agent.exists() or agent.read_bytes() != encoded or not loaded:
        if loaded:
            subprocess.run(['launchctl', 'bootout', domain+'/'+label], check=True)
        atomic_write(agent, encoded)
        bootstrap(domain, agent)
    # A registered job is not proof that its interpreter started, bound the port,
    # or serves the expected directory. Probe an unpredictable, short-lived file.
    token = uuid.uuid4().hex
    marker = feed/('.health-' + token)
    marker.write_text(token)
    try:
        for attempt in range(20):
            try:
                with urlopen(f'http://127.0.0.1:{port}/{marker.name}', timeout=1) as response:
                    if response.read().decode() == token:
                        print(f'local-feed: ready on loopback port {port}', flush=True)
                        return
            except OSError:
                pass
            time.sleep(.5)
        raise RuntimeError(f'feed health check failed on loopback port {port}; inspect {service}/stderr.log')
    finally:
        marker.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--proof', action='store_true', help='Use a separate scratch directory, label and port')
    args = parser.parse_args()
    try:
        install(args.root, args.proof)
    except Exception as error:
        sys.exit(f'local-feed: failed: {error}')
