#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Derive passkey entitlements from the embedded Developer ID profile only."""
import datetime
import icloud

BROWSER = 'com.apple.developer.web-browser.public-key-credential'


def entitlements(profile, bundle_id):
    t = icloud.team(profile)
    granted = profile.get('Entitlements', {})
    if granted.get(icloud.APP_ID) != f'{t}.{bundle_id}':
        raise icloud.ProfileError('passkeys: provisioning profile belongs to another app')
    if not profile.get('ProvisionsAllDevices') or profile.get('ProvisionedDevices'):
        raise icloud.ProfileError('passkeys: a Developer ID provisioning profile is required')
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=None) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise icloud.ProfileError('passkeys: expired provisioning profile')
    result = {icloud.APP_ID: f'{t}.{bundle_id}', icloud.TEAM_ID: t}
    group = f'{t}.{bundle_id}.webauthn'
    if icloud.allows(granted, icloud.KEYCHAIN, [group]):
        result[icloud.KEYCHAIN] = [group]
    if granted.get(BROWSER) is True:
        result[BROWSER] = True
    validate(profile, result)
    return result


def validate(profile, entitlements):
    """Reject manual extras outside the profile before signing any nested code."""
    if BROWSER in entitlements and entitlements[BROWSER] is not True:
        raise icloud.ProfileError('passkeys: omit the browser entitlement when unavailable')
    for key in icloud.RESTRICTED:
        if key in entitlements and not icloud.allows(profile.get('Entitlements', {}), key, entitlements[key]):
            raise icloud.ProfileError(f'passkeys: profile does not grant {key}')
