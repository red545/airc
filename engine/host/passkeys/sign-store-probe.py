#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Package/sign the standalone store probe; run it without registering/launching a browser.
Usage: sign-store-probe.py EXECUTABLE NEW_APP PROFILE
Uses AIRC_SIGN_IDENTITY / AIRC_SIGN_KEYCHAIN / AIRC_SIGN_KEYCHAIN_PASSWORD_FILE.
"""
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
binary, app, profile = map(pathlib.Path, sys.argv[1:])
if app.exists():
    sys.exit('Refusing to replace an existing app')
(app/'Contents/MacOS').mkdir(parents=True)
shutil.copy2(binary, app/'Contents/MacOS/PasskeyStoreProbe')
# Discover the bundle ID from the supplied profile without emitting its team.
repo = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo/'scripts/release'))
import icloud
p = icloud.decode(profile)
t = icloud.team(p)
identifier = p['Entitlements'][icloud.APP_ID]
if not identifier.startswith(t + '.'):
    sys.exit('Unexpected application identifier')
bundle = identifier[len(t) + 1:]
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'PasskeyStoreProbe', 'CFBundleIdentifier': bundle,
    'CFBundleName': 'PasskeyStoreProbe', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'LSUIElement': True,
}))
shutil.copy2(profile, app/'Contents/embedded.provisionprofile')
subprocess.run([sys.executable, str(repo/'scripts/release/sign.py'), str(app),
                os.environ['AIRC_SIGN_IDENTITY']], check=True)
subprocess.run([str(app/'Contents/MacOS/PasskeyStoreProbe')], check=True, timeout=60)
