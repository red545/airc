# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import base64, importlib.util, json, pathlib, plistlib, subprocess, tempfile, unittest
import xml.etree.ElementTree as ET
spec=importlib.util.spec_from_file_location('publisher', pathlib.Path(__file__).with_name('publish.py'))
p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
class TestPublish(unittest.TestCase):
 def test_transaction(self):
  with tempfile.TemporaryDirectory() as tmp:
   r=pathlib.Path(tmp); s=r/'stage'; s.mkdir(); d=r/'updates'
   def run(*a): return subprocess.check_output(a,stderr=subprocess.DEVNULL)
   run('git','init','-q',str(r))
   run('git','-C',str(r),'-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','Source & notes')
   rev=run('git','-C',str(r),'rev-parse','HEAD').decode().strip()
   run('openssl','genpkey','-algorithm','ED25519','-out',str(r/'key'))
   public=base64.b64encode(run('openssl','pkey','-in',str(r/'key'),'-pubout','-outform','DER')[-32:]).decode()
   (r/'infra/release').mkdir(parents=True); (r/'infra/release/sparkle-public-key.txt').write_text(public)
   (r/'apps/browser/Resources').mkdir(parents=True)
   (r/'apps/browser/Resources/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.example.app')))
   feed='https://updates.example.invalid/dev/appcast.xml'
   for n in range(6):
    info=dict(CFBundleVersion=str(202611050100+n),CFBundleShortVersionString='0.1.0',AircDevChannel=True,SUFeedURL=feed,AircDefaultEngine='chromium',SUPublicEDKey=public,AircRevision=rev,CFBundleIdentifier='org.example.app')
    (s/'Info.plist').write_bytes(plistlib.dumps(info)); (s/'update.zip').write_bytes(b'archive fixture '+str(n).encode())
    sig=base64.b64encode(run('openssl','pkeyutl','-sign','-inkey',str(r/'key'),'-rawin','-in',str(s/'update.zip'))).decode()
    (s/'signature.txt').write_text(f'sparkle:edSignature="{sig}" length="{(s/"update.zip").stat().st_size}"\n')
    if n > 0:
     delta=s/f'Airc-{202611050100+n}-{202611050099+n}.delta'
     delta.write_bytes(b'delta fixture '+str(n).encode())
     dsig=base64.b64encode(run('openssl','pkeyutl','-sign','-inkey',str(r/'key'),'-rawin','-in',str(delta))).decode()
     (s/'deltas.json').write_text(json.dumps([{'file':delta.name,'from':str(202611050099+n),'size':delta.stat().st_size,'signature':dsig}]))
     original=delta.read_bytes(); delta.write_bytes(b'corrupt'+original[7:])
     before=(d/'dev/appcast.xml').read_bytes()
     with self.assertRaises((ValueError,subprocess.CalledProcessError)): p.publish(r,d,s,feed)
     self.assertEqual((d/'dev/appcast.xml').read_bytes(),before)
     delta.write_bytes(original)
    p.publish(r,d,s,feed)
   self.assertEqual(len(ET.parse(d/'dev/appcast.xml').findall('.//'+p.tag('deltas'))),5)
   (s/'deltas.json').unlink()
   xml=d/'dev/appcast.xml'; before=xml.read_bytes()
   self.assertEqual(len(ET.fromstring(before).findall('./channel/item')),5)
   self.assertEqual(len(list((d/'dev').glob('*.zip'))),5)
   with self.assertRaises(ValueError): p.publish(r,d,s,feed)
   info['CFBundleVersion']='202611050106'; (s/'Info.plist').write_bytes(plistlib.dumps(info))
   (s/'update.zip').write_bytes(b'corrupt fixture 5')
   with self.assertRaises((ValueError,subprocess.CalledProcessError)): p.publish(r,d,s,feed)
   self.assertEqual(xml.read_bytes(),before)
   with self.assertRaises(ValueError): p.publish(r,d,s,feed.replace('https:','http:'))
   # A test install (own identity or bundled options) never goes to the dev feed; its own proof feed takes it.
   (s/'update.zip').write_bytes(b'archive fixture 6')
   sig=base64.b64encode(run('openssl','pkeyutl','-sign','-inkey',str(r/'key'),'-rawin','-in',str(s/'update.zip'))).decode()
   (s/'signature.txt').write_text(f'sparkle:edSignature="{sig}" length="{(s/"update.zip").stat().st_size}"\n')
   for change in (dict(CFBundleIdentifier='org.example.proof'), dict(AircLaunchArguments=['--automated'])):
    (s/'Info.plist').write_bytes(plistlib.dumps({**info, **change}))
    with self.assertRaises(ValueError): p.publish(r,d,s,feed)
   self.assertEqual(xml.read_bytes(),before)
   proof='https://updates.example.invalid/proof/dev/appcast.xml'
   (s/'Info.plist').write_bytes(plistlib.dumps({**info, 'SUFeedURL': proof, 'CFBundleIdentifier': 'org.example.proof',
                                                'AircLaunchArguments': ['--automated']}))
   p.publish(r,r/'proof-updates',s,proof)
   self.assertEqual(len(ET.fromstring((r/'proof-updates/dev/appcast.xml').read_bytes()).findall('./channel/item')),1)
if __name__=='__main__': unittest.main()
