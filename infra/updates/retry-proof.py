#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Real updater proof of the stalled-download retry (updretry), on a Mac, in a throwaway folder.

A copy of OLD_APP (an Airc build with the retry, older than the target) updates itself with its own Sparkle from a
loopback appcast. The appcast's only enclosure is a published archive with its published EdDSA signature, served by
staller.py, whose first archive GET stalls mid-body. Passes when the first download times out, the app logs one retry,
the second download is verified, and quitting installs the target, which then launches.
Never touches a published feed: the feed is loopback and the archive a local copy.

    retry-proof.py --app OLD_APP --zip ARCHIVE --version BUILD --short X.Y.Z --signature EDSIG --work DIR --helper SMOKE_WINDOW
Run it under the UI lock (scripts/ui-check-lock.py) and inside infra/release/update-proof.py --domain <the app's bundle ID>
(cfprefsd keeps SULastCheckTime outside CFFIXED_USER_HOME; the wrapper clears and restores it), with a smoke-window
helper compiled beforehand (scripts/release/smoke-window.swift). DIR must not exist; the result is DIR/result.json.
`--stall 3` is the negative case: the retry stalls too, and the update must abort after exactly one retry.
"""
import argparse, json, os, plistlib, shutil, signal, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

a = argparse.ArgumentParser()
for name in ('app', 'zip', 'version', 'short', 'signature', 'work', 'helper'):
    a.add_argument('--' + name, required=True)
a.add_argument('--stall', type=int, default=1, help='archive GETs that stall (1: the retry must succeed)')
a.add_argument('--after', type=int, default=1 << 20, help='bytes sent before the stall')
a.add_argument('--wait', type=float, default=300, help='seconds to wait for the update to be ready')
o = a.parse_args()

root = Path(o.work).resolve()
root.mkdir(parents=True, exist_ok=False)
here = Path(__file__).resolve().parent
app = root/'installed/Airc.app'
home, data, feed = root/'home', root/'home/Airc', root/'feed'
for d in (home/'Library', data, feed):
    d.mkdir(parents=True)
subprocess.run(['ditto', o.app, str(app)], check=True)
info = lambda: plistlib.loads((app/'Contents/Info.plist').read_bytes())
before = info()
assert int(before['CFBundleVersion']) < int(o.version), 'the old app must be older than the target'
archive = feed/Path(o.zip).name
try:
    os.link(o.zip, archive)
except OSError:
    shutil.copyfile(o.zip, archive)
length = archive.stat().st_size
exe = str(app/'Contents/MacOS'/before['CFBundleExecutable'])
helper = str(Path(o.helper).resolve())

def own_pids():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    return [int(f[0]) for r in rows if len(f := r.strip().split(None, 1)) == 2 and f[1] == exe]

assert not own_pids()
port_file = root/'port'
staller = subprocess.Popen([sys.executable, str(here/'staller.py'), str(feed), '--stall', str(o.stall), '--after', str(o.after),
                            '--hold', '120', '--log', str(root/'requests.jsonl'), '--port-file', str(port_file)],
                           stdout=(root/'staller.log').open('w'), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
for _ in range(50):
    if port_file.exists() and port_file.read_text().strip():
        break
    time.sleep(0.1)
port = int(port_file.read_text())
url = f'http://127.0.0.1:{port}'
date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
(feed/'appcast.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>updretry proof</title>
<item><title>{o.short}</title><pubDate>{date}</pubDate>
<sparkle:version>{o.version}</sparkle:version><sparkle:shortVersionString>{o.short}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{url}/{archive.name}" length="{length}" type="application/octet-stream" sparkle:edSignature="{o.signature}"/>
</item></channel></rss>
''')

def launch(*extra):
    subprocess.run(['open', '-g', '-n', '--stderr', str(root/'stderr.log'), '--env', 'CFFIXED_USER_HOME=' + str(home),
                    '--env', 'AIRC_TELEMETRY_ENABLED=0', str(app), '--args', '--data-dir', str(data), '--use-mock-keychain',
                    '--deny-permission-prompts', *extra], check=True)
    for _ in range(120):
        if pids := own_pids():
            return pids[0]
        time.sleep(0.25)
    raise RuntimeError('app did not launch')

def requests():
    p = root/'requests.jsonl'
    return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []

result = {'passed': False, 'from': before['CFBundleVersion'], 'to': o.version, 'archive': archive.name, 'bytes': length,
          'stalledGets': o.stall}
pid = None
log = data/'Updates.log'
try:
    started = time.time()
    pid = launch('-SUEnableAutomaticChecks', 'YES', '-SUAutomaticallyUpdate', 'YES', '-SUScheduledCheckInterval', '3600',
                 '-SUFeedURL', url + '/appcast.xml')
    text = ''
    while time.time() - started < o.wait:
        text = log.read_text() if log.exists() else ''
        if f'ready {o.version}: installs on quit' in text:
            break
        if not own_pids():
            raise RuntimeError('old app exited before the update was ready')
        time.sleep(1)
    (root/'updates-before-quit.log').write_text(text)
    result['readySeconds'] = round(time.time() - started, 1)
    result['updatesLog'] = [l.split(': ', 1)[-1] for l in text.splitlines()]
    result['requests'] = requests()
    if f'ready {o.version}: installs on quit' not in text:
        raise RuntimeError('update not ready in %d s' % o.wait)
    # One row per archive GET: a stalled one is logged when it starts (its 'done' row comes when it closes).
    gets = sorted({r['archiveGet']: r for r in reversed(result['requests']) if r.get('archiveGet')}.values(),
                  key=lambda r: r['archiveGet'])
    assert [r['stalled'] for r in gets[:o.stall]] == [True] * o.stall, 'the first archive GET did not stall'
    assert len(gets) == o.stall + 1 and gets[-1]['bytesSent'] == length, 'not exactly one full download after the stall'
    assert text.count('retrying once') == 1, 'expected exactly one retry line'
    assert text.count(f'downloading {o.version}') == 2, 'expected two download attempts'
    lines = result['updatesLog']
    first_fail = next(i for i, l in enumerate(lines) if l.startswith(f'download of {o.version} failed'))
    assert first_fail < next(i for i, l in enumerate(lines) if 'retrying once' in l)
    # Seconds from the stalled GET to the app's failure line: the 20 s idle timeout, not 60.
    fail_line = next(l for l in text.splitlines() if f'download of {o.version} failed' in l)
    fail_at = datetime.fromisoformat(fail_line.split(' ')[0].replace('Z', '+00:00')).timestamp()
    result['stallToFailureSeconds'] = round(fail_at - gets[0]['time'], 1)
    assert result['stallToFailureSeconds'] < 40, 'stall took longer than the 20 s idle timeout'
    print('PASS first download stalled, failed after %.0f s, one retry, update ready after %.0f s' %
          (result['stallToFailureSeconds'], result['readySeconds']), flush=True)
    r = subprocess.run([helper, 'quit', str(pid), '60'], capture_output=True, text=True)
    result['quit'] = r.stdout.strip() or r.stderr.strip()
    pid = None
    for _ in range(180):
        try:
            if info()['CFBundleVersion'] == o.version:
                break
        except (FileNotFoundError, plistlib.InvalidFileException):
            pass
        time.sleep(1)
    else:
        raise RuntimeError('Sparkle did not install the update on quit')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    result['installed'] = {k: info().get(k) for k in ('CFBundleVersion', 'CFBundleShortVersionString', 'CFBundleIdentifier', 'AircRevision')}
    print('PASS Sparkle installed %s (%s) on quit; signature valid' % (o.short, o.version), flush=True)
    pid = launch('-SUEnableAutomaticChecks', 'NO')
    w = subprocess.run([helper, 'window', str(pid), '90'], capture_output=True, text=True)
    result['relaunchWindow'] = w.stdout.strip()
    assert w.returncode == 0, 'updated app showed no window'
    subprocess.run([helper, 'quit', str(pid), '60'], check=True, capture_output=True)
    pid = None
    print('PASS updated app launched: ' + result['relaunchWindow'], flush=True)
    result['passed'] = True
except Exception as failure:
    result['error'] = repr(failure)
    print('FAIL', repr(failure), flush=True)
finally:
    result.setdefault('requests', requests())
    for p in own_pids():
        subprocess.run([helper, 'quit', str(p), '8'], capture_output=True)
    time.sleep(1)
    for p in own_pids():
        os.kill(p, signal.SIGKILL)
    staller.terminate()
    staller.wait(5)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                    '-u', str(app)], capture_output=True)
    archive.unlink(missing_ok=True)
    (root/'result.json').write_text(json.dumps(result, indent=2) + '\n')
sys.exit(0 if result['passed'] else 1)
