#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Build escaped release notes, signed enclosure metadata and an immutable file inventory."""
import hashlib
import html
import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
def tag(name): return '{'+NS+'}'+name

def render(markdown):
    # Deliberately small safe Markdown subset used by the checked-in notes: no raw HTML.
    def inline(s):
        s = html.escape(s)
        s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
        return re.sub(r'`(.+?)`', r'<code>\1</code>', s)
    result = []; paragraph = []; listing = False
    def flush():
        if paragraph:
            result.append('<li>' if listing else '<p>')
            result.append(inline(' '.join(paragraph)))
            result.append('</li>' if listing else '</p>')
            paragraph.clear()
    for line in markdown.splitlines()+['']:
        if not line.strip():
            flush()
            if listing: result.append('</ul>'); listing = False
        elif line.startswith('#'):
            flush()
            if listing: result.append('</ul>'); listing = False
            m = re.fullmatch(r'(#{1,6}) (.*)', line)
            if not m: raise ValueError('Unsupported Markdown heading')
            n = len(m[1]); result.append(f'<h{n}>{inline(m[2])}</h{n}>')
        elif line.startswith('- '):
            flush()
            if not listing: result.append('<ul>'); listing = True
            paragraph.append(line[2:])
        else: paragraph.append(line.strip())
    return '<!doctype html><html lang="en"><meta charset="utf-8"><title>Airc release notes</title><body>'+''.join(result)+'</body></html>\n'

def generate(stage, notes, channel, qualified):
    info = plistlib.loads((stage/'Info.plist').read_bytes())
    version, build = str(info['CFBundleShortVersionString']), str(info['CFBundleVersion'])
    if channel not in ('stable', 'nightly') or not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d{12}', build):
        raise ValueError('Invalid release identifiers')
    prefix = f'https://aircbrowser.com/releases/{version}/{build}/'
    text = notes.read_text()+f"\nSource: `{info['AircRevision']}`. Build: `{build}`. Channel: {channel}.\n"
    (stage/'notes.md').write_text(text)
    (stage/'notes.html').write_text(render(text))
    signature = json.loads((stage/'signature.json').read_text())
    tree = ET.ElementTree(ET.fromstring('<rss version="2.0"><channel><title>Airc</title></channel></rss>'))
    item = ET.SubElement(tree.getroot().find('channel'), 'item')
    for key, val in [('title', f'Airc {version} ({channel})'), (tag('version'), build),
                     (tag('shortVersionString'), version), (tag('channel'), channel),
                     (tag('minimumSystemVersion'), info['LSMinimumSystemVersion']),
                     (tag('releaseNotesLink'), prefix+'notes.html')]:
        ET.SubElement(item, key).text = val
    zipname = f'Airc-{version}.zip'
    ET.SubElement(item, 'enclosure', {'url': prefix+zipname, 'length': str(signature['size']),
                  'type': 'application/octet-stream', tag('edSignature'): signature['signature']})
    deltas = json.loads((stage/'deltas.json').read_text())
    if deltas:
        parent = ET.SubElement(item, tag('deltas'))
        for d in deltas:
            ET.SubElement(parent, 'enclosure', {'url': prefix+d['file'], 'length': str(d['size']),
                'type': 'application/octet-stream', tag('edSignature'): d['signature'], tag('deltaFrom'): d['from']})
    tree.write(stage/'appcast.xml', encoding='utf-8', xml_declaration=True)
    dmg = stage/f'Airc-{version}.dmg'
    latest = {'version': version, 'build': build, 'url': prefix+dmg.name,
              'sha256': hashlib.sha256(dmg.read_bytes()).hexdigest(), 'size': dmg.stat().st_size,
              'minimumMacOS': info['LSMinimumSystemVersion'], 'channel': channel}
    (stage/'latest.json').write_text(json.dumps(latest, indent=2)+'\n')
    names = [dmg.name, zipname, 'appcast.xml', 'latest.json', 'notes.md', 'notes.html']+[d['file'] for d in deltas]
    inventory = {n: {'sha256': hashlib.sha256((stage/n).read_bytes()).hexdigest(), 'size': (stage/n).stat().st_size} for n in names}
    (stage/'SHA256SUMS').write_text(''.join(f'{v["sha256"]}  {n}\n' for n,v in inventory.items()))
    manifest = {'version': version, 'build': build, 'channel': channel, 'revision': info['AircRevision'],
                'qualified': qualified, 'files': inventory}
    (stage/'release.json').write_text(json.dumps(manifest, indent=2)+'\n')

if __name__ == '__main__':
    generate(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4] == '1')
