# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import contextlib
import datetime
import io
import os
import pathlib
import plistlib
import shutil
import tempfile
import unittest
import icloud

BUNDLE = 'com.example.Browser'
TEAM = 'TEAMID0000'   # synthetic: real team identifiers never go in the repo


def profile(**changes):
    p = {
        'TeamIdentifier': [TEAM], 'ProvisionsAllDevices': True,
        'CreationDate': datetime.datetime(2026, 11, 7), 'ExpirationDate': datetime.datetime(2044, 11, 7),
        'Entitlements': {
            icloud.APP_ID: f'{TEAM}.{BUNDLE}', icloud.TEAM_ID: TEAM,
            icloud.CONTAINERS: [f'iCloud.{BUNDLE}'], icloud.SERVICES: '*',
            icloud.ENVIRONMENT: ['Development', 'Production'], icloud.KEYCHAIN: [f'{TEAM}.*'],
        },
    }
    for k, v in changes.items():
        if k.startswith('e_'):
            key = {'e_services': icloud.SERVICES, 'e_containers': icloud.CONTAINERS, 'e_app': icloud.APP_ID,
                   'e_push': icloud.PUSH, 'e_env': icloud.ENVIRONMENT, 'e_keychain': icloud.KEYCHAIN}[k]
            if v is None: p['Entitlements'].pop(key, None)
            else: p['Entitlements'][key] = v
        elif v is None: p.pop(k, None)
        else: p[k] = v
    return p


class ProfileSelectionTest(unittest.TestCase):
    NOW = datetime.datetime(2026, 11, 8)

    def test_only_a_current_developer_id_profile_for_this_app_with_cloudkit(self):
        cases = {
            'other-app': profile(e_app=f'{TEAM}.com.example.Other'),
            'development': profile(ProvisionsAllDevices=None, ProvisionedDevices=['00008000-0000']),
            'expired': profile(ExpirationDate=datetime.datetime(2026, 1, 1)),
            'no-container': profile(e_containers=['iCloud.com.example.Other']),
            'no-cloudkit': profile(e_services=['CloudDocuments']),
        }
        for name, p in cases.items():
            with self.subTest(name):
                chosen, reasons = icloud.select([(name + '.provisionprofile', p)], BUNDLE, self.NOW)
                self.assertIsNone(chosen)
                self.assertEqual(len(reasons), 1)
        old, new = profile(CreationDate=datetime.datetime(2026, 1, 1)), profile()
        chosen, _ = icloud.select([('old.provisionprofile', old), ('new.provisionprofile', new)], BUNDLE, self.NOW)
        self.assertEqual(chosen[0], 'new.provisionprofile')
        self.assertEqual(icloud.select([], BUNDLE, self.NOW), (None, []))

    def test_entitlements_come_from_the_profile(self):
        ents = icloud.entitlements(profile(), BUNDLE)
        self.assertEqual(ents[icloud.CONTAINERS], [f'iCloud.{BUNDLE}'])
        self.assertEqual(ents[icloud.SERVICES], ['CloudKit'])
        self.assertEqual(ents[icloud.ENVIRONMENT], 'Production')
        self.assertEqual(ents[icloud.KEYCHAIN], [f'{TEAM}.{BUNDLE}'])
        self.assertEqual(ents[icloud.APP_ID], f'{TEAM}.{BUNDLE}')
        self.assertNotIn(icloud.PUSH, ents)
        self.assertEqual(icloud.entitlements(profile(e_push='production'), BUNDLE)[icloud.PUSH], 'production')
        with self.assertRaises(icloud.ProfileError):
            icloud.entitlements(profile(e_env=['Development']), BUNDLE)
        with self.assertRaises(icloud.ProfileError):
            icloud.entitlements(profile(e_keychain=['OTHERTEAM.*']), BUNDLE)

    def test_push_only_when_the_profile_grants_it(self):
        without = profile()
        self.assertNotIn(icloud.PUSH, icloud.entitlements(without, BUNDLE))
        granted = profile(e_push='production')
        ents = icloud.entitlements(granted, BUNDLE)
        self.assertEqual(ents[icloud.PUSH], 'production')
        self.assertEqual(icloud.check(None, ents, granted, {}), [])
        # Signed with push but the profile doesn't grant it (a stale profile): the verify gate fails.
        self.assertTrue(any(icloud.PUSH in e for e in icloud.check(None, ents, without, {})))
        # Helpers never get it.
        helper = {'Contents/Frameworks/X.framework/Helpers/H.app/Contents/MacOS/H': {icloud.PUSH: 'production'}}
        self.assertTrue(any('only the main app' in e for e in icloud.check(None, ents, granted, helper)))

    def test_the_profile_must_contain_the_signing_certificate(self):
        # 2026-11-07: a profile made for the account's older Developer ID certificate passed every signature check, and
        # macOS refused to launch the app (AMFI -413 "No matching profile found").
        p = profile(DeveloperCertificates=[b'older certificate'])
        main = icloud.entitlements(p, BUNDLE)
        self.assertTrue(any('another Developer ID certificate' in e for e in icloud.check(None, main, p, {}, b'signing certificate')))
        p['DeveloperCertificates'].append(b'signing certificate')
        self.assertEqual(icloud.check(None, main, p, {}, b'signing certificate'), [])

    def test_a_wildcard_service_grants_cloudkit_and_the_app_still_signs_cloudkit(self):
        # The owner's Developer ID profile: services `*`, one environment as a plain string, keychain `<team>.*`, and
        # ubiquity keys the app doesn't ask for.
        for services in ('*', ['*'], ['CloudKit'], ['CloudKit', 'CloudDocuments']):
            with self.subTest(services=services):
                p = profile(e_services=services, e_env='Production')
                p['Entitlements']['com.apple.developer.ubiquity-container-identifiers'] = [f'iCloud.{BUNDLE}']
                p['Entitlements']['com.apple.developer.ubiquity-kvstore-identifier'] = f'{TEAM}.*'
                chosen, reasons = icloud.select([('owner.provisionprofile', p)], BUNDLE, ProfileSelectionTest.NOW)
                self.assertIsNotNone(chosen, reasons)
                ents = icloud.entitlements(p, BUNDLE)
                self.assertEqual(ents[icloud.SERVICES], ['CloudKit'], 'never the profile\'s wildcard')
                self.assertEqual(ents[icloud.ENVIRONMENT], 'Production')
                self.assertNotIn('com.apple.developer.ubiquity-kvstore-identifier', ents)
                self.assertEqual(icloud.check(None, ents, p, {}), [])

    def test_signature_must_stay_within_the_profile_and_off_helpers(self):
        p = profile()
        main = icloud.entitlements(p, BUNDLE)
        self.assertEqual(icloud.check(None, main, p, {'Contents/Frameworks/X.framework/Helpers/H.app/Contents/MacOS/H': {}}), [])
        wrong = dict(main, **{icloud.CONTAINERS: ['iCloud.com.example.Other']})
        self.assertTrue(any('does not grant' in e for e in icloud.check(None, wrong, p, {})))
        missing = {k: v for k, v in main.items() if k != icloud.SERVICES}
        self.assertTrue(any('lacks' in e for e in icloud.check(None, missing, p, {})))
        helper = {'Contents/Frameworks/X.framework/Helpers/H.app/Contents/MacOS/H': {icloud.CONTAINERS: main[icloud.CONTAINERS]}}
        self.assertTrue(any('only the main app' in e for e in icloud.check(None, main, p, helper)))
        dev = dict(main, **{icloud.ENVIRONMENT: 'Development'})
        self.assertTrue(any('Production' in e for e in icloud.check(None, dev, p, {})))


class PrepareTest(unittest.TestCase):
    """`icloud.py prepare` as package.sh runs it: a profile that doesn't fit is ignored with one stderr line."""

    def run_prepare(self, profiles, bundle='com.aircbrowser.Airc'):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        secrets, work, app = root / 'secrets', root / 'work', root / 'Airc.app'
        for d in (secrets, work, app / 'Contents'): d.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle}))
        decoded = {}
        for name, p in profiles.items():
            (secrets / name).write_bytes(b'cms:' + name.encode())
            decoded[name] = p
        original, env = icloud.decode, os.environ.get('AIRC_ICLOUD_PROFILE_DIR')
        icloud.decode = lambda path: decoded[pathlib.Path(path).name]
        os.environ['AIRC_ICLOUD_PROFILE_DIR'] = str(secrets)
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                result = icloud.prepare(app, work)
        finally:
            icloud.decode = original
            if env is None: os.environ.pop('AIRC_ICLOUD_PROFILE_DIR')
            else: os.environ['AIRC_ICLOUD_PROFILE_DIR'] = env
        return result, out.getvalue(), err.getvalue(), app, work

    def test_profiles_that_dont_fit_change_nothing(self):
        bundle = 'com.aircbrowser.Airc'
        def fitting(**changes):
            p = profile(**changes)
            p['Entitlements'][icloud.APP_ID] = p['Entitlements'][icloud.APP_ID].replace(BUNDLE, bundle)
            if icloud.CONTAINERS in p['Entitlements']:
                p['Entitlements'][icloud.CONTAINERS] = [c.replace(BUNDLE, bundle) for c in p['Entitlements'][icloud.CONTAINERS]]
            return p
        cases = {
            'expired': {'old.provisionprofile': fitting(ExpirationDate=datetime.datetime(2025, 1, 1))},
            'dev bundle': {'dev.provisionprofile': profile(e_app=f'{TEAM}.org.airc.Airc.dev', e_containers=['iCloud.org.airc.Airc.dev'])},
            'no CloudKit': {'nocloud.provisionprofile': fitting(e_services=None, e_containers=None)},
            'none': {},
        }
        cases['all three'] = {**cases['expired'], **cases['dev bundle'], **cases['no CloudKit']}
        for name, profiles in cases.items():
            with self.subTest(name):
                result, out, err, app, work = self.run_prepare(profiles, bundle)
                self.assertIsNone(result)
                self.assertEqual(out, '')
                self.assertEqual(len(err.splitlines()), 1, err)
                self.assertIn('this release has no iCloud sync', err)
                self.assertNotIn(TEAM, err)
                self.assertEqual(sorted(p.name for p in (app / 'Contents').iterdir()), ['Info.plist'])
                self.assertEqual(list(work.iterdir()), [])

    def test_a_fitting_profile_is_embedded_and_nothing_secret_printed(self):
        p = profile()
        result, out, err, app, work = self.run_prepare({'airc.provisionprofile': p}, BUNDLE)
        self.assertEqual(result, work / 'icloud.entitlements.plist')
        self.assertEqual((app / 'Contents/embedded.provisionprofile').read_bytes(), b'cms:airc.provisionprofile')
        self.assertEqual(plistlib.loads(result.read_bytes())[icloud.CONTAINERS], [f'iCloud.{BUNDLE}'])
        self.assertEqual(out, '')
        self.assertEqual(len(err.splitlines()), 1)
        self.assertNotIn(TEAM, err)


if __name__ == '__main__':
    unittest.main()
