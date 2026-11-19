#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Synthetic, reserved fixtures only. Never reproduce operator values."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('scanner', Path(__file__).with_name('scan-bundle.py'))
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


FRAMEWORK = 'Contents/Frameworks/Fixture.framework/Versions/1.0/Fixture'
HOME = '/Users/'

def macho(sections):
    """A minimal thin arm64 Mach-O: one LC_SEGMENT_64 per (segment, section, bytes), contents after the commands."""
    commands, payload = [], b''
    data_start = 32 + len(sections) * (72 + 80)
    for segment, section, content in sections:
        offset = data_start + len(payload)
        sect = struct.pack('<16s16sQQIIIIIIII', section.encode(), segment.encode(), 0, len(content), offset,
                           0, 0, 0, 0, 0, 0, 0)
        commands.append(struct.pack('<II16sQQQQiiII', 0x19, 72 + 80, segment.encode(), 0, 0, offset, len(content),
                                    0, 0, 1, 0) + sect)
        payload += content
    header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 6, len(sections), len(b''.join(commands)), 0, 0)
    return header + b''.join(commands) + payload

def entry(**changes):
    value = {'path': FRAMEWORK, 'kind': 'home-path', 'literal': HOME, 'sections': ['__TEXT,__cstring'], 'count': 1,
             'reason': 'Synthetic fixture: a generic home root literal, no user name'}
    value.update(changes)
    return value

def allowlist(tmp, *entries):
    path = Path(tmp) / 'allowlist.json'
    path.write_text(json.dumps(list(entries)))
    return scanner.load_allowlist(path)

def run(app, entries):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = scanner.scan(app, entries)
    return status, output.getvalue()

class BundleScanTests(unittest.TestCase):
    def test_clean_and_binary_encodings(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Scratch.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            payload = resources / 'fixture.bin'
            for encoding in ('utf8', 'utf-16-le', 'utf-16-be'):
                with self.subTest(encoding=encoding):
                    payload.write_bytes(b'clean')
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(scanner.scan(app, {}), 0)
                    # A chunk-boundary hit must be found; output must omit its value.
                    secret = '/Users/' + 'synthetic-fixture/private.txt'
                    payload.write_bytes(b'x' * (1024 * 1024 - 3) + secret.encode(encoding))
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        self.assertEqual(scanner.scan(app, {}), 1)
                    self.assertIn('fixture.bin', output.getvalue())
                    self.assertIn('home-path', output.getvalue())
                    self.assertNotIn('synthetic-fixture', output.getvalue())

    def test_private_ranges_and_dev_defaults(self):
        for octets in ((10, 1, 2, 3), (172, 16, 1, 2), (192, 168, 1, 2), (100, 64, 1, 2), (169, 254, 1, 2)):
            address = '.'.join(map(str, octets)).encode()
            self.assertIn('private-ip', scanner.kinds(address))
        for key in (b'AircDevChannel', b'AircLaunchArguments'):
            self.assertTrue(scanner.kinds(key))
        self.assertEqual(scanner.kinds(b'https://example.com/appcast.xml'), set())
        self.assertIn('private-host', scanner.kinds(b'fixture' + b'.ts.net'))
        self.assertIn('private-ip', scanner.kinds(b'fc' + b'00::1'))

    def test_symlink_and_filename_redaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Scratch.app'
            app.mkdir()
            (app / 'outside').symlink_to(Path(tmp) / 'absent')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(scanner.scan(app, {}), 1)
            self.assertIn('external-symlink', output.getvalue())
            self.assertNotIn('fixture.ts.net', scanner.label('fixture' + '.ts.net'))

    def test_allowlist_covers_only_the_bare_literal_in_its_section_and_file(self):
        bare = b'\0' + HOME.encode() + b'\0'
        cases = {
            'allowed': ([('__TEXT', '__cstring', b'abc' + bare + b'def\0')], 0),
            'longer path': ([('__TEXT', '__cstring', b'abc\0' + HOME.encode() + b'synthetic-fixture\0')], 1),
            'other section': ([('__DATA', '__data', b'abc' + bare)], 1),
            'one too many': ([('__TEXT', '__cstring', bare + b'x' + bare)], 1),
            'utf-16 copy': ([('__TEXT', '__cstring', bare + b'\0'.join(c.encode() for c in HOME) + b'\0')], 1),
        }
        for name, (sections, expected) in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                app = Path(tmp) / 'Scratch.app'
                binary = app / FRAMEWORK
                binary.parent.mkdir(parents=True)
                binary.write_bytes(macho(sections))
                status, output = run(app, allowlist(tmp, entry()))
                self.assertEqual(status, expected, output)
                self.assertNotIn('synthetic-fixture', output)
                self.assertIn('ALLOW' if expected == 0 else 'FAIL', output)

    def test_allowlist_is_scoped_to_its_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Scratch.app'
            other = app / 'Contents/Frameworks/Other.framework/Other'
            other.parent.mkdir(parents=True)
            other.write_bytes(macho([('__TEXT', '__cstring', b'\0' + HOME.encode() + b'\0')]))
            status, output = run(app, allowlist(tmp, entry()))
            self.assertEqual(status, 1)
            self.assertIn('FAIL', output)
            self.assertIn('allowlist entry unused', output)

    def test_invalid_allowlist_entries_are_rejected(self):
        for name, bad in {
            'no reason': entry(reason=''),
            'glob path': entry(path='Contents/Frameworks/*'),
            'not allowlistable': entry(kind='private-ip', literal='.'.join(['10', '0', '0', '1'])),
            'other literal': entry(literal=HOME + 'synthetic'),
            'no sections': entry(sections=[]),
            'extra field': dict(entry(), offset=12),
        }.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    allowlist(tmp, bad)

    def test_shipped_allowlist_loads(self):
        entries = scanner.load_allowlist()
        self.assertTrue(entries)
        self.assertTrue(all('{' not in path for path in entries))

    def test_public_resource_allowance_is_exact_path_and_kind(self):
        resource = 'Contents/Resources/Lists/fixture.txt'
        reason = 'Synthetic public list fixture; one reviewed kind in this exact text file'
        address = '.'.join(['10', '1', '2', '3']).encode()
        host = b'fixture' + b'.ts.net'
        for kind, payload, other_kind in [('private-ip', address, host), ('private-host', host, address)]:
            cases = [
                ('reviewed text', resource, payload + b'\n', 0),
                ('other file', 'Contents/Resources/Lists/other.txt', payload, 1),
                ('other kind', resource, payload + b'\n' + other_kind, 1),
                ('home path', resource, payload + b'\n' + HOME.encode() + b'fixture', 1),
                ('dev setting', resource, payload + b'\nAircDevChannel', 1),
                ('utf16', resource, payload.decode().encode('utf-16-le'), 1),
                ('binary', resource, payload + b'\0', 1),
            ]
            for label, path, content, expected in cases:
                with self.subTest(kind=kind, case=label), tempfile.TemporaryDirectory() as tmp:
                    app = Path(tmp) / 'Scratch.app'
                    target = app / path
                    target.parent.mkdir(parents=True)
                    target.write_bytes(content)
                    status, output = run(app, allowlist(tmp, {'path': resource, 'kind': kind, 'reason': reason}))
                    self.assertEqual(status, expected, output)
                    self.assertNotIn(payload.decode(), output)

    def test_resource_allowance_rejects_broad_paths_and_kinds(self):
        good = {'path': 'Contents/Resources/Lists/fixture.txt', 'kind': 'private-ip',
                'reason': 'Synthetic public list fixture; one reviewed kind in this exact text file'}
        for changes in [dict(path='Contents/Resources/Lists/*.txt'), dict(path='/Contents/Resources/list.txt'),
                        dict(path='Contents/Resources/../MacOS/fixture.txt'), dict(path='Contents/MacOS/fixture.txt'),
                        dict(kind='home-path'), dict(kind='dev-channel-key'), dict(reason=''), dict(extra=True)]:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    allowlist(tmp, dict(good, **changes))

    def test_resource_allowance_does_not_cover_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Scratch.app'
            target = app / 'Contents/Resources/Lists/fixture.txt'
            target.parent.mkdir(parents=True)
            target.symlink_to(Path(tmp) / 'outside')
            status, output = run(app, allowlist(tmp, {'path': target.relative_to(app).as_posix(),
                'kind': 'private-ip', 'reason': 'Synthetic public list fixture; one reviewed text file only'}))
            self.assertEqual(status, 1, output)
            self.assertIn('external-symlink', output)

# --- DMG fixtures ------------------------------------------------------------------------------
LZFSE, RAW, END = 0x80000007, 0x00000001, 0xffffffff
# Six bytes that fit the IPv6 ULA pattern, as random compressed data can (release049's hit was
# this shape). Built at run time so no source line carries an address-like value.
ULA_LIKE = b'fc' + b'DF:0'

def udif(chunks, name='disk image (Apple_APFS : 4)', tail=b'', table=None):
    """A minimal UDIF file: data fork of (type, bytes) chunks, XML plist with one blkx entry, `tail`
    (stands in for the code signature), koly trailer. Compressed chunks are not real compressed data:
    the scanner never decompresses them, it only skips their bytes."""
    fork, entries, at = b'', [], 0
    for kind, content in chunks:
        entries.append(struct.pack('>IIQQQQ', kind, 0, at // 512, 1, len(fork), len(content)))
        fork += content
        at += 512
    if table is not None:  # (type, offset, length) rows instead of the computed ones
        entries = [struct.pack('>IIQQQQ', kind, 0, i, 1, offset, length) for i, (kind, offset, length) in enumerate(table)]
    entries.append(struct.pack('>IIQQQQ', END, 0, at // 512, 0, len(fork), 0))
    mish = struct.pack('>4sIQQQII', b'mish', 1, 0, at // 512, 0, 0, 0) + b'\0' * 24 + b'\0' * 136
    mish = mish[:200] + struct.pack('>I', len(entries)) + b''.join(entries)
    xml = plistlib.dumps({'resource-fork': {'blkx': [{'Attributes': '0x0050', 'CFName': name, 'Data': mish,
                                                      'ID': '4', 'Name': name}]}})
    koly = bytearray(512)
    koly[0:4] = b'koly'
    struct.pack_into('>III', koly, 4, 4, 512, 1)
    struct.pack_into('>QQ', koly, 24, 0, len(fork))
    struct.pack_into('>QQ', koly, 216, len(fork), len(xml))
    return fork + xml + tail + bytes(koly)

def volume(tmp, extra=None):
    """A volume as a mount shows it: Airc.app, the /Applications link, a background picture."""
    root = Path(tmp) / 'volume'
    (root / 'Airc.app/Contents/MacOS').mkdir(parents=True)
    (root / 'Airc.app/Contents/MacOS/Airc').write_bytes(b'\xcf\xfa\xed\xfe clean')
    (root / 'Airc.app/Contents/Info.plist').write_text('<plist><dict/></plist>')
    (root / '.background').mkdir()
    (root / '.background/install.png').write_bytes(b'\x89PNG clean')
    (root / 'Applications').symlink_to('/Applications')
    for rel, content in (extra or {}).items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_bytes(content)
    return root

def run_dmg(tmp, image, root, allowlist=None):
    dmg = Path(tmp) / 'Fixture.dmg'
    dmg.write_bytes(image)
    opener = (lambda dmg, work: (root, lambda: None, {})) if not callable(root) else root
    output = io.StringIO()
    with contextlib.redirect_stdout(output), mock.patch.dict(os.environ, {'AIRC_SCAN_WORK': tmp}):
        status = scanner.scan_dmg(dmg, {} if allowlist is None else allowlist, opener=opener)
    return status, output.getvalue()

class DmgScanTests(unittest.TestCase):
    def test_pattern_like_bytes_inside_a_compressed_chunk_are_not_a_hit(self):
        # The old raw scan of the whole file fails on exactly this image.
        image = udif([(RAW, b'\0' * 64), (LZFSE, b'\x9c\xed' * 150 + b'\0' + ULA_LIKE + b'\0' + b'\xbd\x0b' * 150)])
        self.assertIn('private-ip', scanner.content_kinds(image)[0])
        with tempfile.TemporaryDirectory() as tmp:
            status, output = run_dmg(tmp, image, volume(tmp))
            self.assertEqual(status, 0, output)
            self.assertIn('DMG scan: PASS', output)
            self.assertIn('Volume scan: PASS', output)

    def test_every_compressed_type_is_skipped_and_nothing_else(self):
        for kind in scanner.UDIF_COMPRESSED:
            with self.subTest(kind=hex(kind)), tempfile.TemporaryDirectory() as tmp:
                self.assertEqual(run_dmg(tmp, udif([(kind, ULA_LIKE)]), volume(tmp))[0], 0)
        # The same bytes in a raw (uncompressed) chunk, the plist or the signature area are plain text.
        for name, image in {
            'raw chunk': udif([(LZFSE, b'x' * 32), (RAW, ULA_LIKE + b'\n')]),
            'plist name': udif([(LZFSE, b'x' * 32)], name='disk image ' + HOME + 'synthetic-fixture'),
            'signature tail': udif([(LZFSE, b'x' * 32)], tail=b'\0' + b'fixture' + b'.ts.net\0'),
        }.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                status, output = run_dmg(tmp, image, volume(tmp))
                self.assertEqual(status, 1, output)
                self.assertIn('FAIL DMG container (outside compressed chunks)', output)
                self.assertNotIn('synthetic-fixture', output)

    def test_files_inside_the_volume_are_scanned(self):
        secret = (HOME + 'synthetic-fixture/notes.txt').encode()
        address = '.'.join(['10', '1', '2', '3']).encode()
        for rel, content, where in [
            ('Airc.app/Contents/Resources/fixture.txt', secret, 'DMG volume app'),
            ('Airc.app/Contents/MacOS/Airc', b'\xcf\xfa\xed\xfe\0' + secret.decode().encode('utf-16-le'), 'DMG volume app'),
            ('.background/readme.txt', address + b'\n', 'DMG volume, outside the app'),
            ('.DS_Store', b'\0Bud1' + secret, 'DMG volume, outside the app'),
        ]:
            with self.subTest(rel), tempfile.TemporaryDirectory() as tmp:
                status, output = run_dmg(tmp, udif([(LZFSE, b'x' * 32)]), volume(tmp, {rel: content}))
                self.assertEqual(status, 1, output)
                self.assertIn('DMG scan: FAIL', output)
                self.assertIn(where, output)
                self.assertNotIn('synthetic-fixture', output)
                self.assertNotIn(address.decode(), output)

    def test_only_the_volume_applications_link_may_leave_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = volume(tmp)
            (root / 'Elsewhere').symlink_to('/Library')
            status, output = run_dmg(tmp, udif([(LZFSE, b'x')]), root)
            self.assertEqual(status, 1, output)
            self.assertIn("'Elsewhere': external-symlink", output)
        with tempfile.TemporaryDirectory() as tmp:
            root = volume(tmp)
            link = root / 'Airc.app/Contents/Applications'
            link.symlink_to('/Applications')
            self.assertEqual(run_dmg(tmp, udif([(LZFSE, b'x')]), root)[0], 1)
        with tempfile.TemporaryDirectory() as tmp:
            # An extractor's listing gives the true target of a rewritten link.
            root = volume(tmp)
            opener = lambda dmg, work: (root, lambda: None, {str(root / 'Applications'): HOME + 'synthetic-fixture'})
            status, output = run_dmg(tmp, udif([(LZFSE, b'x')]), opener)
            self.assertEqual(status, 1, output)
            self.assertIn('home-path', output)

    def test_contents_not_readable_fails_closed(self):
        def refuse(dmg, work):
            raise scanner.ContentsNotScanned('hdiutil attach failed (exit 1)')
        with tempfile.TemporaryDirectory() as tmp:
            for name, opener in {
                'mount refused': refuse,
                'empty volume': lambda dmg, work: (Path(work), lambda: None, {}),
            }.items():
                with self.subTest(name):
                    status, output = run_dmg(tmp, udif([(LZFSE, b'x')]), opener)
                    self.assertEqual(status, 1, output)
                    self.assertIn('DMG contents not scanned', output)
                    self.assertNotIn('DMG scan: PASS', output)
            # No hdiutil and no 7-Zip: the default opener refuses.
            with mock.patch.object(scanner.sys, 'platform', 'linux'), \
                 mock.patch.dict(os.environ, {'AIRC_7ZZ': str(Path(tmp) / 'absent-7zz')}):
                status, output = run_dmg(tmp, udif([(LZFSE, b'x')]), scanner.open_dmg_contents)
            self.assertEqual(status, 1, output)
            self.assertIn('DMG contents not scanned (no hdiutil (macOS) and no 7-Zip', output)

    def test_malformed_images_fail_closed(self):
        chunks = [(LZFSE, b'x' * 16), (LZFSE, b'y' * 16)]
        overlapping = udif(chunks, table=[(LZFSE, 0, 16), (LZFSE, 8, 16)])
        outside = udif(chunks, table=[(LZFSE, 0, 16), (LZFSE, 16, 9999)])
        unknown = udif(chunks, table=[(LZFSE, 0, 16), (0x80000099, 16, 16)])
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(run_dmg(tmp, udif(chunks, table=[(LZFSE, 0, 16), (LZFSE, 16, 16)]), volume(tmp))[0], 0)
        for name, image in {'no trailer': b'plain bytes' * 100, 'overlapping': overlapping,
                            'outside the fork': outside, 'unknown chunk type': unknown}.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                status, output = run_dmg(tmp, image, volume(tmp))
                self.assertEqual(status, 1, output)
                self.assertIn('DMG contents not scanned', output)

    @unittest.skipUnless(scanner.seven_zip() or (sys.platform == 'darwin' and shutil.which('hdiutil')),
                         'needs hdiutil (macOS) or 7-Zip to open a real image')
    @unittest.skipUnless(os.environ.get('AIRC_SCAN_REAL_DMG'), 'set AIRC_SCAN_REAL_DMG=<image> to scan a real one')
    def test_real_image(self):
        # e.g. a tiny `hdiutil create -format ULFO` image; AIRC_SCAN_REAL_DMG_EXPECT=1 when it holds a hit.
        expected = int(os.environ.get('AIRC_SCAN_REAL_DMG_EXPECT', '0'))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = scanner.scan_dmg(Path(os.environ['AIRC_SCAN_REAL_DMG']), {})
        self.assertEqual(status, expected, output.getvalue())
        self.assertIn('DMG volume app', output.getvalue())

if __name__ == '__main__':
    unittest.main()
