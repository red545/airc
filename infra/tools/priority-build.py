#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""priority-build.py: the one shared way to join, hand on and read status/priority-build.

The marker is a small text file:

    <head>                                  the agent that may build now (first word of the first line)
    Handed on by <agent> at <UTC>[ (why)]   optional, written by `handon`
    <free note lines>                       optional, kept by join/leave, dropped by handon
    next: <agent>, <agent>, ...             optional queue, in order

Every write takes an flock on a sibling lock file (.priority-build.lock), re-reads the
marker, writes a temp file and os.replace()s it, so a reader never sees half a file and two
tool users never interleave. Agents that still edit the marker by hand don't take the lock,
so the write also checks the marker is unchanged since it was read and retries if not.

Subcommands (agent names: letters, digits, . _ -):
  status [--json]          head, queue, age
  join <name> [--front]    queue up (become head if there is no marker or no head).
                           --front: first in next: (release and Chromium-update agents only)
  handon <name> [--rejoin] [--front] [--reason TEXT]
                           only the head: first of next: becomes head, or the marker is
                           removed when next: is empty. Safe to call twice: the second call
                           is refused because <name> is no longer head (exit 3).
  leave <name>             drop <name> from next:; if <name> is head, hand on.
  is-head <name>           exit 0 if <name> is head, 1 if not (or no marker)
  may-build <name>         exit 0 if there is no marker or <name> is head, else 1

Common options: --marker PATH (or $AIRC_PRIORITY_BUILD) to work on a copy; --dry-run prints
the new marker without writing it.

Exit codes: 0 ok, 1 no (is-head/may-build), 2 usage error, 3 refused, 4 lock timeout.
"""
import argparse
import fcntl
import json
import os
import re
import sys
import time
from datetime import datetime, timezone



def default_marker():
    """$AIRC_PRIORITY_BUILD, else <ancestor>/status/priority-build for the nearest ancestor of
    this script whose status/ holds the agent build lock (works from the tools folder and from
    a repo checkout next to status/)."""
    env = os.environ.get('AIRC_PRIORITY_BUILD')
    if env:
        return env
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.exists(os.path.join(d, 'status', '.agent-build.lock')):
            return os.path.join(d, 'status', 'priority-build')
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent

NAME_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*')
VALID_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*\Z')
# Words people put between names on a next: line ("a, then b", "b first") that are not agents.
STOPWORDS = {'then', 'first', 'and', 'after', 'last', 'later', 'or', 'next', 'rejoin', 'rejoined'}
HANDED_RE = re.compile(r'^\s*handed\s+on\s+by\b', re.I)
NEXT_RE = re.compile(r'^\s*next\s*:(.*)$', re.I)
FRONT_OK_RE = re.compile(r'^(release|chromium|chrome)', re.I)

EXIT_OK, EXIT_NO, EXIT_USAGE, EXIT_REFUSED, EXIT_LOCK = 0, 1, 2, 3, 4


class Refused(Exception):
    pass


def utcnow():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _names(text):
    """Agent names in a fragment: parenthesised asides and markdown dropped, stopwords skipped."""
    text = re.sub(r'\([^)]*\)?', ' ', text)
    text = text.replace('*', ' ').replace('`', ' ')
    return [w for w in NAME_RE.findall(text) if w.lower() not in STOPWORDS]


class Marker:
    """Parsed marker. head is None when the file is absent, empty or has no head line."""

    def __init__(self, exists=False, head=None, head_line='', handed='', notes=None, queue=None,
                 warnings=None):
        self.exists = exists
        self.head = head
        self.head_line = head_line
        self.handed = handed
        self.notes = notes or []
        self.queue = queue or []
        self.warnings = warnings or []

    @classmethod
    def parse(cls, text):
        if text is None:
            return cls()
        m = cls(exists=True)
        lines = [l.rstrip() for l in text.splitlines()]
        rest = []
        for line in lines:
            if not line.strip():
                continue
            nm = NEXT_RE.match(line)
            if nm:
                for n in _names(nm.group(1)):
                    if n not in m.queue:
                        m.queue.append(n)
                continue
            if m.head is None and not m.head_line and not HANDED_RE.match(line):
                m.head_line = line.strip()
                names = _names(line)
                if names:
                    m.head = names[0]
                else:
                    m.warnings.append('head line has no agent name: %r' % line)
                continue
            if HANDED_RE.match(line):
                m.handed = line.strip()  # the last one wins
                continue
            rest.append(line.strip())
        m.notes = rest
        if m.head is None and m.queue:
            m.head = m.queue.pop(0)
            m.warnings.append('no head line; first of next: (%s) taken as head' % m.head)
        if m.head in m.queue:
            m.queue = [n for n in m.queue if n != m.head]
            m.warnings.append('head %s was also in next:; dropped there' % m.head)
        return m

    def render(self):
        """Normalized text, or None when the marker should not exist."""
        if self.head is None:
            return None
        out = [self.head]
        if self.handed:
            out.append(self.handed)
        decoration = self.head_line.strip()
        if decoration and decoration != self.head and decoration not in self.notes:
            out.append(decoration)  # keep what a hand-written head line said, as a note
        out.extend(n for n in self.notes if n)
        queue = [n for n in self.queue if n != self.head]
        if queue:
            out.append('next: ' + ', '.join(queue))
        return '\n'.join(out) + '\n'

    def to_dict(self):
        return {'exists': self.exists, 'head': self.head, 'handed': self.handed,
                'notes': self.notes, 'queue': self.queue, 'warnings': self.warnings}


# --- pure transitions (no I/O; unit-tested) --------------------------------------------

def check_name(name):
    if not VALID_NAME.match(name or ''):
        raise ValueError('bad agent name %r (letters, digits, . _ - only)' % name)


def check_front(name, force=False):
    if not force and not FRONT_OK_RE.match(name):
        raise Refused('--front is only for release and Chromium-update agents (name starts with '
                      'release/chromium/chrome); %s may not jump the queue without the lead '
                      '(--lead-approved)' % name)


def do_join(m, name, front=False, note=''):
    """Returns (marker, message)."""
    if m.head is None:
        new = Marker(exists=True, head=name, queue=[n for n in m.queue if n != name],
                     notes=([note] if note else []))
        return new, '%s is head (no one held the marker)' % name
    if m.head == name:
        return m, '%s is already head' % name
    q = list(m.queue)
    if name in q:
        if not front or q[0] == name:
            return m, '%s is already in next: (position %d)' % (name, q.index(name) + 1)
        q.remove(name)
    if front:
        q.insert(0, name)
    else:
        q.append(name)
    new = Marker(exists=True, head=m.head, head_line=m.head_line, handed=m.handed,
                 notes=m.notes, queue=q)
    return new, '%s joined next: at position %d behind head %s' % (name, q.index(name) + 1, m.head)


def do_handon(m, name, rejoin=False, front=False, reason='', now=None):
    if m.head is None:
        raise Refused('no marker head; %s holds nothing to hand on' % name)
    if m.head != name:
        raise Refused('%s is not head (head is %s); nothing handed on' % (name, m.head))
    q = [n for n in m.queue if n != name]
    if not q:
        return Marker(), '%s handed on; next: empty, marker removed' % name
    head, q = q[0], q[1:]
    if rejoin:
        if front:
            q.insert(0, name)
        else:
            q.append(name)
    line = 'Handed on by %s at %s' % (name, now or utcnow())
    if reason:
        line += ' (%s)' % reason.replace('\n', ' ').strip()
    new = Marker(exists=True, head=head, handed=line, queue=q)
    return new, '%s handed on to %s' % (name, head)


def do_leave(m, name, reason='', now=None):
    if m.head == name:
        return do_handon(m, name, reason=reason or 'left', now=now)
    if name not in m.queue:
        return m, '%s is not in the marker' % name
    new = Marker(exists=True, head=m.head, head_line=m.head_line, handed=m.handed,
                 notes=m.notes, queue=[n for n in m.queue if n != name])
    return new, '%s left next:' % name


# --- file handling ---------------------------------------------------------------------

def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


class Lock:
    def __init__(self, path, timeout):
        d, b = os.path.split(path)
        self.path = os.path.join(d, '.' + b.lstrip('.') + '.lock')
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o664)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    raise TimeoutError('could not lock %s within %ds' % (self.path, self.timeout))
                time.sleep(0.1)

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def write_atomic(path, text, tag):
    """text None removes the marker. Write tmp + fsync + os.replace."""
    if text is None:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return
    tmp = '%s.%s.%d.tmp' % (path, tag, os.getpid())
    with open(tmp, 'w') as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o664)
    os.replace(tmp, path)


def transact(path, fn, tag, dry_run=False, timeout=60, out=None):
    """Apply fn(marker)->(marker, msg) under the lock. Retries if a hand edit raced us."""
    out = out or sys.stdout
    with Lock(path, timeout):
        for _ in range(5):
            before = read_text(path)
            old = Marker.parse(before)
            for w in old.warnings:
                print('warning: ' + w, file=sys.stderr)
            new, msg = fn(old)
            if new is old:  # no-op: leave the file exactly as it is
                print(msg, file=out)
                return msg
            text = new.render()
            if dry_run:
                print(msg, file=out)
                print('--- dry run: new marker ---' if text else '--- dry run: marker removed ---',
                      file=out)
                if text:
                    out.write(text)
                return msg
            if read_text(path) != before:  # someone edited by hand between read and write
                time.sleep(0.2)
                continue
            write_atomic(path, text, tag)
            print(msg, file=out)
            return msg
        raise TimeoutError('marker kept changing under us; nothing written')


def age_seconds(path, m):
    try:
        mtime = os.stat(path).st_mtime
    except FileNotFoundError:
        return None, None
    since = time.time() - mtime
    handed = None
    if m.handed:
        t = re.search(r'(\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d+)?)?)(?:Z|\+00:00)?', m.handed)
        if t:
            s = t.group(1)
            fmt = '%Y-%m-%dT%H:%M:%S' if s.count(':') == 2 else '%Y-%m-%dT%H:%M'
            try:
                dt = datetime.strptime(s.split('.')[0], fmt).replace(tzinfo=timezone.utc)
                handed = (datetime.now(timezone.utc) - dt).total_seconds()
            except ValueError:
                pass
    return since, handed


def fmt_age(s):
    if s is None:
        return '?'
    s = int(s)
    return '%dh%02dm' % (s // 3600, s % 3600 // 60) if s >= 3600 else '%dm%02ds' % (s // 60, s % 60)


def main(argv=None):
    ap = argparse.ArgumentParser(prog='priority-build.py', description=__doc__.split('\n')[0])
    ap.add_argument('--marker', default=None)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--lock-timeout', type=int, default=60)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('status')
    s.add_argument('--json', action='store_true')
    j = sub.add_parser('join')
    j.add_argument('name')
    j.add_argument('--front', action='store_true')
    j.add_argument('--lead-approved', action='store_true',
                   help='allow --front for a non-release agent (only when the lead said so)')
    j.add_argument('--note', default='', help='note line when you become head')
    h = sub.add_parser('handon')
    h.add_argument('name')
    h.add_argument('--rejoin', action='store_true', help='get back in line (end of next:)')
    h.add_argument('--front', action='store_true', help='with --rejoin: first in next:')
    h.add_argument('--lead-approved', action='store_true')
    h.add_argument('--reason', default='')
    l = sub.add_parser('leave')
    l.add_argument('name')
    l.add_argument('--reason', default='')
    for c in ('is-head', 'may-build'):
        sub.add_parser(c).add_argument('name')
    a = ap.parse_args(argv)
    a.marker = a.marker or default_marker()
    if not a.marker:
        print('error: no status/ folder with .agent-build.lock above this script; pass --marker '
              'or set AIRC_PRIORITY_BUILD', file=sys.stderr)
        return EXIT_USAGE

    try:
        if getattr(a, 'name', None) is not None:
            check_name(a.name)
        if a.cmd == 'status':
            m = Marker.parse(read_text(a.marker))
            since, handed = age_seconds(a.marker, m)
            if a.json:
                d = m.to_dict()
                d.update(marker=a.marker, age_s=since, handed_age_s=handed)
                print(json.dumps(d))
            elif not m.exists:
                print('no marker (%s): anyone may build under the agent build lock' % a.marker)
            else:
                print('head:  %s' % (m.head or '(none)'))
                print('queue: %s' % (', '.join(m.queue) or '(empty)'))
                print('age:   %s since last write%s' % (
                    fmt_age(since), '' if handed is None else ', %s since hand-on' % fmt_age(handed)))
                if m.handed:
                    print('       ' + m.handed)
                for n in m.notes + ([m.head_line] if m.head_line and m.head_line != m.head else []):
                    print('note:  ' + n)
                for w in m.warnings:
                    print('warning: ' + w)
            return EXIT_OK
        if a.cmd in ('is-head', 'may-build'):
            m = Marker.parse(read_text(a.marker))
            if m.head == a.name or (a.cmd == 'may-build' and not m.exists):
                return EXIT_OK
            return EXIT_NO
        tag = a.name
        if a.cmd == 'join':
            if a.front:
                check_front(a.name, a.lead_approved)
            fn = lambda m: do_join(m, a.name, front=a.front, note=a.note)
        elif a.cmd == 'handon':
            if a.front and not a.rejoin:
                raise ValueError('--front with handon needs --rejoin')
            if a.front:
                check_front(a.name, a.lead_approved)
            fn = lambda m: do_handon(m, a.name, rejoin=a.rejoin, front=a.front, reason=a.reason)
        else:
            fn = lambda m: do_leave(m, a.name, reason=a.reason)
        transact(a.marker, fn, tag, dry_run=a.dry_run, timeout=a.lock_timeout)
        return EXIT_OK
    except ValueError as e:
        print('error: %s' % e, file=sys.stderr)
        return EXIT_USAGE
    except Refused as e:
        print('refused: %s' % e, file=sys.stderr)
        return EXIT_REFUSED
    except TimeoutError as e:
        print('error: %s' % e, file=sys.stderr)
        return EXIT_LOCK


if __name__ == '__main__':
    sys.exit(main())
