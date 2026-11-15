# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

here = Path(__file__).parent
def load(name):
    spec = importlib.util.spec_from_file_location(name, here/f'{name}.py')
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
w = load('whatsnew')

NOTES = """# Airc 0.2.0 public beta

Intro.

## New since 0.1.9

- **Right-click menus on web pages.** Body text
  continued.
- **Open Link in Space, in every link menu.** Body.
- **A `code` title, with a long tail after its comma.** Body.
- **Right-click menus on web pages.** A duplicate.
- **Five.** x
- **Six.** x
- **Seven.** x
- **Eight.** x
- **Nine.** x

## Included from 0.1.9

- **Older thing.** Body.
"""

class WhatsNewScriptTests(unittest.TestCase):
    def test_extracts_short_titles_details_icons_and_cap(self):
        lines = w.extract(NOTES, overrides={'Right-click menus on web pages': 'Right-click menus'})
        self.assertEqual(len(lines), 7)   # wnactions: the cap is 7 (8 unique bullets here)
        self.assertEqual(w.MAX_PER_RELEASE, 7)
        self.assertEqual(lines[-1]['lead'], 'Eight')
        self.assertEqual(lines[0], {'title': 'Right-click menus', 'lead': 'Right-click menus on web pages',
                                    'detail': 'Body text continued.', 'icon': 'contextualmenu.and.cursorarrow'})
        # By rule: cut at the comma.
        self.assertEqual(lines[1]['title'], 'Open Link in Space')
        self.assertEqual(lines[1]['icon'], 'square.stack.3d.up')
        self.assertEqual(lines[2]['title'], 'A code title')
        self.assertNotIn('`', lines[2]['lead'])
        self.assertEqual([l['lead'] for l in lines].count('Right-click menus on web pages'), 1)
        self.assertEqual(w.extract(NOTES, 'Included from 0.1.9', overrides={}),
                         [{'title': 'Older thing', 'lead': 'Older thing', 'detail': 'Body.', 'icon': 'sparkles'}])

    def test_fails_on_a_title_over_26_characters(self):
        with self.assertRaises(SystemExit) as e:
            w.extract(NOTES, overrides={})   # "Right-click menus on web pages" is 30 and no rule shortens it
        self.assertIn('whatsnew-titles.json', str(e.exception))
        with self.assertRaises(SystemExit):
            w.extract(NOTES, overrides={'Right-click menus on web pages': 'An override that is still far too long'})
        self.assertEqual(w.short_title('Your Spaces now sync instantly', {}), 'Spaces now sync instantly')   # "Your" dropped
        self.assertEqual(w.short_title('Your Spaces are kept', {}), 'Your Spaces are kept')   # fits: unchanged

    def test_every_override_and_bundled_title_fits(self):
        for lead, title in w.load_titles().items():
            self.assertLessEqual(len(title), w.TITLE_MAX, lead)
        for r in w.load()['releases']:
            for h in r['highlights']:
                self.assertLessEqual(len(h['title']), w.TITLE_MAX, h)
                self.assertIn('lead', h)
                if w.require_detail(r['version']):
                    self.assertTrue(h.get('detail'), h)

    def test_details_actions_and_images(self):
        notes = """## New since 0.1.20

- **More app icons.** Settings › Appearance › App Icon now has six icons. The Finder shows your choice too. And a
  third sentence that is cut.
- **Boosts, reviewed.** A Boost's code shows first.
- **Nothing after it.**
"""
        with tempfile.TemporaryDirectory() as tmp:
            img = Path(tmp)
            (img/'settings-app-icon.heic').write_bytes(b'x')
            with self.assertRaises(SystemExit) as e:   # the third bullet has no text: no detail, the release fails
                w.extract(notes, overrides={}, image_dir=img)
            self.assertIn('no detail', str(e.exception))
            lines = w.extract(notes, overrides={'Nothing after it': {'detail': 'Now it has one.', 'action': 'sendFeedback'}}, image_dir=img)
        self.assertEqual(lines[0]['detail'], 'Settings › Appearance › App Icon now has six icons. The Finder shows your choice too.')
        self.assertEqual(lines[0]['action'], 'settingsAppIcon')
        self.assertEqual(lines[0]['image'], 'settings-app-icon')   # guessed and present
        self.assertEqual(lines[1]['action'], 'settingsBoosts')
        self.assertNotIn('image', lines[1])                       # boost-import.heic isn't in this folder
        self.assertEqual(lines[2], {'title': 'Nothing after it', 'lead': 'Nothing after it', 'detail': 'Now it has one.',
                                    'icon': 'sparkles', 'action': 'sendFeedback'})
        long = w.default_detail(' ' + 'word ' * 80 + 'end.')
        self.assertLessEqual(len(long), w.DETAIL_MAX)
        self.assertTrue(long.endswith('…'))

    def test_new_actions_and_explicit_none(self):
        notes = """## New since 0.1.20

- **Tidy Downloads renames.** Turn on Rename automatically in Settings › AI › Downloads.
- **Edit and Help shortcuts.** Every menu command has a keyboard shortcut now, in Settings › Shortcuts.
- **Dark mode reads better.** Text in dark mode meets standard contrast. Settings › General has nothing to do with it.
- **Search shortcuts come over.** Your search shortcuts become Site Search entries.
"""
        with tempfile.TemporaryDirectory() as tmp:
            lines = w.extract(notes, overrides={'Dark mode reads better': {'action': 'none'}}, image_dir=Path(tmp))
            self.assertEqual([l.get('action') for l in lines], ['settingsAI', 'settingsShortcuts', None, None])
            self.assertNotIn('action', lines[2])   # "none": no key at all, not the guessed settingsGeneral
            # null in the titles file means the same.
            self.assertNotIn('action', w.extract(notes, overrides={'Dark mode reads better': {'action': None}}, image_dir=Path(tmp))[2])
            # Without the override the guess would have been misleading.
            self.assertEqual(w.extract(notes, overrides={}, image_dir=Path(tmp))[2].get('action'), 'settingsGeneral')
            with self.assertRaises(SystemExit) as e:
                w.extract(notes, overrides={'Dark mode reads better': {'action': 'nothing'}}, image_dir=Path(tmp))
            self.assertIn('"none"', str(e.exception))
        # "none" is a titles-file word only: WhatsNew.json never carries it, and the app has no such action.
        self.assertNotIn(w.NO_ACTION, w.ACTIONS)
        bad = {'schema': 1, 'releases': [{'version': '0.1.20', 'highlights': [{'title': 'A', 'detail': 'd', 'icon': 'x', 'action': 'none'}]}]}
        self.assertTrue(any('action' in e for e in w.validate(bad)))

    def test_seven_lines_validate_eight_do_not(self):
        h = lambda i: {'title': f'Line {i}', 'detail': 'A sentence.', 'icon': 'sparkles'}
        doc = lambda n: {'schema': 1, 'releases': [{'version': '0.1.20', 'highlights': [h(i) for i in range(n)]}]}
        self.assertEqual(w.validate(doc(7)), [])
        self.assertNotEqual(w.validate(doc(8)), [])

    def test_action_whitelist_matches_the_app(self):
        swift = (here/'../../packages/AircKit/Sources/AircKit/WhatsNew.swift').read_text()
        body = swift[swift.index('public enum WhatsNewAction'):]
        body = body[:body.index('public var buttonTitle')]
        import re
        self.assertEqual(re.findall(r'^\s+case (\w+)', body, re.M), w.ACTIONS)
        for _, a in w.ACTION_RULES:
            self.assertIn(a, w.ACTIONS)
        bad = {'schema': 1, 'releases': [{'version': '0.1.20', 'highlights': [{'title': 'A', 'detail': 'd', 'icon': 'x', 'action': 'openURL'}]}]}
        self.assertTrue(any('action' in e for e in w.validate(bad)))

    def test_update_keeps_hand_picked_icons_and_sorts(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'WhatsNew.json'
            w.update('0.1.9', NOTES, 'Included from 0.1.9', p)
            doc = json.loads(p.read_text())
            doc['releases'][0]['highlights'][0]['icon'] = 'star'
            p.write_text(json.dumps(doc))
            notes = NOTES.replace('- **Five.** x', '- **Older thing.** again')
            w.update('0.2.0', notes, None, p)
            doc = json.loads(p.read_text())
            self.assertEqual([r['version'] for r in doc['releases']], ['0.2.0', '0.1.9'])
            self.assertIn({'title': 'Older thing', 'lead': 'Older thing', 'detail': 'again', 'icon': 'star'}, doc['releases'][0]['highlights'])
            w.update('0.2.0', NOTES, None, p)   # rerun replaces, never duplicates
            self.assertEqual(len(json.loads(p.read_text())['releases']), 2)

    def test_schema(self):
        good = {'schema': 1, 'releases': [{'version': '0.1.12', 'highlights': [{'title': 'A', 'detail': 'A longer A', 'icon': 'sparkles'}]}]}
        self.assertEqual(w.validate(good), [])
        for bad in [{'schema': 2, 'releases': []},
                    {'schema': 1, 'releases': [{'version': 'next', 'highlights': [{'title': 'A', 'icon': 'x'}]}]},
                    {'schema': 1, 'releases': [{'version': '0.1.1', 'highlights': []}]},
                    {'schema': 1, 'releases': [{'version': '0.1.1', 'highlights': [{'title': 'x' * 27, 'icon': 'x'}]}]},
                    {'schema': 1, 'releases': [{'version': '0.1.1', 'highlights': [{'title': 'A', 'icon': 'Bad Icon'}]}]},
                    {'schema': 1, 'releases': [{'version': '0.1.1', 'highlights': [{'title': 'A', 'icon': 'x', 'extra': 1}]}]},
                    # From 0.1.13 every line needs a detail (the What's new tab), at most 280 characters.
                    {'schema': 1, 'releases': [{'version': '0.1.13', 'highlights': [{'title': 'A', 'icon': 'x'}]}]},
                    {'schema': 1, 'releases': [{'version': '0.1.13', 'highlights': [{'title': 'A', 'detail': 'x' * 281, 'icon': 'x'}]}]},
                    {'schema': 1, 'releases': [{'version': '0.1.13', 'highlights': [{'title': 'A', 'detail': 'd', 'icon': 'x', 'image': 'no-such-picture'}]}]}]:
            self.assertNotEqual(w.validate(bad), [], bad)

    def test_bundled_resource_is_valid_and_backfilled(self):
        doc = w.load()
        self.assertEqual(w.validate(doc), [])
        versions = [r['version'] for r in doc['releases']]
        for v in ('0.1.10', '0.1.11', '0.1.12', '0.1.13', '0.1.14', '0.1.15'):
            self.assertIn(v, versions)
        self.assertEqual(versions, sorted(versions, key=w.version_key, reverse=True))

    def test_manifest_appcast_carries_highlights(self):
        m = load('manifest')
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.2.0', CFBundleVersion='202611131200',
                                                            AircRevision='a'*40, LSMinimumSystemVersion='14.0')))
            (p/'Airc-0.2.0.dmg').write_bytes(b'dmg'); (p/'Airc-0.2.0.zip').write_bytes(b'zip')
            (p/'signature.json').write_text(json.dumps(dict(signature='s', size=3)))
            (p/'deltas.json').write_text('[]')
            notes = p/'notes.src.md'; notes.write_text(NOTES.replace('**Right-click menus on web pages.**', '**Right-click menus.**'))
            m.generate(p, notes, 'stable', True)
            item = ET.parse(p/'appcast.xml').find('./channel/item')
            text = item.findtext('{'+w.NS+'}highlights')
            lines = json.loads(text)
            self.assertEqual(len(lines), 3)
            self.assertEqual(lines[0]['title'], 'Right-click menus')
            self.assertEqual(set(lines[0]), {'title', 'lead', 'detail', 'icon'})   # the lead-in, not the page's detail
            self.assertEqual(lines[0]['detail'], lines[0]['lead'])
            self.assertTrue(all(len(l['title']) <= w.TITLE_MAX for l in lines))
            self.assertIn('xmlns:airc=', (p/'appcast.xml').read_text())
            # Notes without a "New since" section: no element, nothing else changes.
            notes.write_text('# Notes\n\n- plain\n')
            m.generate(p, notes, 'stable', True)
            self.assertIsNone(ET.parse(p/'appcast.xml').find('./channel/item').find('{'+w.NS+'}highlights'))

    # A fixture release whose hand-picked icons differ from icon_for's guess (0.1.17 shipped the guesses: promptic).
    PICKED = {'schema': 1, 'releases': [{'version': '0.2.0', 'highlights': [
        {'title': 'Right-click menus', 'lead': 'Right-click menus on web pages', 'detail': 'd', 'icon': 'cursorarrow.click'},
        {'title': 'Open Link in Space', 'lead': 'Open Link in Space, in every link menu', 'detail': 'd', 'icon': 'star'},
        {'title': 'A code title', 'lead': 'A code title, with a long tail after its comma', 'detail': 'd', 'icon': 'curlybraces'}]}]}

    def stage(self, p, version='0.2.0'):
        (p/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=version, CFBundleVersion='202611131200',
                                                        AircRevision='a'*40, LSMinimumSystemVersion='14.0')))
        (p/f'Airc-{version}.dmg').write_bytes(b'dmg'); (p/f'Airc-{version}.zip').write_bytes(b'zip')
        (p/'signature.json').write_text(json.dumps(dict(signature='s', size=3)))
        (p/'deltas.json').write_text('[]')

    def appcast_icons(self, p):
        return [l['icon'] for l in json.loads(ET.parse(p/'appcast.xml').find('./channel/item').findtext('{'+w.NS+'}highlights'))]

    def test_appcast_uses_the_staged_apps_hand_picked_icons(self):
        guessed = [w.icon_for(h['lead']) for h in self.PICKED['releases'][0]['highlights']]
        picked = [h['icon'] for h in self.PICKED['releases'][0]['highlights']]
        self.assertTrue(all(a != b for a, b in zip(guessed, picked)), guessed)   # the fixture really disagrees
        m = load('manifest')
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); self.stage(p)
            notes = p/'notes.src.md'; notes.write_text(NOTES)
            # worker.sh keeps the app in package/ while manifest.py runs; nothing in the tooling tree has 0.2.0.
            res = p/'package/Airc.app/Contents/Resources/WhatsNew.json'
            res.parent.mkdir(parents=True); res.write_text(json.dumps(self.PICKED))
            m.generate(p, notes, 'stable', True)   # default resource list
            self.assertEqual(self.appcast_icons(p), picked)
            # A Linux regeneration (no app in the stage) reads the tree's WhatsNew.json instead.
            tree = p/'tree-WhatsNew.json'; res.rename(tree)
            m.generate(p, notes, 'stable', True, [p/'package/Airc.app/Contents/Resources/WhatsNew.json', tree])
            self.assertEqual(self.appcast_icons(p), picked)
            # No WhatsNew.json at all: the guess, as before.
            m.generate(p, notes, 'stable', True, [])
            self.assertEqual(self.appcast_icons(p), guessed)

    def test_appcast_matches_icons_per_line_and_guesses_only_the_rest(self):
        # The release has no entry of its own: each notes line takes the icon of a WhatsNew.json line with the same
        # lead-in (or, failing that, the same title); a line nobody picked an icon for keeps the guess.
        doc = {'schema': 1, 'releases': [{'version': '0.1.9', 'highlights': [
            {'title': 'Right-click menus', 'lead': 'Right-click menus on web pages', 'detail': 'd', 'icon': 'cursorarrow.click'},
            {'title': 'A code title', 'lead': 'Something else entirely', 'detail': 'd', 'icon': 'curlybraces'}]}]}
        with tempfile.TemporaryDirectory() as tmp:
            r = Path(tmp)/'WhatsNew.json'; r.write_text(json.dumps(doc))
            lines = w.appcast_lines('0.2.0', NOTES, [Path(tmp)/'missing.json', r])
        self.assertEqual([l['icon'] for l in lines],
                         ['cursorarrow.click', w.icon_for('Open Link in Space, in every link menu'), 'curlybraces'])

    def test_0_1_17_appcast_icons_match_its_whatsnew_entry(self):
        # The shipped 0.1.17 notes, regenerated as manifest.py on Linux would (no app in the stage).
        notes = (w.ROOT/'apps/marketing/src/content/changelog/0.1.17.md')
        if not notes.exists():
            self.skipTest('no 0.1.17 changelog')
        entry = next(r for r in w.load()['releases'] if r['version'] == '0.1.17')['highlights'][:w.APPCAST_LINES]
        lines = w.appcast_lines('0.1.17', notes.read_text(), [w.RESOURCE])
        self.assertEqual([(l['title'], l['icon']) for l in lines], [(h['title'], h['icon']) for h in entry])
        self.assertIn('calendar', [l['icon'] for l in lines])          # 0.1.17's appcast said rectangle.on.rectangle
        # And from the notes alone (an entry under another version), still the hand-picked icons.
        other = {'schema': 1, 'releases': [dict(r, version='9.9.9') for r in w.load()['releases'] if r['version'] == '0.1.17']}
        with tempfile.TemporaryDirectory() as tmp:
            r = Path(tmp)/'WhatsNew.json'; r.write_text(json.dumps(other))
            self.assertEqual([l['icon'] for l in w.appcast_lines('0.1.17', notes.read_text(), [r])], [h['icon'] for h in entry])

if __name__ == '__main__':
    unittest.main()
