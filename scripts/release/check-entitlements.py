#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Verify every real Mach-O in a Developer ID app; no framework symlink aliases."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from entitlement_policy import library_validation_error

MACHO = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

def check(app):
    requirement = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    identity = subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R='+requirement, str(app)], capture_output=True)
    if identity.returncode:
        print('FAIL entitlement gate: a valid Developer ID bundle is required')
        return 1
    count = 0
    errors = []
    for root, dirs, files in os.walk(app, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(root)/d).is_symlink()]
        for name in files:
            path = Path(root)/name
            if path.is_symlink(): continue
            with path.open('rb') as f:
                if f.read(4) not in MACHO: continue
            result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True)
            relative = path.relative_to(app)
            try:
                if result.returncode: raise ValueError('codesign failed')
                entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
                error = library_validation_error(relative, entitlements)
            except (ValueError, plistlib.InvalidFileException):
                error = 'could not inspect signed entitlements'
            if error: errors.append(f'{relative}: {error}')
            count += 1
    if not count: errors.append('no Mach-O files checked')
    for error in errors: print('FAIL entitlement gate: '+error)
    print(f'Entitlement gate: {"FAIL" if errors else "PASS"} ({count} Mach-O files)')
    return int(bool(errors))

if __name__ == '__main__':
    sys.exit(check(Path(sys.argv[1]).resolve()))
