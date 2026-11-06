#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Exercise the real series on a small copy; never mutate the source mirror."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

engine = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).resolve()
manifest = json.loads((engine / 'patches/manifest.json').read_text())
retired = json.loads((engine / 'patches/retired.json').read_text())
original = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in [*manifest, *retired]}
with tempfile.TemporaryDirectory(prefix='airc-apply-', dir=Path.home()) as tmp:
    scratch = Path(tmp)
    for name in [*manifest, *retired, 'chrome/VERSION']:
        target = scratch / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    def apply(*args, success=True):
        run = subprocess.run([str(engine / 'apply.sh'), '--src', str(scratch), *args], capture_output=True, text=True)
        assert (run.returncode == 0) == success, run.stdout + run.stderr
        print((run.stdout + run.stderr).strip())
    apply('--check')
    assert not (scratch / 'airc').exists(), 'check mode wrote the core'
    apply(); apply('--check'); apply(); apply('--check')
    for name, hashes in manifest.items():
        assert hashlib.sha256((scratch / name).read_bytes()).hexdigest() == hashes['after']
    # A pre-refactor build must be rejected by check, migrated by apply, then
    # checked as genuinely pristine upstream (not merely omitted from the count).
    import importlib.util
    spec = importlib.util.spec_from_file_location('airc_apply', engine / 'apply.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    for name, hashes in retired.items():
        target = scratch / name
        pristine = target.read_bytes()
        old = module.apply_diff(pristine, (engine / 'patches' / hashes['patch']).read_text().splitlines(keepends=True))
        assert module.digest(old) == hashes['after']
        target.write_bytes(old)
        apply('--check', success=False)
        apply(); apply('--check')
        assert target.read_bytes() == pristine
        target.write_bytes(old + b'\n// drift\n')
        apply(success=False)
        assert target.read_bytes() == old + b'\n// drift\n'
        target.write_bytes(pristine)
    drift = scratch / 'chrome/BUILD.gn'
    drift.write_text(drift.read_text() + '\n# deliberate test drift\n')
    apply('--check', success=False)
    before = drift.read_bytes(); apply(success=False); assert drift.read_bytes() == before
for name, sha in original.items():
    assert hashlib.sha256((source / name).read_bytes()).hexdigest() == sha
print('PASS pristine dry run, apply, applied check, repeat apply, drift refusal, mirror unchanged')
