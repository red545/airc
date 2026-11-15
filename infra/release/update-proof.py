#!/usr/bin/env python3
"""Run an actual updater proof with a fresh Sparkle check, restoring its timestamp.

Run under the UI-check lock, with no other app using the bundle's defaults domain.
The child must stop its scratch app before returning. A separate data directory or
CFFIXED_USER_HOME alone does not isolate cfprefsd's SULastCheckTime.
Usage: update-proof.py --domain BUNDLE_ID --evidence DIRECTORY -- COMMAND [ARGS...]
"""
import argparse
from contextlib import contextmanager
import datetime
import plistlib
from pathlib import Path
import signal
import subprocess

KEY = 'SULastCheckTime'


def read_domain(domain):
    result = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    if result.returncode:
        raise RuntimeError('Cannot snapshot defaults domain; refusing to alter it')
    return plistlib.loads(result.stdout)


@contextmanager
def isolated_check(domain, evidence):
    evidence = Path(evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    original = read_domain(domain)
    present = KEY in original
    value = original.get(KEY)
    if present and not isinstance(value, datetime.datetime):
        raise ValueError('SULastCheckTime is not a date; refusing to alter it')
    snapshot = {'present': present}
    if present:
        snapshot['value'] = value
    # Save only the touched key; unrelated preferences may contain private data.
    path = evidence / 'sparkle-defaults-before.plist'
    with path.open('xb') as output:
        output.write(plistlib.dumps(snapshot))
    try:
        if present:
            subprocess.run(['defaults', 'delete', domain, KEY], check=True)
        if KEY in read_domain(domain):
            raise RuntimeError('Sparkle check timestamp was not cleared')
        yield
    finally:
        if present:
            subprocess.run(['defaults', 'write', domain, KEY, '-date',
                            value.strftime('%Y-%m-%d %H:%M:%S +0000')], check=True)
        elif KEY in read_domain(domain):
            subprocess.run(['defaults', 'delete', domain, KEY], check=True)
        restored = read_domain(domain)
        if (KEY in restored) != present or restored.get(KEY) != value:
            raise RuntimeError('Sparkle check timestamp restoration failed; retain snapshot')
        (evidence / 'sparkle-defaults-restored.plist').write_bytes(plistlib.dumps(snapshot))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--domain', required=True)
    parser.add_argument('--evidence', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a proof command is required')
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    with isolated_check(args.domain, args.evidence):
        child = subprocess.Popen(command)
        try:
            return child.wait()
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == '__main__':
    raise SystemExit(main())
