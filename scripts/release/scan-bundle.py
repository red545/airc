#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Conservative byte gate, including UTF-16 strings. No matched values in output.

Literal dev/test key names also fail in executables: compile out their readers
before public packaging. This does not decode arbitrary compressed resources.

Reviewed false positives live in scan-allowlist.json. A literal entry covers
`home-path` in one exact file, as a bare NUL-bounded C string in named Mach-O
sections, at most `count` times. A resource entry covers one kind in one exact
UTF-8 text resource containing public third-party data. Both require a reason.
Other kinds, paths, symlinks and UTF-16 copies remain checked.

A DMG is scanned by what it contains (scan_dmg): every file of its volume, read through a
read-only mount (hdiutil on macOS) or a 7-Zip extraction elsewhere, and every byte of the
image itself except the payload of its compressed chunks (see dmg_container_kinds). When the
contents cannot be read, the scan fails closed ("DMG contents not scanned").
"""
import json
import mmap
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

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
RESOURCE_KINDS = {'private-host', 'private-ip'}
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
    resource_keys = {'path', 'kind', 'reason'}
    by_path = {}
    for entry in entries:
        common = (isinstance(entry, dict) and isinstance(entry.get('path'), str)
              and not re.search(r'[*?\[\]]', entry['path'])
              and not entry['path'].startswith('/')
              and '..' not in Path(entry['path']).parts
              and isinstance(entry.get('reason'), str) and len(entry['reason'].strip()) >= 20)
        literal = (common and set(entry) == keys
              and isinstance(entry['path'], str) and not re.search(r'[*?\[]', entry['path'])
              and not entry['path'].startswith('/')
              and ALLOWLISTABLE.get(entry['kind']) == str(entry['literal']).encode()
              and isinstance(entry['sections'], list) and entry['sections']
              and all(re.fullmatch(r'__\w+,__\w+', s) for s in entry['sections'])
              and isinstance(entry['count'], int) and entry['count'] > 0
              and isinstance(entry['reason'], str) and len(entry['reason'].strip()) >= 20)
        resource = (common and set(entry) == resource_keys
              and entry['kind'] in RESOURCE_KINDS
              and entry['path'].startswith('Contents/Resources/')
              and entry['path'].endswith('.txt'))
        if not (literal or resource):
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

def link_escapes(path, target, top, override):
    """True when a symlink leaves `top`. An `override` target (from an extractor's listing) is
    resolved lexically, because the extracted link on disk may not carry it."""
    if not override:
        try:
            path.resolve().relative_to(top.resolve())
            return False
        except ValueError:
            return True
    resolved = Path(os.path.normpath(target if os.path.isabs(target) else path.parent / target))
    try:
        resolved.relative_to(top)
        return False
    except ValueError:
        return True

def scan(app, allowlist=None, *, skip=(), link_targets=None, external_ok=(), title='Bundle scan'):
    """Scan every entry under `app`. `skip`: top-level names left to another scan. `link_targets`:
    absolute path -> true symlink target, when the tree on disk is an extraction. `external_ok`:
    (relative path, exact target) pairs of symlinks allowed to leave the tree."""
    allowlist = load_allowlist() if allowlist is None else allowlist
    link_targets = link_targets or {}
    used = set()
    failed = False
    def unreadable(error):
        raise error
    for root, dirs, files in os.walk(app, followlinks=False, onerror=unreadable):
        if Path(root) == Path(app):
            dirs[:] = [d for d in dirs if d not in skip]
            files = [f for f in files if f not in skip]
        for name in dirs + files:
            path = Path(root) / name
            relative = path.relative_to(app)
            hits = kinds(str(relative).encode())
            if path.is_symlink():
                override = str(path) in link_targets
                target = link_targets[str(path)] if override else os.readlink(path)
                hits |= kinds(target.encode())
                if (relative.as_posix(), target) not in external_ok and link_escapes(path, target, Path(app), override):
                    hits.add('external-symlink')
            elif path.is_file() and path.stat().st_size:
                with path.open('rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    raw, decoded = content_kinds(data)
                    entry = allowlist.get(relative.as_posix())
                    if entry and 'literal' in entry and entry['kind'] in raw - decoded:
                        count = allowed_occurrences(entry, data)
                        if count is not None:
                            raw.discard(entry['kind'])
                            used.add(relative.as_posix())
                            print(f"ALLOW {label(relative)}: {entry['kind']} x{count} in {'/'.join(entry['sections'])}"
                                  f" ({entry['reason']})")
                    elif entry and 'literal' not in entry and entry['kind'] in raw - decoded and data.find(b'\0') == -1:
                        # Resource allowances never apply to binary/UTF-16 payloads or path/link metadata.
                        try:
                            data[:].decode('utf-8')
                        except UnicodeDecodeError:
                            pass
                        else:
                            raw.discard(entry['kind'])
                            used.add(relative.as_posix())
                            print(f"ALLOW {label(relative)}: {entry['kind']} in public text resource ({entry['reason']})")
                    hits |= raw | decoded
            for kind in sorted(hits):
                print(f'FAIL {label(relative)}: {kind}')
                failed = True
    for path in sorted(set(allowlist) - used):
        print(f'NOTE allowlist entry unused here: {label(path)}')
    print(f'{title}: FAIL' if failed else f'{title}: PASS')
    return int(failed)

# --- DMG (UDIF) images -------------------------------------------------------------------------
# Chunk types in a blkx table (Apple's UDIF "mish" block). Only these compressed kinds are skipped.
UDIF_COMPRESSED = {0x80000004: 'adc', 0x80000005: 'zlib', 0x80000006: 'bzip2', 0x80000007: 'lzfse', 0x80000008: 'lzma'}
UDIF_KNOWN = set(UDIF_COMPRESSED) | {0x00000000, 0x00000001, 0x00000002, 0x7ffffffe, 0xffffffff}
# The volume's own Finder link, the only symlink in a DMG allowed to leave it.
DMG_EXTERNAL_OK = {('Applications', '/Applications')}

class ContentsNotScanned(Exception):
    """The DMG's files could not be read; the scan must fail closed."""

def udif_compressed_ranges(data):
    """Sorted, non-overlapping (start, end) file ranges of the compressed chunks' payload, read from
    the koly trailer's XML plist. Raises ValueError for anything that is not a well-formed UDIF image."""
    size = len(data)
    if size < 512 or data[size - 512:size - 508] != b'koly':
        raise ValueError('not a UDIF image (no koly trailer)')
    koly = data[size - 512:]
    data_offset, data_length = struct.unpack_from('>QQ', koly, 24)
    xml_offset, xml_length = struct.unpack_from('>QQ', koly, 216)
    if not (0 < xml_length and xml_offset + xml_length <= size - 512 and data_offset + data_length <= size - 512):
        raise ValueError('UDIF trailer points outside the file')
    blkx = plistlib.loads(bytes(data[xml_offset:xml_offset + xml_length]))['resource-fork']['blkx']
    ranges = []
    for block in blkx:
        mish = block['Data']
        if mish[:4] != b'mish':
            raise ValueError('UDIF block table without mish header')
        base, = struct.unpack_from('>Q', mish, 24)
        count, = struct.unpack_from('>I', mish, 200)
        if len(mish) < 204 + 40 * count:
            raise ValueError('truncated UDIF block table')
        for i in range(count):
            kind, _, _, _, offset, length = struct.unpack_from('>IIQQQQ', mish, 204 + 40 * i)
            if kind not in UDIF_KNOWN:
                raise ValueError('unknown UDIF chunk type')
            if kind in UDIF_COMPRESSED and length:
                start = data_offset + base + offset
                if start + length > data_offset + data_length:
                    raise ValueError('UDIF chunk outside the data fork')
                ranges.append((start, start + length))
    ranges.sort()
    for (_, end), (start, _) in zip(ranges, ranges[1:]):
        if start < end:
            raise ValueError('overlapping UDIF chunks')
    return ranges

def dmg_container_kinds(data):
    """Kinds in the image's own bytes, outside its compressed chunks: the koly trailer, the XML
    plist and resource fork, raw (uncompressed) chunks, the code signature and any gap.

    Compressed payload is not matched as text. Its bytes are lzfse/lzma/zlib/bzip2/ADC output,
    which is effectively random: a six-byte run such as an IPv6 ULA prefix turns up by chance in
    a 200 MB image (0.1.29, 0.1.30, 0.1.37), and real text inside is never visible there anyway,
    because it is compressed. Skipping it is safe only because scan_dmg scans the decompressed
    contents of every file in the image instead; this function must never be used on its own."""
    raw, decoded = set(), set()
    at = 0
    for start, end in udif_compressed_ranges(data) + [(len(data), len(data))]:
        if at < start:
            r, d = content_kinds(data[at:start])
            raw |= r
            decoded |= d
        at = max(at, end)
    return raw, decoded

def seven_zip():
    """A 7-Zip binary (AIRC_7ZZ, or 7zz/7z on PATH), or None."""
    named = os.environ.get('AIRC_7ZZ')
    if named:
        return named if os.access(named, os.X_OK) else None
    return shutil.which('7zz') or shutil.which('7z')

def mount_dmg(dmg, work):
    """Read-only, unbrowsed mount on macOS. Returns (root, cleanup, link targets)."""
    point = Path(work) / 'mount'
    point.mkdir()
    result = subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noverify', '-noautoopen',
                             '-mountpoint', str(point), str(dmg)], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode or not os.path.ismount(point):
        raise ContentsNotScanned(f'hdiutil attach failed (exit {result.returncode})')
    def cleanup():
        for extra in ([], ['-force']):
            if subprocess.run(['hdiutil', 'detach', '-quiet', *extra, str(point)],
                              stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                return
    return point, cleanup, {}

def extract_dmg(dmg, work, tool):
    """7-Zip extraction (DMG, then its APFS/HFS+ volume). 7-Zip rewrites absolute symlink targets
    on extraction, so the true targets come from its listing. Alternate streams are not extracted,
    as a mount's walk does not read them either."""
    out = Path(work) / 'volume'
    base = [tool, '-sns-', '-bso0', '-bsp0']
    listing = subprocess.run([tool, 'l', '-slt', '-sns-', str(dmg)], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, errors='replace')
    if listing.returncode:
        raise ContentsNotScanned(f'7-Zip could not list the image (exit {listing.returncode})')
    result = subprocess.run(base[:1] + ['x', '-snl'] + base[1:] + [f'-o{out}', str(dmg)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise ContentsNotScanned(f'7-Zip extraction failed (exit {result.returncode})')
    links = {}
    body = listing.stdout.split('\n----------\n', 1)[-1]
    for block in body.split('\n\n'):
        fields = dict(line.split(' = ', 1) for line in block.splitlines() if ' = ' in line)
        if fields.get('Symbolic Link') and fields.get('Path'):
            links[str(out / fields['Path'])] = fields['Symbolic Link']
    return out, (lambda: None), links

def open_dmg_contents(dmg, work):
    if sys.platform == 'darwin' and shutil.which('hdiutil'):
        return mount_dmg(dmg, work)
    tool = seven_zip()
    if tool:
        return extract_dmg(dmg, work, tool)
    raise ContentsNotScanned('no hdiutil (macOS) and no 7-Zip (AIRC_7ZZ, 7zz or 7z)')

def scan_dmg(dmg, allowlist=None, opener=open_dmg_contents):
    """Container bytes (outside compressed chunks) plus every file of the volume. 0 on PASS, 1 otherwise."""
    allowlist = load_allowlist() if allowlist is None else allowlist
    dmg = Path(dmg)
    failed = False
    try:
        with dmg.open('rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
            raw, decoded = dmg_container_kinds(data)
    except (ValueError, KeyError, TypeError, struct.error) as error:
        print(f'FAIL DMG container: {error if isinstance(error, ValueError) else "unreadable UDIF metadata"}')
        print('DMG scan: FAIL: DMG contents not scanned')
        return 1
    for kind in sorted(raw | decoded):
        print(f'FAIL DMG container (outside compressed chunks): {kind}')
        failed = True
    work = tempfile.mkdtemp(prefix='airc-dmg-scan.', dir=os.environ.get('AIRC_SCAN_WORK'))
    cleanup = lambda: None
    try:
        try:
            root, cleanup, links = opener(dmg, work)
        except (ContentsNotScanned, OSError) as error:
            reason = error if isinstance(error, ContentsNotScanned) else type(error).__name__
            print(f'DMG scan: FAIL: DMG contents not scanned ({reason})')
            return 1
        root = Path(root)
        apps = sorted(p.name for p in root.iterdir() if p.suffix == '.app' and (p / 'Contents').is_dir()
                      and not p.is_symlink())
        if not apps:
            print('DMG scan: FAIL: DMG contents not scanned (no app bundle in the volume)')
            return 1
        for name in apps:
            print(f'DMG volume app {label(name)}:')
            failed |= bool(scan(root / name, allowlist, link_targets=links))
        print('DMG volume, outside the app:')
        failed |= bool(scan(root, {}, skip=set(apps), link_targets=links, external_ok=DMG_EXTERNAL_OK,
                            title='Volume scan'))
    finally:
        cleanup()
        shutil.rmtree(work, ignore_errors=True)
    print('DMG scan: FAIL' if failed else 'DMG scan: PASS')
    return int(failed)

if __name__ == '__main__':
    try:
        if len(sys.argv) == 2 and sys.argv[1].endswith('.dmg') and Path(sys.argv[1]).is_file():
            sys.exit(scan_dmg(Path(sys.argv[1])))
        if len(sys.argv) != 2 or not (Path(sys.argv[1]) / 'Contents').is_dir():
            sys.exit('Expected an app bundle or a .dmg')
        sys.exit(scan(Path(sys.argv[1])))
    except (OSError, ValueError, KeyError, json.JSONDecodeError, struct.error, plistlib.InvalidFileException):
        sys.exit('Bundle scan: unreadable file, invalid allowlist or invalid bundle (details redacted)')
