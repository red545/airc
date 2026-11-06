#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Build Mac: install the loopback-only owner feed. No root, TLS proxy or dependencies.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$root" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys
home = pathlib.Path.home()
service = home/'arcfork/tools/devfeed'
feed = home/'arcfork/updates-local'
service.mkdir(parents=True, exist_ok=True)
feed.mkdir(parents=True, exist_ok=True)
shutil.copyfile(pathlib.Path(sys.argv[1])/'infra/updates/server.py', service/'server.py')
agent = home/'Library/LaunchAgents/org.airc.devfeed.plist'
agent.parent.mkdir(parents=True, exist_ok=True)
data = dict(Label='org.airc.devfeed', ProgramArguments=[sys.executable, str(service/'server.py'), str(feed), '3483'],
            RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
            StandardOutPath=str(service/'stdout.log'), StandardErrorPath=str(service/'stderr.log'))
encoded = plistlib.dumps(data)
domain = 'gui/'+str(os.getuid())
loaded = subprocess.run(['launchctl','print',domain+'/org.airc.devfeed'], capture_output=True).returncode == 0
if not agent.exists() or agent.read_bytes() != encoded or not loaded:
    if loaded: subprocess.run(['launchctl','bootout',domain+'/org.airc.devfeed'], check=True)
    agent.write_bytes(encoded)
    subprocess.run(['launchctl','bootstrap',domain,str(agent)],check=True)
PY
