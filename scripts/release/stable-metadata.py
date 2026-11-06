#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Metadata on a freshly compiled public staging copy, before gates and signing."""
import os
import plistlib
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
info = plistlib.loads(p.read_bytes())
version = os.environ.get('AIRC_RELEASE_VERSION', '0.1.0')
build = os.environ.get('AIRC_RELEASE_BUILD', info['CFBundleVersion'])
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d{12}', build):
    sys.exit('Expected SemVer and UTC YYYYMMDDHHMM build')
info.update(CFBundleIdentifier='com.aircbrowser.Airc', CFBundleShortVersionString=version,
            CFBundleVersion=build, SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True,
            SUScheduledCheckInterval=3600)
# Never inherit test/development metadata, even if the underlying builder changes.
for key in ('AircPublishedBundleID', 'AircLaunchArguments', 'AircDevChannel'):
    if key in info:
        sys.exit('Public builder unexpectedly emitted test/development metadata')
p.write_bytes(plistlib.dumps(info))
