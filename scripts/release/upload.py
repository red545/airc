#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Verify locally by default; --go alone authorizes immutable Blob writes and feed promotion."""
import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
def tag(n): return '{'+NS+'}'+n

def verify(stage):
    m = json.loads((stage/'release.json').read_text())
    if m['channel'] not in ('stable', 'nightly') or not re.fullmatch(r'\d+\.\d+\.\d+', m['version']) or not re.fullmatch(r'\d{12}', m['build']):
        raise ValueError('Invalid manifest')
    expected = {f'Airc-{m["version"]}.dmg', f'Airc-{m["version"]}.zip', 'notes.md', 'notes.html', 'appcast.xml', 'latest.json'}
    for name, v in m['files'].items():
        if Path(name).name != name or name not in expected and not re.fullmatch(r'Airc-\d{12}-\d{12}\.delta', name):
            raise ValueError('Unexpected public file')
        p=stage/name
        if p.is_symlink() or p.stat().st_size != v['size'] or hashlib.sha256(p.read_bytes()).hexdigest() != v['sha256']:
            raise ValueError('Staged bytes changed: '+name)
    if not expected <= set(m['files']): raise ValueError('Missing public files')
    tree=ET.parse(stage/'appcast.xml'); items=tree.findall('./channel/item')
    if len(items) != 1: raise ValueError('Expected exactly one candidate item')
    item=items[0]
    if item.findtext(tag('version')) != m['build'] or item.findtext(tag('channel')) != m['channel']:
        raise ValueError('Wrong feed identity')
    prefix=f'https://aircbrowser.com/releases/{m["version"]}/{m["build"]}/'
    public=base64.b64decode((ROOT/'infra/release/sparkle-public-key.txt').read_text().strip(), validate=True)
    with tempfile.TemporaryDirectory(dir=stage, prefix='.verify-') as tmp:
        key=Path(tmp)/'public.der'; key.write_bytes(bytes.fromhex('302a300506032b6570032100')+public)
        for e in item.iter('enclosure'):
            url=e.attrib['url']; name=url.removeprefix(prefix)
            if not url.startswith(prefix) or name not in m['files'] or int(e.attrib['length']) != m['files'][name]['size']:
                raise ValueError('Wrong enclosure')
            sig=Path(tmp)/'signature'; sig.write_bytes(base64.b64decode(e.attrib[tag('edSignature')], validate=True))
            subprocess.run(['openssl','pkeyutl','-verify','-pubin','-keyform','DER','-inkey',str(key),'-rawin',
                            '-in',str(stage/name),'-sigfile',str(sig)], check=True, stdout=subprocess.DEVNULL)
    latest=json.loads((stage/'latest.json').read_text()); dmg=f'Airc-{m["version"]}.dmg'
    if latest['url'] != prefix+dmg or latest['sha256'] != m['files'][dmg]['sha256'] or latest['size'] != m['files'][dmg]['size']:
        raise ValueError('latest.json differs from artifact')
    for name in ('app-notary-log.json', f'Airc-{m["version"]}-{m["build"]}.dmg.notary-log.json'):
        if json.loads((stage/'evidence'/name).read_text())['status'] != 'Accepted': raise ValueError('Notary not Accepted')
    package=(stage/'evidence/package.log').read_text()
    if 'Release check: PASS' not in package or 'Bundle scan: PASS' not in package:
        raise ValueError('Public bundle gates missing')
    q=(stage/'evidence/qualification.log').read_text()
    if 'PASS quarantined DMG accepted' not in q or 'PASS throwaway install, Gatekeeper and public smoke' not in q:
        raise ValueError('Qualification not complete')
    for kind in ('delta', 'full'):
        proof=ET.parse(stage/f'evidence/sparkle-{kind}.xml')
        if any(i.findtext(tag('channel')) != m['channel'] for i in proof.findall('./channel/item')):
            raise ValueError('Sparkle proof used another channel')
        log=(stage/f'evidence/sparkle-{kind}.log').read_text()
        if 'PASS installed and relaunched 0.0.2' not in log or 'PASS installed Developer ID signature' not in log:
            raise ValueError('Sparkle proof incomplete')
    return m, item

def read_back(url, tries=12, wait=5):
    """A new Blob object can read as 404 for a few seconds after its put, and the CDN may serve that 404 again;
    read it back under a fresh query string until it appears."""
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(f'{url}?readback={attempt}', timeout=120) as r:
                return hashlib.file_digest(r,'sha256').hexdigest()
        except urllib.error.HTTPError as e:
            if e.code != 404 or attempt == tries-1: raise
            time.sleep(wait)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('stage', type=Path, nargs='?')
    parser.add_argument('--accept-red-suite', metavar='REASON')
    parser.add_argument('--go', action='store_true')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--create-store', action='store_true')
    args=parser.parse_args()
    if args.stage is None:
        pointer=Path(os.environ.get('AIRC_ARTIFACTS_DIR',str(ROOT.parent/'artifacts')))/'release/.last-stage'
        if not pointer.is_file(): parser.error('Supply a staging folder')
        args.stage=Path(pointer.read_text().strip())
    stage=args.stage.resolve()
    m,item=verify(stage)
    print('PASS local checksums, EdDSA, notarization and qualification evidence')
    if args.verify_only: return
    if not args.go: parser.error('Refusing publication without --go (use --verify-only for a dry run)')
    if not m['qualified']:
        if not args.accept_red_suite or len(args.accept_red_suite.strip()) < 20:
            parser.error('Source lacks green-suite evidence; rebuild or explicitly --accept-red-suite REASON')
        failures=[line for line in (stage/'evidence/source-suite.txt').read_text().splitlines() if line.startswith('FAIL ')]
        if not failures: parser.error('Override requires the actual failing source-suite check names')
        record={'reason':args.accept_red_suite.strip(), 'failedChecks':failures,
                'recordedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'revision':m['revision'], 'dmgSHA256':m['files'][f'Airc-{m["version"]}.dmg']['sha256']}
        (stage/'evidence/source-suite-override.json').write_text(json.dumps(record,indent=2)+'\n')
        m['sourceSuiteOverride']=record
        (stage/'release.json').write_text(json.dumps(m,indent=2)+'\n')
        print('EXPLICIT RED-SUITE OVERRIDE:',record['reason'])
        print('Recorded',len(failures),'failed checks in release.json and private evidence; distribution gates still mandatory.')
    scope=os.environ['AIRC_VERCEL_SCOPE']
    project=Path(os.environ['AIRC_VERCEL_PROJECT_DIR']).resolve()
    cli=['vercel','--cwd',str(project),'--scope',scope]
    # Serialize public feed promotion; no private feed paths are used anywhere here.
    with (stage.parents[1]/'.upload.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.create_store:
            subprocess.run(cli+['blob','create-store','airc-releases','--access','public','--yes','--environment','production'], check=True)
            print('Store created; set AIRC_BLOB_BASE_URL and Blob credentials, then rerun without --create-store.')
            return
        base=os.environ['AIRC_BLOB_BASE_URL'].rstrip('/')
        u=urlsplit(base)
        if u.scheme != 'https' or not re.fullmatch(r'[a-z0-9]+\.public\.blob\.vercel-storage\.com', u.netloc) or u.path:
            raise ValueError('Expected the public Blob store origin')
        if not os.environ.get('BLOB_READ_WRITE_TOKEN'): raise ValueError('Configure BLOB_READ_WRITE_TOKEN privately')
        # Merge the live public feed at upload time, never from a stale staged snapshot.
        try:
            with urllib.request.urlopen(base+'/feeds/appcast.xml', timeout=30) as r: tree=ET.ElementTree(ET.fromstring(r.read()))
        except urllib.error.HTTPError as e:
            if e.code != 404: raise
            tree=ET.ElementTree(ET.fromstring('<rss version="2.0"><channel><title>Airc</title></channel></rss>'))
        channel=tree.getroot().find('channel')
        existing=channel.findall('item')
        same=[i for i in existing if i.findtext(tag('version')) == m['build']]
        if existing and int(m['build']) < max(int(i.findtext(tag('version'))) for i in existing):
            raise ValueError('Refusing non-increasing public build')
        if same and (len(same) != 1 or ET.tostring(same[0]) != ET.tostring(item)):
            raise ValueError('Published build has different feed metadata')
        def put(path, name, mutable=False):
            command=cli+['blob','put',str(path),'--access','public','--pathname',name,'--cache-control-max-age', '60' if mutable else '31536000']
            if mutable: command+=['--force']
            types={'.xml':'application/xml', '.json':'application/json', '.html':'text/html', '.md':'text/markdown', '.dmg':'application/x-apple-diskimage'}
            command+=['--content-type',types.get(path.suffix,'application/octet-stream')]
            subprocess.run(command, check=True)
        prefix=f'releases/{m["version"]}/{m["build"]}/'
        for name,v in m['files'].items():
            url=base+'/'+prefix+name
            # Resume only when remote bytes exactly match. Never --force immutable artifacts.
            try:
                with urllib.request.urlopen(url, timeout=60) as r: digest=hashlib.file_digest(r,'sha256').hexdigest()
            except urllib.error.HTTPError as e:
                if e.code != 404: raise
                put(stage/name,prefix+name)
                digest=read_back(url)
            if digest != v['sha256']: raise ValueError('Remote checksum mismatch: '+name)
            print(url)
        if not same: channel.insert(1,item)
        for kind in ('stable','nightly'):
            selected=sorted((i for i in channel.findall('item') if i.findtext(tag('channel'))==kind), key=lambda i:int(i.findtext(tag('version'))), reverse=True)
            for old in selected[4:]: channel.remove(old)
        merged=stage/'uploaded-appcast.xml'; tree.write(merged,encoding='utf-8',xml_declaration=True)
        put(merged,'feeds/appcast.xml',True)
        pointer='latest.json' if m['channel']=='stable' else 'nightly-latest.json'
        put(stage/'latest.json','feeds/'+pointer,True)
        (stage/'uploaded.json').write_text(json.dumps({'base':base,'build':m['build']},indent=2)+'\n')
        print('Public feed:',base+'/feeds/appcast.xml')
        print('Download:',base+'/'+prefix+f'Airc-{m["version"]}.dmg')
        # Cache acknowledgement is safe to retry if the Mac is offline; upload is already complete.
        subprocess.run(['ssh',os.environ.get('AIRC_MAC_HOST','mac'),
                        f'touch arcfork/updates-cache/public/{m["build"]}/published'],check=True)

if __name__=='__main__': main()
