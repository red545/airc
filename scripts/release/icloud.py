#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""iCloud sync in a release (docs/release.md, "iCloud sync"): the Developer ID provisioning profile and the main app's
CloudKit entitlements.

  icloud.py prepare APP WORKDIR   if a profile in $AIRC_ICLOUD_PROFILE_DIR (default ~/arcfork/secrets) matches APP's
                                  bundle ID: embed it as Contents/embedded.provisionprofile and print the path of the
                                  entitlements to add to the main app; otherwise print nothing (the release is unchanged)
  icloud.py verify APP            the signed main app's entitlements are all granted by its embedded profile, and no
                                  nested code has iCloud or Keychain entitlements

Team and application identifiers come from the profile at build time and are never printed or committed.
"""
import datetime
import fnmatch
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

CONTAINERS = 'com.apple.developer.icloud-container-identifiers'
SERVICES = 'com.apple.developer.icloud-services'
ENVIRONMENT = 'com.apple.developer.icloud-container-environment'
APP_ID = 'com.apple.application-identifier'
TEAM_ID = 'com.apple.developer.team-identifier'
KEYCHAIN = 'keychain-access-groups'
PUSH = 'com.apple.developer.aps-environment'
# Entitlements only a provisioning profile can grant; helpers must have none of them.
RESTRICTED = (CONTAINERS, SERVICES, ENVIRONMENT, APP_ID, TEAM_ID, KEYCHAIN, PUSH,
              'com.apple.developer.web-browser.public-key-credential')
MACHO = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


class ProfileError(Exception):
    pass


def decode(path):
    """The profile's plist (a CMS-signed message; `security` checks the signature)."""
    result = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
    if result.returncode:
        raise ProfileError(f'{pathlib.Path(path).name}: not a readable provisioning profile')
    return plistlib.loads(result.stdout)


def team(profile):
    teams = profile.get('TeamIdentifier') or []
    if len(teams) != 1 or not teams[0]:
        raise ProfileError('the profile has no single team')
    return teams[0]


def matches(profile, bundle_id, now):
    """Why this profile can't sign `bundle_id` for Developer ID with CloudKit, or None when it can."""
    ents = profile.get('Entitlements', {})
    try:
        t = team(profile)
    except ProfileError as e:
        return str(e)
    if ents.get(APP_ID, ents.get('application-identifier')) != f'{t}.{bundle_id}':
        return 'another app ID'
    if not profile.get('ProvisionsAllDevices') or profile.get('ProvisionedDevices'):
        return 'not a Developer ID profile'
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=None) <= now:
        return 'expired'
    if f'iCloud.{bundle_id}' not in (ents.get(CONTAINERS) or []):
        return f'no iCloud.{bundle_id} container'
    services = ents.get(SERVICES) or []
    if 'CloudKit' not in services and '*' not in services:
        return 'no CloudKit'
    return None


def select(candidates, bundle_id, now=None):
    """The newest matching (path, profile) of `candidates`, or None, with the reasons the others didn't match."""
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    good, reasons = [], []
    for path, profile in candidates:
        why = matches(profile, bundle_id, now)
        if why:
            reasons.append(f'{pathlib.Path(path).name}: {why}')
        else:
            good.append((profile.get('CreationDate') or datetime.datetime.min, path, profile))
    if not good:
        return None, reasons
    good.sort(key=lambda g: g[0].replace(tzinfo=None))
    return (good[-1][1], good[-1][2]), reasons


def entitlements(profile, bundle_id, environment='Production'):
    """The main app's iCloud entitlements, as the profile grants them."""
    t = team(profile)
    granted = profile.get('Entitlements', {})
    environments = granted.get(ENVIRONMENT)
    if environments is not None:
        allowed = environments if isinstance(environments, list) else [environments]
        if environment not in allowed:
            raise ProfileError(f'the profile does not allow the {environment} CloudKit environment')
    ents = {
        APP_ID: f'{t}.{bundle_id}',
        TEAM_ID: t,
        CONTAINERS: [f'iCloud.{bundle_id}'],
        SERVICES: ['CloudKit'],
        ENVIRONMENT: environment,
        # The synchronizable group key (iCloud Keychain) lives in the app's own access group.
        KEYCHAIN: [f'{t}.{bundle_id}'],
    }
    # Silent pushes for the sidebar zone when the App ID has Push Notifications; otherwise the app polls.
    if PUSH in granted:
        ents[PUSH] = 'production'
    for key, value in ents.items():
        if not allows(granted, key, value):
            raise ProfileError(f'the profile does not grant {key}')
    return ents


def allows(granted, key, value):
    """A signed entitlement value is within what the profile grants (lists may use the profile's `*` patterns)."""
    if key not in granted:
        return False
    have = granted[key]
    if key in (ENVIRONMENT, PUSH):
        return value in (have if isinstance(have, list) else [have])
    if isinstance(value, list):
        patterns = have if isinstance(have, list) else [have]
        return all(any(fnmatch.fnmatchcase(v, p) for p in patterns) for v in value)
    if isinstance(have, str) and isinstance(value, str):
        return fnmatch.fnmatchcase(value, have)
    return have == value


def bundle_id(app):
    with open(pathlib.Path(app) / 'Contents/Info.plist', 'rb') as f:
        return plistlib.load(f)['CFBundleIdentifier']


def prepare(app, workdir):
    app = pathlib.Path(app)
    folder = pathlib.Path(os.path.expanduser(os.environ.get('AIRC_ICLOUD_PROFILE_DIR', '~/arcfork/secrets')))
    bid = bundle_id(app)
    candidates = []
    for path in sorted(folder.glob('*.provisionprofile')) if folder.is_dir() else []:
        try:
            candidates.append((path, decode(path)))
        except ProfileError as e:
            print(f'iCloud: skipped {e}', file=sys.stderr)
    chosen, reasons = select(candidates, bid)
    if not chosen:
        detail = f' ({"; ".join(reasons)})' if reasons else ''
        print(f'iCloud: no Developer ID provisioning profile for {bid}{detail}; this release has no iCloud sync', file=sys.stderr)
        return None
    path, profile = chosen
    environment = os.environ.get('AIRC_ICLOUD_ENVIRONMENT', 'Production')
    ents = entitlements(profile, bid, environment)
    target = app / 'Contents/embedded.provisionprofile'
    if target.exists() and target.read_bytes() != path.read_bytes():
        raise ProfileError('the app already embeds a different provisioning profile')
    shutil.copyfile(path, target)
    out = pathlib.Path(workdir) / 'icloud.entitlements.plist'
    out.write_bytes(plistlib.dumps(ents))
    print(f'iCloud: embedded the provisioning profile for {bid} (CloudKit, {environment})', file=sys.stderr)
    return out


def signed_entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True)
    if result.returncode:
        raise ProfileError(f'could not read the entitlements of {path.name}')
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def check(app, main, profile, nested, leaf=None):
    """Errors for the main app's signed entitlements against the profile, for nested code ({relative: ents}), and for
    the signing certificate (`leaf`, DER) the profile must contain: otherwise macOS refuses to launch the app (AMFI
    "No matching profile found") although every signature check passes."""
    errors = []
    if leaf is not None and leaf not in (profile.get('DeveloperCertificates') or []):
        errors.append('the profile was made for another Developer ID certificate: regenerate it with the one this '
                      'Mac signs with (the release would not launch)')
    granted = profile.get('Entitlements', {})
    for key in RESTRICTED:
        if key in main and not allows(granted, key, main[key]):
            errors.append(f'the main app has {key} the profile does not grant')
    for key in (CONTAINERS, SERVICES, ENVIRONMENT, APP_ID, KEYCHAIN):
        if key not in main:
            errors.append(f'the main app lacks {key}')
    if main.get(ENVIRONMENT) not in (None, 'Production') and os.environ.get('AIRC_ICLOUD_ENVIRONMENT', 'Production') == 'Production':
        errors.append('a release must use the Production CloudKit environment')
    for relative, ents in sorted(nested.items()):
        bad = sorted(k for k in ents if k in RESTRICTED)
        if bad:
            errors.append(f'{relative} has {", ".join(bad)} (only the main app may)')
    return errors


def signing_leaf(app):
    """The DER of the certificate that signed `app` (codesign --extract-certificates)."""
    with tempfile.TemporaryDirectory() as d:
        result = subprocess.run(['codesign', '-d', f'--extract-certificates={d}/cert', str(app)], capture_output=True)
        leaf = pathlib.Path(d) / 'cert0'
        if result.returncode or not leaf.is_file():
            raise ProfileError('could not read the signing certificate')
        return leaf.read_bytes()


def verify(app):
    app = pathlib.Path(app)
    embedded = app / 'Contents/embedded.provisionprofile'
    if not embedded.is_file():
        print('FAIL iCloud: no embedded.provisionprofile')
        return 1
    profile = decode(embedded)
    executable = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    main = signed_entitlements(app)
    nested = {}
    for root, dirs, files in os.walk(app, followlinks=False):
        dirs[:] = [d for d in dirs if not (pathlib.Path(root) / d).is_symlink()]
        for name in files:
            path = pathlib.Path(root) / name
            if path.is_symlink() or path == executable:
                continue
            with path.open('rb') as f:
                if f.read(4) not in MACHO:
                    continue
            nested[str(path.relative_to(app))] = signed_entitlements(path)
    errors = check(app, main, profile, nested, signing_leaf(app))
    for e in errors:
        print('FAIL iCloud: ' + e)
    print(f'iCloud entitlement gate: {"FAIL" if errors else "PASS"} (main app and {len(nested)} nested Mach-O files)')
    return int(bool(errors))


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'prepare':
        try:
            out = prepare(sys.argv[2], sys.argv[3])
        except ProfileError as e:
            sys.exit(f'iCloud: {e}')
        if out:
            print(out)
    elif len(sys.argv) == 3 and sys.argv[1] == 'verify':
        try:
            sys.exit(verify(sys.argv[2]))
        except ProfileError as e:
            sys.exit(f'FAIL iCloud: {e}')
    else:
        sys.exit(__doc__)
