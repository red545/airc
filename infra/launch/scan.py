#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Privacy gate for an exported tree. Prints `file:line: kind`, never a matched value.

    scan.py <dir> --patterns FILE [--allowlist FILE] [--synthetic FILE] [--gitleaks-report FILE] [--public-email ADDR]...

Kinds:
  <pattern kind>   a value from the operator's private pattern file (tailnet-host, username, ...)
  email            an address that is neither reserved (RFC 2606/6761) nor a public mailbox
  external-symlink a symlink that points outside the tree
  gitleaks:<rule>  a secret found by gitleaks (read from its redacted JSON report)

A text line's hit of a regex kind (private-ip, tailnet-domain) is approved without an allowlist
entry when every value that kind matched on the line is a made-up value from --synthetic
(scan-synthetic.txt): <path glob><TAB><kind><TAB>net:<CIDR> | text:<exact><TAB><reason>.
Literal kinds (the operator's real values) can never be approved that way, and the gate refuses a
synthetic entry that would cover one of them.

Exit status: 0 when every hit is allowlisted, 1 on any unapproved hit, 2 on bad input.
"""
import argparse
import fnmatch
import ipaddress
import json
import os
from pathlib import Path
import re
import sys

EMAIL = re.compile(r'(?<![\w.%+-])[A-Za-z0-9][A-Za-z0-9._%+-]*@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})(?![\w-])')
# The last label of a "domain" that is really a filename, as in icon_16x16@2x.png.
FILE_SUFFIXES = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'icns', 'pdf', 'js', 'mjs', 'ts', 'css',
                 'json', 'md', 'html', 'swift', 'py', 'sh', 'txt', 'plist', 'mm', 'cc', 'h'}
RESERVED_TLDS = {'example', 'invalid', 'test', 'localhost'}
RESERVED_DOMAINS = {'example.com', 'example.net', 'example.org'}
# Addresses that identify a service, not a person.
SERVICE_ADDRESSES = {'git@github.com', 'git@gitlab.com'}
SITE_EMAIL = re.compile(r'\b\w*EMAIL\w*\s*=\s*["\']([^"\'@\s]+@[^"\'\s]+)["\']')
TEXT_SNIFF = 8192


def load_patterns(path):
    patterns = []
    for number, line in enumerate(Path(path).read_text(encoding='utf8').splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        kind, sep, spec = line.partition('\t')
        if not sep or ':' not in spec:
            raise ValueError(f'pattern file line {number}: expected <kind><TAB>literal:|regex:')
        mode, _, value = spec.partition(':')
        if mode == 'literal':
            rx = re.compile(r'(?<![A-Za-z0-9])' + re.escape(value) + r'(?![A-Za-z0-9])', re.I)
        elif mode == 'regex':
            rx = re.compile(value)
        else:
            raise ValueError(f'pattern file line {number}: unknown mode')
        patterns.append((kind, rx, mode, value if mode == 'literal' else None))
    if not patterns:
        raise ValueError('pattern file has no patterns')
    return patterns


def load_allowlist(path):
    entries = []
    if not path:
        return entries
    for number, line in enumerate(Path(path).read_text(encoding='utf8').splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 3 or not all(p.strip() for p in parts):
            raise ValueError(f'allowlist line {number}: expected <path glob><TAB><kind><TAB><reason>')
        entries.append({'glob': parts[0].strip(), 'kind': parts[1].strip(), 'line': number, 'used': 0})
    return entries


def as_ip(text):
    """The address a private-ip match names (zone and brackets dropped), or None."""
    try:
        return ipaddress.ip_address(text.strip('[]').split('%')[0])
    except ValueError:
        return None


def load_synthetic(path, patterns):
    entries = []
    if not path:
        return entries
    regex_kinds = {kind for kind, _, mode, _ in patterns if mode == 'regex'}
    literal_kinds = {kind for kind, _, mode, _ in patterns if mode == 'literal'}
    literals = [(kind, value) for kind, _, mode, value in patterns if mode == 'literal']
    for number, line in enumerate(Path(path).read_text(encoding='utf8').splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 4 or not all(p.strip() for p in parts):
            raise ValueError(f'synthetic line {number}: expected <path glob><TAB><kind><TAB>net:|text:<value><TAB><reason>')
        glob, kind, spec = (p.strip() for p in parts[:3])
        if kind in literal_kinds or (regex_kinds and kind not in regex_kinds):
            raise ValueError(f'synthetic line {number}: kind {kind} is not a regex kind; real values are never approvable')
        mode, _, value = spec.partition(':')
        if mode == 'net':
            net = ipaddress.ip_network(value, strict=True)
            if net.version == 4 and net.prefixlen < 24 or net.version == 6 and net.prefixlen < 112:
                raise ValueError(f'synthetic line {number}: network too wide (at most a /24 or an IPv6 /112)')
            match = lambda text, net=net: (ip := as_ip(text)) is not None and ip in net
        elif mode == 'text':
            match = lambda text, value=value.lower(): text.lower() == value
        else:
            raise ValueError(f'synthetic line {number}: expected net: or text:')
        # A made-up value must never cover one of the operator's real values.
        for lit_kind, lit in literals:
            ip = as_ip(lit)
            if (ip is not None and match(str(ip))) or (ip is None and mode == 'text' and lit.lower() in value.lower()):
                raise ValueError(f'synthetic line {number}: covers a private {lit_kind} value')
        entries.append({'glob': glob, 'kind': kind, 'match': match, 'line': number, 'used': 0})
    return entries


def synthetic_ok(rel, kind, values, synthetic):
    """True when every matched value is a made-up one approved for this file."""
    if not values:
        return False
    for value in values:
        entry = next((e for e in synthetic if e['kind'] == kind and fnmatch.fnmatchcase(rel, e['glob'])
                      and e['match'](value)), None)
        if not entry:
            return False
        entry['used'] += 1
    return True


def public_emails(root, extra):
    emails = {e.lower() for e in extra}
    site = root / 'apps/marketing/src/lib/site.ts'
    if site.is_file():
        emails |= {m.lower() for m in SITE_EMAIL.findall(site.read_text(encoding='utf8', errors='replace'))}
    return emails


def email_ok(address, domain, public):
    address, domain = address.lower(), domain.lower()
    labels = domain.split('.')
    return (address in public or address in SERVICE_ADDRESSES or labels[-1] in FILE_SUFFIXES
            or labels[-1] in RESERVED_TLDS or domain in RESERVED_DOMAINS
            or any(domain.endswith('.' + d) for d in RESERVED_DOMAINS))


def scan_text(text, patterns, public, check_email):
    """Yield (line, kind, matched values) for every hit. Line numbers start at 1. The values stay
    in memory for synthetic approval and are never printed."""
    for number, line in enumerate(text.splitlines(), 1):
        values = {}
        for kind, rx, _, _ in patterns:
            found = [m.group(0) for m in rx.finditer(line)]
            if found:
                values.setdefault(kind, []).extend(found)
        for kind, found in values.items():
            yield number, kind, tuple(found)
        if check_email:
            for m in EMAIL.finditer(line):
                if not email_ok(m.group(0), m.group(1), public):
                    yield number, 'email', ()


def scan_file(path, patterns, public):
    data = path.read_bytes()
    if b'\0' not in data[:TEXT_SNIFF]:
        yield from scan_text(data.decode('utf8', 'replace'), patterns, public, True)
        return
    # Binary: private literals only (metadata, embedded paths), in UTF-8 and UTF-16 strings.
    views = [data.decode('latin-1')]
    views += [data[s:].decode(enc, 'ignore') for s in (0, 1) for enc in ('utf-16-le', 'utf-16-be')]
    found = set()
    for view in views:
        for kind, rx, _, _ in patterns:
            if kind not in found and rx.search(view):
                found.add(kind)
                yield 0, kind, ()


def walk(root):
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not (Path(base) == root and d == '.git'))
        for name in sorted(files) + [d for d in dirs if (Path(base) / d).is_symlink()]:
            yield Path(base) / name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--patterns', required=True)
    ap.add_argument('--allowlist')
    ap.add_argument('--synthetic')
    ap.add_argument('--gitleaks-report')
    ap.add_argument('--public-email', action='append', default=[])
    ap.add_argument('--show-allowed', action='store_true')
    args = ap.parse_args()

    root = Path(args.dir).resolve()
    if not root.is_dir():
        raise ValueError('not a directory')
    patterns = load_patterns(args.patterns)
    allow = load_allowlist(args.allowlist)
    synthetic = load_synthetic(args.synthetic, patterns)
    public = public_emails(root, args.public_email)

    hits = []  # (relative path or label, line, kind)
    synthetic_lines = 0
    redacted = 0
    for path in walk(root):
        rel = path.relative_to(root).as_posix()
        label = rel
        path_kinds = [k for k, rx, _, _ in patterns if rx.search(rel)]
        if path_kinds:
            redacted += 1
            label = f'<redacted path {redacted}>'
            hits += [(label, 0, 'path:' + k) for k in path_kinds]
        if path.is_symlink():
            target = os.readlink(path)
            hits += [(label, 0, k) for k, rx, _, _ in patterns if rx.search(target)]
            try:
                path.resolve().relative_to(root)
            except ValueError:
                hits.append((label, 0, 'external-symlink'))
            continue
        if path.is_file():
            for line, kind, values in scan_file(path, patterns, public):
                if not path_kinds and synthetic_ok(rel, kind, values, synthetic):
                    synthetic_lines += 1
                else:
                    hits.append((label, line, kind))

    if args.gitleaks_report:
        text = Path(args.gitleaks_report).read_text(encoding='utf8').strip()
        for finding in json.loads(text) if text else []:
            file = Path(finding.get('File', ''))
            try:
                rel = file.resolve().relative_to(root).as_posix()
            except ValueError:
                rel = file.as_posix()
            if any(rx.search(rel) for _, rx, _, _ in patterns):
                rel = '<redacted path>'
            hits.append((rel, int(finding.get('StartLine', 0)), 'gitleaks:' + finding.get('RuleID', 'unknown')))

    hits = sorted(set(hits))
    failed = []
    allowed = []
    for hit in hits:
        rel, _, kind = hit
        entry = next((e for e in allow if e['kind'] == kind and fnmatch.fnmatchcase(rel, e['glob'])), None)
        if entry:
            entry['used'] += 1
            allowed.append(hit)
        else:
            failed.append(hit)

    def show(hit, suffix=''):
        rel, line, kind = hit
        print(f'{rel}:{line if line else "-"}: {kind}{suffix}')

    for hit in failed:
        show(hit)
    if args.show_allowed:
        for hit in allowed:
            show(hit, ' (allowed)')
    for e in allow:
        if not e['used']:
            print(f'warning: allowlist line {e["line"]} matched nothing; remove it if stale', file=sys.stderr)
    for e in synthetic:
        if not e['used'] and e['glob'] != '*':
            print(f'warning: synthetic line {e["line"]} matched nothing; remove it if stale', file=sys.stderr)

    counts = {}
    for _, _, kind in failed:
        counts[kind] = counts.get(kind, 0) + 1
    summary = ', '.join(f'{k} {v}' for k, v in sorted(counts.items())) or 'none'
    print(f'Privacy scan: {"FAIL" if failed else "PASS"}: {len(failed)} unapproved ({summary}), '
          f'{len(allowed)} allowlisted, {synthetic_lines} synthetic, {len(public)} public mailbox(es)')
    return 1 if failed else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except OSError as error:
        # No filename: a path could itself be private.
        sys.exit(f'Privacy scan: error: {type(error).__name__}: {error.strerror}')
    except (ValueError, re.error, json.JSONDecodeError) as error:
        # These messages name a pattern or allowlist line, never a matched value.
        sys.exit(f'Privacy scan: error: {type(error).__name__}: {error}')
