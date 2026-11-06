#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Release-only incremental build. Caller must hold the coordinator ship lock."""
import os, re, signal, subprocess, time

def free():
    info = subprocess.check_output(['diskutil', 'info', '/System/Volumes/Data'], text=True)
    return int(re.search(r'Container Free Space:.*?\((\d+) Bytes\)', info)[1])

print('Free bytes before:', free(), flush=True)
if free() < 14_000_000_000:
    raise SystemExit('Refusing build below 14 GB')
p = subprocess.Popen(['caffeinate', '-i', '-s', 'engine/build.sh', '--run', '--variant', 'release'], start_new_session=True)
while p.poll() is None:
    if free() < 12_000_000_000:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait()
        raise SystemExit('Stopped build below 12 GB')
    time.sleep(5)
print('Free bytes after:', free(), flush=True)
raise SystemExit(p.returncode)
