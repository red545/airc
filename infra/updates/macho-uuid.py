#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Stand-ins for the two Xcode tools posthog-cli's `dsym upload` runs, on Linux (infra/updates/upload-symbols.sh links
this file as `dwarfdump` and as `lipo`):

    dwarfdump --uuid PATH...            PATH: a .dSYM bundle or a Mach-O file. One line per architecture, as dwarfdump
                                        prints it: `UUID: <UUID> (<arch>) <file>`. Reads only the Mach-O headers.
    lipo FILE -thin ARCH -output OUT    the ARCH slice of a universal binary
"""
import os
import struct
import sys
import uuid

LC_UUID = 0x1B
ARCHS = {(0x0100000C, 2): "arm64e", (0x0100000C, None): "arm64", (0x01000007, None): "x86_64"}


def arch(cputype, subtype):
    return ARCHS.get((cputype, subtype & 0xFF)) or ARCHS.get((cputype, None)) or f"cpu{cputype:#x}"


def slices(data):
    """(offset, cputype, cpusubtype) of each thin Mach-O in data."""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        wide = magic == 0xCAFEBABF
        out = []
        for i in range(count):
            if wide:
                cpu, sub, off = struct.unpack_from(">iiQ", data, 8 + i * 32)
            else:
                cpu, sub, off = struct.unpack_from(">iiI", data, 8 + i * 20)
            out.append((off, cpu & 0xFFFFFFFF, sub & 0xFFFFFFFF))
        return out
    return [(0, None, None)]


def uuids(path):
    with open(path, "rb") as f:
        data = f.read()
    out = []
    for off, _, _ in slices(data):
        magic = struct.unpack_from("<I", data, off)[0]
        if magic != 0xFEEDFACF:
            continue
        cpu, sub, _, ncmds, _, _, _ = struct.unpack_from("<iiIIIII", data, off + 4)
        p = off + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, p)
            if cmd == LC_UUID:
                out.append((str(uuid.UUID(bytes=data[p + 8:p + 24])).upper(), arch(cpu & 0xFFFFFFFF, sub & 0xFFFFFFFF)))
            p += size
    return out


def files(path):
    if os.path.isdir(path):
        dwarf = os.path.join(path, "Contents", "Resources", "DWARF")
        return [os.path.join(dwarf, n) for n in sorted(os.listdir(dwarf))] if os.path.isdir(dwarf) else []
    return [path]


def thin(argv):
    src, want, out = argv[0], argv[argv.index("-thin") + 1], argv[argv.index("-output") + 1]
    with open(src, "rb") as f:
        data = f.read()
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        return 1
    wide = magic == 0xCAFEBABF
    for i in range(struct.unpack_from(">I", data, 4)[0]):
        if wide:
            cpu, sub, off, size = struct.unpack_from(">iiQQ", data, 8 + i * 32)
        else:
            cpu, sub, off, size = struct.unpack_from(">iiII", data, 8 + i * 20)
        if arch(cpu & 0xFFFFFFFF, sub & 0xFFFFFFFF) == want:
            with open(out, "wb") as f:
                f.write(data[off:off + size])
            return 0
    return 1


def main(argv):
    paths = [a for a in argv if a != "--uuid"]
    found = False
    for p in paths:
        for f in files(p):
            for u, a in uuids(f):
                print(f"UUID: {u} ({a}) {f}")
                found = True
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(thin(sys.argv[1:]) if os.path.basename(sys.argv[0]) == "lipo" else main(sys.argv[1:]))
