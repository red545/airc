# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec=importlib.util.spec_from_file_location('manifest',Path(__file__).with_name('manifest.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class ManifestTests(unittest.TestCase):
 def test_notes_are_escaped_and_lists_closed(self):
  text=m.render('# Title\n\n- **Bold** <script>\n  continued & safe\n- second\n\nEnd `code`.')
  self.assertNotIn('<script>',text)
  self.assertIn('&lt;script&gt;',text)
  self.assertIn('<strong>Bold</strong>',text)
  self.assertEqual(text.count('<ul>'),text.count('</ul>'))
  self.assertEqual(text.count('<li>'),2)
 def test_signed_delta_feed_and_inventory(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)
   (p/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.1.0',CFBundleVersion='202611061600',AircRevision='a'*40,LSMinimumSystemVersion='14.0')))
   (p/'Airc-0.1.0.dmg').write_bytes(b'dmg'); (p/'Airc-0.1.0.zip').write_bytes(b'zip')
   (p/'Airc-202611061600-202611061500.delta').write_bytes(b'delta')
   (p/'signature.json').write_text(json.dumps(dict(signature='public-signature',size=3)))
   (p/'deltas.json').write_text(json.dumps([{'file':'Airc-202611061600-202611061500.delta','from':'202611061500','size':5,'signature':'delta-signature'}]))
   notes=p/'source.md'; notes.write_text('# Safe notes\n\n- Text')
   m.generate(p,notes,'nightly',True)
   tree=ET.parse(p/'appcast.xml'); item=tree.find('./channel/item')
   self.assertEqual(item.findtext(m.tag('channel')),'nightly')
   e=item.find(m.tag('deltas')).find('enclosure')
   self.assertEqual(e.attrib[m.tag('deltaFrom')],'202611061500')
   self.assertEqual(e.attrib[m.tag('edSignature')],'delta-signature')
   latest=json.loads((p/'latest.json').read_text())
   self.assertEqual(latest['size'],3)
   self.assertIn('/releases/0.1.0/202611061600/',latest['url'])
   release=json.loads((p/'release.json').read_text())
   self.assertNotIn('Info.plist',release['files'])
   self.assertTrue(release['qualified'])
if __name__=='__main__': unittest.main()
