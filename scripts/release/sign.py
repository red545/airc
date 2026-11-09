#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Sign real files inside out; never traverse framework symlink aliases."""
import os, pathlib, plistlib, stat, subprocess, sys, tempfile
from entitlement_policy import is_cdm_helper_bundle
import icloud
import passkeys
app = pathlib.Path(sys.argv[1]).resolve()
identity = sys.argv[2]
keychain = os.environ.get('AIRC_SIGN_KEYCHAIN') if identity != '-' else None
if keychain:
    keychain = os.path.expanduser(keychain)
    password_file = os.environ.get('AIRC_SIGN_KEYCHAIN_PASSWORD_FILE')
    if not password_file:
        sys.exit('AIRC_SIGN_KEYCHAIN requires AIRC_SIGN_KEYCHAIN_PASSWORD_FILE')
    password_file = pathlib.Path(password_file).expanduser()
    st = password_file.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o777 != 0o600 or st.st_uid != os.getuid():
        sys.exit('The signing password must be an owned mode-600 regular file')
    # Do not log the password or put it in the environment. security requires -p.
    result = subprocess.run(['security', 'unlock-keychain', '-p', password_file.read_text().rstrip('\n'),
                             keychain], capture_output=True)
    if result.returncode:
        sys.exit('Could not unlock the signing keychain')
config = pathlib.Path(__file__).resolve().parents[2] / 'infra/release'

def sign(path, ent=None):
    args = ['codesign', '--force', '--sign', identity,
            '--timestamp=none' if identity == '-' else '--timestamp']
    if path.suffix != '.dmg': args += ['--options', 'runtime']
    if keychain: args += ['--keychain', keychain]
    if ent: args += ['--entitlements', str(ent)]
    result = subprocess.run(args + [str(path)], capture_output=True)
    if result.returncode:
        sys.exit(f'codesign failed for {path.name} (exit {result.returncode}); inspect locally without logging credentials')

# Reuse the same immediate unlock for the DMG; notarization may outlast the
# keychain's automatic lock timeout. DMGs have no executable entitlements.
if app.suffix == '.dmg':
    sign(app)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    sys.exit(0)

embedded = app / 'Contents/embedded.provisionprofile'
profile = None
passkey_entitlements = {}
if embedded.is_file():
    if identity == '-':
        sys.exit('A provisioning profile requires Developer ID signing')
    try:
        profile = icloud.decode(embedded)
        passkey_entitlements = passkeys.entitlements(profile, icloud.bundle_id(app))
    except icloud.ProfileError as error:
        sys.exit(str(error))

with tempfile.TemporaryDirectory(dir=app.parent, prefix='.entitlements-') as tmp:
    ents = {}
    for kind in ('app', 'renderer', 'gpu', 'helper', 'cdm-helper'):
        source = config / (kind + '.entitlements.plist')
        if kind == 'cdm-helper':
            source = config.parents[1] / 'engine/cdm-helper.entitlements.plist'
        data = plistlib.loads(source.read_bytes())
        if identity == '-': data['com.apple.security.cs.disable-library-validation'] = True
        if kind == 'app': data.update(passkey_entitlements)
        # Profile-granted extras for the main app only: passkeys, and iCloud sync (icloud.py prepare). One profile must
        # grant both; list values such as keychain-access-groups are merged, not replaced.
        for variable, what in (('AIRC_PASSKEY_ENTITLEMENTS', 'Passkeys'), ('AIRC_ICLOUD_ENTITLEMENTS', 'iCloud sync')):
            if kind != 'app' or not os.environ.get(variable):
                continue
            if identity == '-' or not (app/'Contents/embedded.provisionprofile').is_file():
                sys.exit(f'{what} requires Developer ID and embedded.provisionprofile')
            for key, value in plistlib.loads(pathlib.Path(os.environ[variable]).read_bytes()).items():
                if isinstance(value, list) and isinstance(data.get(key), list):
                    data[key] = data[key] + [v for v in value if v not in data[key]]
                else:
                    data[key] = value
        if kind == 'app' and profile is not None:
            try:
                passkeys.validate(profile, data)
            except icloud.ProfileError as error:
                sys.exit(str(error))
        if identity != '-' and kind != 'cdm-helper' and data.get('com.apple.security.cs.disable-library-validation'):
            sys.exit('Developer ID entitlements must not disable library validation')
        ents[kind] = pathlib.Path(tmp)/f'{kind}.plist'
        ents[kind].write_bytes(plistlib.dumps(data))
    bundles = []
    for root, dirs, files in os.walk(app, followlinks=False):
        p = pathlib.Path(root)
        if p != app and p.suffix in ('.app', '.framework', '.xpc', '.bundle'): bundles.append(p)
        for name in files:
            f = p/name
            if f.is_symlink(): continue
            with f.open('rb') as stream: magic = stream.read(4)
            if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
                sign(f, ents['helper'])
    for p in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        kind = 'renderer' if 'Renderer' in p.name else 'gpu' if '(GPU)' in p.name else 'helper'
        if is_cdm_helper_bundle(p.relative_to(app)):
            kind = 'cdm-helper'
        sign(p, ents[kind] if p.suffix != '.framework' else None)
    sign(app, ents['app'])
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
if identity != '-':
    subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('check-entitlements.py')), str(app)], check=True)

if profile is not None:
    if icloud.signing_leaf(app) not in profile.get('DeveloperCertificates', []):
        sys.exit('The embedded profile was issued for another signing certificate')
    passkeys.validate(profile, icloud.signed_entitlements(app))
