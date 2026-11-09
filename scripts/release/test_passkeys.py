# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import datetime
import unittest
import icloud
import passkeys
from test_icloud import profile, TEAM, BUNDLE


class PasskeysTest(unittest.TestCase):
    def test_existing_cloudkit_profile_enables_local_not_managed_passkeys(self):
        e = passkeys.entitlements(profile(), BUNDLE)
        self.assertEqual(e[icloud.KEYCHAIN], [f'{TEAM}.{BUNDLE}.webauthn'])
        self.assertNotIn(passkeys.BROWSER, e)
        self.assertNotIn(icloud.CONTAINERS, e)

    def test_managed_entitlement_requires_boolean_grant(self):
        for grant in (True, False, 'true', None):
            p = profile()
            p['Entitlements'][passkeys.BROWSER] = grant
            self.assertEqual(passkeys.BROWSER in passkeys.entitlements(p, BUNDLE), grant is True)

    def test_exact_group_and_missing_group(self):
        p = profile(e_keychain=[f'{TEAM}.{BUNDLE}'])
        self.assertNotIn(icloud.KEYCHAIN, passkeys.entitlements(p, BUNDLE))
        p = profile(e_keychain=[f'{TEAM}.{BUNDLE}.webauthn'])
        self.assertIn(icloud.KEYCHAIN, passkeys.entitlements(p, BUNDLE))

    def test_wrong_app_expired_and_development_profiles_rejected(self):
        for p in (profile(e_app=f'{TEAM}.com.example.Other'),
                  profile(ExpirationDate=datetime.datetime(2000, 1, 1)),
                  profile(ProvisionsAllDevices=False), profile(ProvisionedDevices=['test'])):
            with self.assertRaises(icloud.ProfileError):
                passkeys.entitlements(p, BUNDLE)

    def test_manual_extras_cannot_claim_ungranted_capability(self):
        for e in ({passkeys.BROWSER: True}, {icloud.KEYCHAIN: ['OTHER.group']}):
            with self.assertRaises(icloud.ProfileError):
                passkeys.validate(profile(), e)

    def test_cloudkit_and_passkeys_groups_can_coexist(self):
        p = profile()
        e = icloud.entitlements(p, BUNDLE)
        e[icloud.KEYCHAIN] += passkeys.entitlements(p, BUNDLE)[icloud.KEYCHAIN]
        self.assertEqual(icloud.check(None, e, p, {}), [])
        self.assertTrue(icloud.check(None, e, p, {'helper': {icloud.KEYCHAIN: e[icloud.KEYCHAIN]}}))

if __name__ == '__main__':
    unittest.main()
