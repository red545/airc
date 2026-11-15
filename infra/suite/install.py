#!/usr/bin/env python3
"""Install only the buildmac background suite; leave legacy laptop jobs held."""
import argparse
from pathlib import Path
import subprocess

ap = argparse.ArgumentParser()
ap.add_argument('--repo', type=Path, required=True, help='dedicated owned run checkout, never the shared tree')
ap.add_argument('--remote', required=True)
ap.add_argument('--status', type=Path, required=True)
ap.add_argument('--queue', type=Path, required=True)
ap.add_argument('--hours', type=int, default=6)
a = ap.parse_args()
if a.hours < 1:
    ap.error('--hours must be positive')
for p in (a.repo, a.status, a.queue):
    if not p.is_absolute() or any(c in str(p) for c in '\n"%'):
        ap.error('paths must be absolute and systemd-safe')
if any(c in a.remote for c in '\n\"%'):
    ap.error('remote must be systemd-safe')
units = Path.home() / '.config/systemd/user'
units.mkdir(parents=True, exist_ok=True)
runner = Path(__file__).resolve().with_name('schedule.py')
(units / 'airc-background-suite.service').write_text(f'''[Unit]
Description=Airc background full suite (dedicated build Mac only)
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 "{runner}" --repo "{a.repo}" --remote "{a.remote}" --status "{a.status}" --queue "{a.queue}"
StandardInput=null
TimeoutStartSec=12h
TimeoutStopSec=90
KillMode=mixed
Restart=on-failure
RestartSec=60
Nice=10
MemoryMax=2G
''')
(units / 'airc-background-suite.timer').write_text(f'''[Unit]
Description=Airc full suite every {a.hours} hours and nightly
[Timer]
OnActiveSec=1min
OnUnitInactiveSec={a.hours}h
OnCalendar=*-*-* 01:15:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
''')
subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
subprocess.run(['systemctl', '--user', 'enable', '--now', 'airc-background-suite.timer'], check=True)
