#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Generate a synthetic CRX3 in a scratch directory (never a real store install)."""
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
def openssl(*args, data=None):
    return subprocess.check_output(['openssl', *args], input=data, stderr=subprocess.DEVNULL)
def varint(n):
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    return bytes(out + bytes([n]))
def field(n, data):
    return varint((n << 3) | 2) + varint(len(data)) + data
key = folder / 'fixture.pem'
openssl('genrsa', '-out', str(key), '2048')
pub = openssl('rsa', '-in', str(key), '-pubout', '-outform', 'DER')
crx_id = hashlib.sha256(pub).digest()[:16]
identifier = ''.join(chr(ord('a') + int(x, 16)) for x in crx_id.hex())
zipdata = io.BytesIO()
with zipfile.ZipFile(zipdata, 'w') as z:
    z.writestr('manifest.json', json.dumps({'manifest_version': 3, 'name': 'Synthetic profile extension',
        'version': '1.0', 'permissions': ['tabs']}))
archive = zipdata.getvalue()
signed_header = field(1, crx_id)
signed = b'CRX3 SignedData\x00' + struct.pack('<I', len(signed_header)) + signed_header + archive
signature = openssl('dgst', '-sha256', '-sign', str(key), data=signed)
header = field(2, field(1, pub) + field(2, signature)) + field(10000, signed_header)
(folder / 'fixture.crx').write_bytes(b'Cr24' + struct.pack('<II', 3, len(header)) + header + archive)
(folder / 'id.txt').write_text(identifier)
key.unlink()
print(identifier)
