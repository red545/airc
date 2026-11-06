#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Synthetic, reserved fixtures only. Never reproduce operator values."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest

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

if __name__ == '__main__':
    unittest.main()
