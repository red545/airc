#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Reject development metadata, test code and incomplete mandatory licence payloads.

    check-release.py APP

Test code: public builds are compiled without AIRC_TESTING (apps/browser/Sources/Airc/App/TestingGate.swift). The
app executable must not name a test-only type (Swift keeps type names in its metadata, so they survive stripping) or
carry a test option's longer literal. Swift encodes string literals of 15 bytes or fewer, such as "--snapshot" or a
scenario name, inside instructions rather than as bytes, so those can't be searched for; the types that parse and
run them can. A dev/test build from scripts/build-app.sh fails this check.

Engine test hooks: the framework's harness switches (`airc-test`, `airc-trace`) are only compiled out by a separately
configured engine build. Until then they must ship with their run-time gate (engine/core/airc_launch_switches.cc):
the distribution-signature requirement and the refusals for a missing mock keychain or scratch profile. A framework
with the switch names but without those strings fails. This proves the gate is linked in, not that it is reached;
docs/release.md says how to prove that on a Developer ID build.
"""
from pathlib import Path
import plistlib
import os
import subprocess
import sys

# Test-only types (Debug/, AppDelegate) and literals of more than 15 bytes from test-only code paths.
TEST_MARKERS = (
    b'SnapshotRunner', b'OnboardingFixture', b'LocalPageServer', b'LaunchDiagnostics', b'TestAnchors', b'PerfLaunch',
    b'FrameClock', b'SplitTimings', b'LayoutCounter', b'ViewCensus', b'TestCrashSwitch',
    b'AircLaunchArguments', b'AIRC_UPDATE_RESTART_WHEN_READY', b'AIRC_LIVE_SUGGESTIONS',
)
ENGINE_TEST_SWITCHES = (b'airc-test\0', b'airc-trace\0')
ENGINE_TEST_GATE = (
    b'certificate leaf[field.1.2.840.113635.100.6.1.13] exists',
    b'signed for distribution\0',
    b'not on the mock keychain\0',
    b"--user-data-dir isn't the scratch data dir's Chromium folder\0",
)

app = Path(sys.argv[1])
p = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
checks = {
    'Chromium engine': p.get('AircDefaultEngine') == 'chromium' and (app / 'Contents/Frameworks/Airc Framework.framework').is_dir(),
    'public feed': p.get('SUFeedURL') == 'https://aircbrowser.com/appcast.xml',
    'public identity': p.get('CFBundleIdentifier') == 'com.aircbrowser.Airc',
    'no test published identity': 'AircPublishedBundleID' not in p,
    'automatic checks': p.get('SUEnableAutomaticChecks') is True,
    'automatic downloads': p.get('SUAutomaticallyUpdate') is True,
    'Sparkle key': p.get('SUPublicEDKey') == (Path(__file__).resolve().parents[2] / 'infra/release/sparkle-public-key.txt').read_text().strip(),
    'telemetry configured': bool(p.get('AircTelemetryKey')) and p.get('AircTelemetryHost', '').startswith('https://'),
    'stable channel': p.get('AircUpdateChannel') == os.environ.get('AIRC_RELEASE_CHANNEL', 'stable'),
    'no dev channel': 'AircDevChannel' not in p,
    'no launch defaults': 'AircLaunchArguments' not in p,
}
licenses = app / 'Contents/Resources/Licenses'
for name in ('LICENSE', 'NOTICE', 'Sparkle-LICENSE', 'Chromium-LICENSE'):
    checks[name] = (licenses / name).is_file() and (licenses / name).stat().st_size > 0
credits = licenses / 'Chromium-credits.html'
checks['generated Chromium credits'] = credits.is_file() and b'Neither the name' in credits.read_bytes() and credits.stat().st_size > 10000

executable = app / 'Contents/MacOS/Airc'
binary = executable.read_bytes() if executable.is_file() else b''
found = [m.decode() for m in TEST_MARKERS if m in binary]
checks['app executable present'] = bool(binary)
checks['no test code in the app' + (f" ({', '.join(found)})" if found else '')] = not found

framework = app / 'Contents/Frameworks/Airc Framework.framework/Airc Framework'
engine = framework.read_bytes() if framework.is_file() else b''
if any(s in engine for s in ENGINE_TEST_SWITCHES):
    missing = sum(m not in engine for m in ENGINE_TEST_GATE)
    checks['engine test switches ship with their run-time gate' + (f' ({missing} gate strings missing)' if missing else '')] = not missing

# The packager also runs this metadata gate before final signing. Ad-hoc build
# artifacts need their existing exceptions; distributed signatures must pass the
# per-binary CDM-only exception gate, including when inspected inside a DMG.
if sys.platform == 'darwin':
    signature = subprocess.run(['codesign', '-dv', str(app)], capture_output=True)
    if signature.returncode == 0 and b'Signature=adhoc' not in signature.stderr:
        checks['signed entitlement policy'] = subprocess.run([
            sys.executable, str(Path(__file__).with_name('check-entitlements.py')), str(app)
        ]).returncode == 0

for name, ok in checks.items():
    if not ok:
        print(f'FAIL release metadata: {name}')
print('Release check: ' + ('PASS' if all(checks.values()) else 'FAIL'))
sys.exit(0 if all(checks.values()) else 1)
