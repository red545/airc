#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Validate transferred signed archive, atomically publish feed, retain five versions.
Caller holds .publish.lock. The XML is the sole publication/last-revision journal.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
def tag(name): return '{' + NS + '}' + name

def publish(root, dest, stage, feed):
    url = urlsplit(feed)
    if url.scheme != 'https' or not url.netloc or url.query or url.fragment or not url.path.endswith('/dev/appcast.xml'):
        raise ValueError('Expected HTTPS /dev/appcast.xml without query or fragment')
    info = plistlib.loads((stage / 'Info.plist').read_bytes())
    version = str(info['CFBundleVersion'])
    if not re.fullmatch(r'[0-9]{12}', version):
        raise ValueError('Build must be YYYYmmddHHMM')
    if info.get('AircDevChannel') is not True or info.get('SUFeedURL') != feed or info.get('AircDefaultEngine') != 'chromium':
        raise ValueError('Wrong app/channel/feed')
    # The dev feed (/dev/appcast.xml) only takes the real app: never a test install with its own identity or bundled
    # options (an update proof's, which publishes to a feed of its own).
    if url.path == '/dev/appcast.xml':
        app_id = plistlib.loads((root / 'apps/browser/Resources/Info.plist').read_bytes())['CFBundleIdentifier']
        if info.get('CFBundleIdentifier') != app_id or 'AircLaunchArguments' in info:
            raise ValueError('A test build never goes to the dev feed')
    public = (root / 'infra/release/sparkle-public-key.txt').read_text().strip()
    if info.get('SUPublicEDKey') != public:
        raise ValueError('Wrong signing key')
    sig = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/=]+)"\s+length="([0-9]+)"\s*', (stage / 'signature.txt').read_text())
    archive = stage / 'update.zip'
    if not sig or int(sig[2]) != archive.stat().st_size:
        raise ValueError('Invalid signature metadata/length')
    # Verify transfer and signing independently using the committed public key.
    with tempfile.TemporaryDirectory(dir=stage) as temp:
        key, signature = Path(temp)/'public.der', Path(temp)/'signature'
        key.write_bytes(bytes.fromhex('302a300506032b6570032100') + base64.b64decode(public, validate=True))
        signature.write_bytes(base64.b64decode(sig[1], validate=True))
        subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(key),
                        '-rawin', '-in', str(archive), '-sigfile', str(signature)], check=True)
    folder = dest / 'dev'
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'appcast.xml'
    tree = ET.parse(path) if path.exists() else ET.ElementTree(ET.fromstring('<rss version="2.0"><channel><title>Airc dev</title></channel></rss>'))
    channel = tree.getroot().find('channel')
    items = channel.findall('item')
    if items and int(version) <= max(int(x.findtext(tag('version'))) for x in items):
        raise ValueError('Refusing duplicate or non-increasing build')
    deltas = json.loads((stage/'deltas.json').read_text()) if (stage/'deltas.json').exists() else []
    published = {x.findtext(tag('version')) for x in items}
    for delta in deltas:
        name = delta['file']
        if not re.fullmatch(r'Airc-' + version + r'-[0-9]{12}\.delta', name) or delta['from'] not in published:
            raise ValueError('Delta source is not a retained published build')
        payload = stage/name
        if (folder/name).exists(): raise ValueError('Immutable delta already exists')
        if payload.is_symlink() or payload.stat().st_size != delta['size']:
            raise ValueError('Invalid delta length')
        with tempfile.TemporaryDirectory(dir=stage) as temp:
            key, signature = Path(temp)/'public.der', Path(temp)/'signature'
            key.write_bytes(bytes.fromhex('302a300506032b6570032100') + base64.b64decode(public, validate=True))
            signature.write_bytes(base64.b64decode(delta['signature'], validate=True))
            subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(key),
                            '-rawin', '-in', str(payload), '-sigfile', str(signature)], check=True)
    revision = info['AircRevision']
    if not re.fullmatch('[0-9a-f]{7,40}', revision):
        raise ValueError('Build must record a source commit')
    git = lambda *args: subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
    revision = git('rev-parse', '--verify', revision + '^{commit}')
    prior = items[0].findtext('sourceCommit') if items else None
    span = f'{prior}..{revision}' if prior else revision
    notes = git('log', '-15', '--format=%s', span)
    filename = f'Airc-{version}.zip'
    target = folder / filename
    if target.exists():
        raise ValueError('Immutable archive already exists; inspect interrupted publish')
    shutil.copyfile(archive, target.with_suffix('.zip.tmp'))
    os.replace(target.with_suffix('.zip.tmp'), target)
    shutil.copyfile(stage/'signature.txt', folder/f'Airc-{version}.signature.txt')
    item = ET.Element('item')
    for name, value in [('title', 'Airc ' + info['CFBundleShortVersionString']), (tag('version'), version),
                        (tag('shortVersionString'), info['CFBundleShortVersionString']), (tag('channel'), 'dev'),
                        ('sourceCommit', revision), ('description', notes + '\nSource: ' + revision)]:
        ET.SubElement(item, name).text = value
    ET.SubElement(item, 'enclosure', {'url': feed.rsplit('/',1)[0] + '/' + filename,
        'length': sig[2], 'type': 'application/octet-stream', tag('edSignature'): sig[1]})
    if deltas:
        parent = ET.SubElement(item, tag('deltas'))
        for delta in deltas:
            destination = folder/delta['file']
            shutil.copyfile(stage/delta['file'], destination.with_suffix('.delta.tmp'))
            os.replace(destination.with_suffix('.delta.tmp'), destination)
            ET.SubElement(parent, 'enclosure', {'url': feed.rsplit('/',1)[0]+'/'+delta['file'],
                'length': str(delta['size']), 'type': 'application/octet-stream',
                tag('edSignature'): delta['signature'], tag('deltaFrom'): delta['from']})
    channel.insert(1, item)
    for old in channel.findall('item')[5:]: channel.remove(old)
    tree.write(str(path)+'.tmp', encoding='utf-8', xml_declaration=True)
    os.replace(str(path)+'.tmp', path)
    kept = {x.findtext(tag('version')) for x in channel.findall('item')}
    for old in folder.glob('Airc-*'):
        match = re.fullmatch(r'Airc-([0-9]{12})\.(zip|signature.txt)', old.name)
        if match and match[1] not in kept: old.unlink()
    for old in folder.glob('*.delta'):
        match = re.fullmatch(r'Airc-([0-9]{12})-[0-9]{12}\.delta', old.name)
        if match and match[1] not in kept: old.unlink()
    (stage/'published-sha256.txt').write_text(hashlib.sha256(target.read_bytes()).hexdigest() + '\n')

if __name__ == '__main__':
    publish(*(Path(x) for x in sys.argv[1:4]), sys.argv[4])
