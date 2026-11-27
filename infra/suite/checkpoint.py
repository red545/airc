"""Atomic Linux checkpoints for one pinned full-suite run; no Mac locks held."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

OWNER = 'airc-suite-checkpoint-v1\n'
SCHEMA = 2
# A full run moves only in the gaps between releases, priority builds and quiet
# windows (often only at night), so it may span several days. Main moves ~45
# commits a day; past MAX_BEHIND the pinned run is too stale to be worth ending.
MAX_AGE = int(os.environ.get('AIRC_SUITE_CHECKPOINT_MAX_AGE', 4 * 24 * 60 * 60))
MAX_BEHIND = int(os.environ.get('AIRC_SUITE_MAX_BEHIND', 200))
# Which app build step produces which pinned bundle (and its verified binaries).
PRODUCTS = {
    'build-webkit': ('Airc.app', ('Airc.app/Contents/MacOS/Airc',)),
    'build-chromium': ('Airc-Chromium.app', ('Airc-Chromium.app/Contents/MacOS/Airc',
                       'Airc-Chromium.app/Contents/Frameworks/Airc Framework.framework/Airc Framework')),
}
BINARIES = tuple(b for _, (_, names) in PRODUCTS.items() for b in names)


def immutable(steps):
    """Bundles that no later step rewrites: link them instead of copying again."""
    names = [bundle for step, (bundle, _) in PRODUCTS.items() if steps.get(step) == 0]
    if all(steps.get(step) == 0 for step in PRODUCTS):
        names.append('dSYMs')   # both builds add to it; only final once both ran
    return names


def built_binaries(steps):
    return [b for step, (_, names) in PRODUCTS.items() if steps.get(step) == 0 for b in names]


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as f:
        json.dump(value, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    temporary.replace(path)


def runner_identity(repo):
    # App source and build-app.sh belong to the pinned build/inventory. New
    # scenarios on main must not invalidate an otherwise unchanged runner.
    paths = list((repo / 'infra/suite').glob('*.py'))
    paths += [repo / name for name in (
        'infra/ui_gate.py', 'infra/engine-inputs.sh',
        'scripts/ui-session-preflight.py', 'scripts/check-redirect-history.py',
        'scripts/ui-check-lock.py',
    )]
    files = {str(p.relative_to(repo)): digest(p) for p in sorted(paths)}
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(), files


def case_ids(cases):
    occurrences = {}
    for case in cases:
        key = (case['engine'], case['script'])
        occurrences[key] = occurrences.get(key, 0) + 1
        yield f'{key[0]}/{key[1]}-{occurrences[key]}'


class Checkpoints:
    def __init__(self, suite):
        self.suite = Path(suite)
        self.pointer = self.suite / 'checkpoint.json'
        self.root = self.suite / 'checkpoints'

    def read(self):
        try:
            return json.loads(self.pointer.read_text())
        except (OSError, ValueError):
            return None

    def directory(self, record):
        campaign, generation = record['campaign'], record['generation']
        if not all(re.fullmatch(r'[0-9]+', x) for x in (campaign, generation)):
            raise ValueError('invalid checkpoint identity')
        base = self.root / campaign
        if base.is_symlink() or (base / '.owner').read_text() != OWNER:
            raise ValueError('not an owned checkpoint')
        target = base / generation
        if self.root.is_symlink() or target.is_symlink():
            raise ValueError('checkpoint directory is a symlink')
        return target

    def discard(self, record=None):
        record = record or self.read()
        if record:
            try:
                base = self.directory(record).parent
            except (KeyError, TypeError, ValueError, OSError):
                base = None
            if base is not None:
                shutil.rmtree(base)
        self.pointer.unlink(missing_ok=True)

    def expire(self, now=None):
        record = self.read()
        if record and (time.time() if now is None else now) - record.get('created_at', 0) > MAX_AGE:
            self.discard(record)
            return True
        return False

    def select(self, engine_marker, runner_sha, now=None, behind=0):
        """Resume point for a cleanly preempted run, or (None, why it was dropped).

        behind: commits origin/main is ahead of the pinned revision; None means the
        pinned revision is no longer an ancestor of main (or unknown)."""
        record = self.read()
        if not record:
            return None, None
        reason = None
        try:
            build = self.directory(record) / 'build'
            age = (time.time() if now is None else now) - record['created_at']
            result, cases = record['result'], record['inventory']
            plan, steps = result['plan'], result['steps']
            if record.get('schema') != SCHEMA:
                reason = 'checkpoint schema changed'
            elif not record.get('clean_preemption'):
                reason = 'checkpoint was not cleanly preempted'
            elif age > MAX_AGE or age < 0:
                reason = 'checkpoint expired or has an invalid creation time'
            elif engine_marker != result['engine_marker']:
                reason = 'engine marker changed'
            elif runner_sha != result['runner_sha']:
                reason = 'suite runner SHA changed'
            elif behind is None:
                reason = 'pinned revision is no longer on main'
            elif behind > MAX_BEHIND:
                reason = f'main moved {behind} commits past the pinned revision (limit {MAX_BEHIND})'
            elif (result['dry_run'] or not cases or result['expected'] != len(cases)
                  or list(steps) != plan[:len(steps)] or any(steps.values())
                  or not all(step in plan for step in PRODUCTS)
                  or (result['cases'] and len(steps) != len(plan))
                  or not re.fullmatch(r'[0-9a-f]{40}', result['revision'])):
                reason = 'incomplete pinned build or inventory'
            elif [c['id'] for c in result['cases']] != list(case_ids(cases))[:len(result['cases'])]:
                reason = 'completed cases are not an inventory prefix'
            elif len(result['cases']) > len(cases):
                reason = 'completed case count exceeds inventory'
            else:
                for name in built_binaries(steps):
                    path = build / name
                    if (not path.is_file() or not path.stat().st_mode & 0o111
                            or not path.resolve().is_relative_to(build.resolve())
                            or digest(path) != record['build_hashes'][name]):
                        reason = 'pinned build missing or changed'
                        break
        except (KeyError, TypeError, ValueError, OSError):
            reason = 'checkpoint metadata or pinned build missing'
        if reason:
            self.discard(record)
            return None, reason
        return record, None

    def snapshot(self, source, result, previous, inventory, inventory_source, now=None):
        """Commit state only after its app has exited and its UI lock is released.

        Unchanged bundle files are linked locally; mutable fixtures use rsync's
        checksum comparison, so equal-size writes within one second survive.
        A failed/interrupted transfer leaves the previous checkpoint intact.
        """
        old = self.read()
        campaign = result['logs']
        if not re.fullmatch(r'[0-9]+', campaign):
            raise ValueError('invalid campaign identity')
        if old and old['campaign'] != campaign:
            self.discard(old)
            old = None
        base = self.root / campaign
        if not base.exists():
            base.mkdir(parents=True)
            (base / '.owner').write_text(OWNER)
        generation = str(time.time_ns())
        record = dict(schema=SCHEMA, campaign=campaign, generation=generation,
                      created_at=old['created_at'] if old else (time.time() if now is None else now),
                      clean_preemption=False, result=result, previous=previous,
                      inventory=inventory, inventory_source=inventory_source)
        destination = self.directory(record)
        build = destination / 'build'
        build.mkdir(parents=True)
        try:
            args = ['rsync', '-az', '--checksum', '--delete', '--exclude=/.swiftpm*/', '--exclude=/blocking/']
            hashes = {}
            if old:
                prior = self.directory(old) / 'build'
                hashes = {k: v for k, v in old.get('build_hashes', {}).items()
                          if k in built_binaries(old['result']['steps'])}
                for name in immutable(old['result']['steps']):
                    if (prior / name).exists():
                        shutil.copytree(prior / name, build / name, copy_function=os.link, symlinks=True)
                    args.append('--exclude=/' + name + '/')
                args += ['--link-dest=' + str(prior.resolve())]
            subprocess.run([*args, source, str(build) + '/'], check=True, timeout=1800)
            for name in built_binaries(result['steps']):
                hashes.setdefault(name, digest(build / name))
            record['build_hashes'] = hashes
            # Metadata is part of the committed generation, useful independently
            # of the rolling pointer when diagnosing an interrupted transfer.
            write(destination / 'checkpoint.json', record)
            write(self.pointer, record)
        except BaseException:
            # A signal immediately after rename must not erase committed state.
            current = self.read() or {}
            if current.get('generation') != generation:
                shutil.rmtree(destination)
            raise
        if old:
            shutil.rmtree(self.directory(old))
        return record

    def activate(self, record):
        record = dict(record, clean_preemption=False)
        write(self.pointer, record)

    def preempted(self, result, cleanup_pending=None):
        record = self.read()
        if record and record['campaign'] == result['logs'] and (result.get('cleanup_exit') == 0 or cleanup_pending):
            record.update(clean_preemption=True, preempted_at=time.time(),
                          preemption_reason=result.get('reason', 'preempted'), cleanup_pending=cleanup_pending)
            # Progress bookkeeping lives in the result so the status line survives resumes.
            for key in ('yields', 'last_yield', 'transient_errors'):
                if key in result:
                    record['result'][key] = result[key]
            write(self.pointer, record)

    def complete(self, campaign):
        record = self.read()
        if record and record['campaign'] == campaign:
            self.discard(record)
