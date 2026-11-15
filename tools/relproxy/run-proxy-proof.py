#!/usr/bin/env python3
"""relproxy: run proxy-update-proof.py on buildmac under the UI lock and infra/release/update-proof.py
(from artifacts/release029/loopback/run-loopback-proof.py). Pulls the evidence back and redacts the preview's
protection-bypass value from every file. Usage: run-proxy-proof.py PREVIEW_URL BYPASS_FILE EVIDENCE_DIR
"""
from pathlib import Path
import subprocess, sys
preview, bypass_file, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=False)
bypass = bypass_file.read_text().strip()
status = Path.home() / 'arcfork/status'  # the Linux box's coordination markers
build = '202611151025'
cut = '78fccf77553ccfa659004079c02b00651aa2e52c'
blocked = lambda: any((status / x).exists() for x in ['quiet-pending', 'relink-pending', 'release-staging'])
assert not blocked(), 'Coordination held'
tools, feed = 'arcfork/work/relproxy-tools', 'arcfork/work/relproxy-feed'
cmd = ('cd ~/' + tools + ' && { test ! -e /tmp/owner-ui-hold.state || test "$(cat /tmp/owner-ui-hold.state)" = released; }'
       ' && export AIRC_UI_COORDINATOR=1 AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1'
       ' && caffeinate -d -i python3 scripts/ui-check-lock.py python3 infra/release/update-proof.py'
       ' --domain com.aircbrowser.Airc --evidence build/update-defaults -- python3 proxy-update-proof.py '
       + build + ' . ' + cut + ' "$HOME/' + feed + '" ' + preview + ' "$HOME/' + feed + '/bypass.txt"')
p = subprocess.Popen(['ssh', 'buildmac', cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     text=True, bufsize=1)
with (out / 'update-proof.log').open('w') as log:
    for line in p.stdout:
        line = line.replace(bypass, 'BYPASS')
        log.write(line); log.flush(); print(line, end='', flush=True)
        if line.startswith('@@LOCKED@@'):
            p.stdin.write(('HOLD' if blocked() else 'RUN') + '\n'); p.stdin.flush()
rc = p.wait()
(out / 'update-proof.exit').write_text(str(rc) + '\n')
subprocess.run(['rsync', '-az', '--exclude=home', '--exclude=installed', '--exclude=smoke-window',
                'buildmac:arcfork/work/relproxy-update-proxy.noindex/', str(out / 'update-proof') + '/'], check=False)
subprocess.run(['rsync', '-az', 'buildmac:' + tools + '/build/update-defaults/', str(out / 'update-proof/defaults') + '/'],
               check=False)
leaks = 0
for f in out.rglob('*'):
    if f.is_file():
        b = f.read_bytes()
        if bypass.encode() in b:
            f.write_bytes(b.replace(bypass.encode(), b'BYPASS')); leaks += 1
print('redacted bypass in', leaks, 'evidence files')
raise SystemExit(rc)
