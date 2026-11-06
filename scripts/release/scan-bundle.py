#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Conservative byte gate, including UTF-16 strings. No matched values in output.

Literal dev/test key names also fail in executables: compile out their readers
before public packaging. This does not decode arbitrary compressed resources.

Reviewed false positives live in scan-allowlist.json. An entry covers one kind
(only `home-path` can be allowlisted), in one exact file, as a bare NUL-bounded
C string inside the named Mach-O sections, at most `count` times, with a reason.
Anything else of that kind in that file (a longer path, another section, one
more occurrence, any UTF-16 copy) still fails, and so does every other file.
"""
import json
import mmap
import os
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = Path(__file__).with_name('scan-allowlist.json')

PATTERNS = {
    'home-path': rb'/Users/',
    'private-host': rb'(?i)\.ts\.net',
    'dev-channel-key': rb'AircDevChannel',
    'launch-argument-default': rb'AircLaunchArguments',
}
# Kinds an allowlist entry may cover, with the exact literal it must name.
ALLOWLISTABLE = {'home-path': b'/Users/'}
IP = re.compile(rb'(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])')
IPV6 = re.compile(rb'(?i)(?<![\w:])(?:f[cd][0-9a-f]{2}|fe[89ab][0-9a-f]):[0-9a-f:]+(?:%[\w]+)?')

def kinds(data):
    hits = {kind for kind, pattern in PATTERNS.items() if re.search(pattern, data)}
    for match in IP.finditer(data):
        a, b, c, d = map(int, match[0].split(b'.'))
        if max(a, b, c, d) > 255:
            continue
        # RFC1918, shared address space (including tailnets), link-local.
        if a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168) or (a == 100 and 64 <= b <= 127) or (a == 169 and b == 254):
            hits.add('private-ip')
    if IPV6.search(data):
        hits.add('private-ip')
    return hits

def label(path):
    # A filename can itself contain a secret. Redact it before reporting.
    value = str(path).encode('utf8', 'replace')
    value = re.sub(rb'/Users/[^/\s]*', b'/[redacted-home]', value)
    value = re.sub(rb'(?i)[\w.-]+\.ts\.net', b'[redacted-host]', value)
    value = IP.sub(b'[redacted-address]', value)
    value = IPV6.sub(b'[redacted-address]', value)
    return repr(value.decode('utf8', 'replace'))

def load_allowlist(path=ALLOWLIST):
    """Entries by bundle-relative path. `{CHROMIUM_VERSION}` in a path is the pinned engine version."""
    entries = json.loads(Path(path).read_text())
    version = (ROOT / 'CHROMIUM_VERSION').read_text().strip()
    keys = {'path', 'kind', 'literal', 'sections', 'count', 'reason'}
    by_path = {}
    for entry in entries:
        ok = (isinstance(entry, dict) and set(entry) == keys
              and isinstance(entry['path'], str) and not re.search(r'[*?\[]', entry['path'])
              and not entry['path'].startswith('/')
              and ALLOWLISTABLE.get(entry['kind']) == str(entry['literal']).encode()
              and isinstance(entry['sections'], list) and entry['sections']
              and all(re.fullmatch(r'__\w+,__\w+', s) for s in entry['sections'])
              and isinstance(entry['count'], int) and entry['count'] > 0
              and isinstance(entry['reason'], str) and len(entry['reason'].strip()) >= 20)
        if not ok:
            raise ValueError('invalid allowlist entry')
        path = entry['path'].replace('{CHROMIUM_VERSION}', version)
        if path in by_path:
            raise ValueError('duplicate allowlist entry')
        by_path[path] = entry
    return by_path

def macho_sections(data):
    """(segment,section name, start, end) file ranges of a thin or universal 64-bit Mach-O; [] for anything else."""
    def thin(base):
        if data[base:base + 4] != b'\xcf\xfa\xed\xfe':
            return []
        ncmds, = struct.unpack_from('<I', data, base + 16)
        sections, at = [], base + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 0x19:  # LC_SEGMENT_64
                nsects, = struct.unpack_from('<I', data, at + 64)
                for i in range(nsects):
                    s = at + 72 + i * 80
                    sect, seg = (data[s:s + 16].rstrip(b'\0').decode(), data[s + 16:s + 32].rstrip(b'\0').decode())
                    size_, = struct.unpack_from('<Q', data, s + 40)
                    offset, = struct.unpack_from('<I', data, s + 48)
                    if offset:
                        sections.append((f'{seg},{sect}', base + offset, base + offset + size_))
            at += size
        return sections
    if data[:4] == b'\xca\xfe\xba\xbe':  # universal: big-endian fat_arch entries
        count, = struct.unpack_from('>I', data, 4)
        return [s for i in range(count) for s in thin(struct.unpack_from('>I', data, 8 + i * 20 + 8)[0])]
    return thin(0)

def allowed_occurrences(entry, data):
    """How many times the entry's literal occurs, or None if any occurrence falls outside what it allows."""
    literal = entry['literal'].encode()
    sections = macho_sections(data)
    count, start = 0, data.find(literal)
    while start != -1:
        end = start + len(literal)
        bare = (start == 0 or data[start - 1] == 0) and end < len(data) and data[end] == 0
        inside = any(name in entry['sections'] and lo <= start and end <= hi for name, lo, hi in sections)
        if not (bare and inside):
            return None
        count += 1
        start = data.find(literal, start + 1)
    return count if count <= entry['count'] else None

def content_kinds(data):
    """Kinds found in the raw bytes, and kinds found only in UTF-16 decodings."""
    raw, decoded = set(), set()
    # Bounded chunks with overlap for strings crossing a chunk boundary.
    for offset in range(0, len(data), 1024 * 1024):
        block = data[max(0, offset - 4096):offset + 1024 * 1024]
        raw |= kinds(block)
        if b'\0' in block:
            for start in (0, 1):
                decoded |= kinds(block[start:].decode('utf-16-le', 'ignore').encode('utf8'))
                decoded |= kinds(block[start:].decode('utf-16-be', 'ignore').encode('utf8'))
    return raw, decoded

def scan(app, allowlist=None):
    allowlist = load_allowlist() if allowlist is None else allowlist
    used = set()
    failed = False
    def unreadable(error):
        raise error
    for root, dirs, files in os.walk(app, followlinks=False, onerror=unreadable):
        for name in dirs + files:
            path = Path(root) / name
            relative = path.relative_to(app)
            hits = kinds(str(relative).encode())
            if path.is_symlink():
                hits |= kinds(os.readlink(path).encode())
                try:
                    path.resolve().relative_to(app.resolve())
                except ValueError:
                    hits.add('external-symlink')
            elif path.is_file() and path.stat().st_size:
                with path.open('rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    raw, decoded = content_kinds(data)
                    entry = allowlist.get(relative.as_posix())
                    if entry and entry['kind'] in raw - decoded:
                        count = allowed_occurrences(entry, data)
                        if count is not None:
                            raw.discard(entry['kind'])
                            used.add(relative.as_posix())
                            print(f"ALLOW {label(relative)}: {entry['kind']} x{count} in {'/'.join(entry['sections'])}"
                                  f" ({entry['reason']})")
                    hits |= raw | decoded
            for kind in sorted(hits):
                print(f'FAIL {label(relative)}: {kind}')
                failed = True
    for path in sorted(set(allowlist) - used):
        print(f'NOTE allowlist entry unused here: {label(path)}')
    print('Bundle scan: FAIL' if failed else 'Bundle scan: PASS')
    return int(failed)

if __name__ == '__main__':
    try:
        if len(sys.argv) != 2 or not (Path(sys.argv[1]) / 'Contents').is_dir():
            sys.exit('Expected an app bundle')
        sys.exit(scan(Path(sys.argv[1])))
    except (OSError, ValueError, KeyError, json.JSONDecodeError, struct.error):
        sys.exit('Bundle scan: unreadable file, invalid allowlist or invalid bundle (details redacted)')
