# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The engine-inputs check compares trees, not ancestry (infra/engine-inputs.sh)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'infra/engine-inputs.sh'


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, text=True,
                          env=dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                                   GIT_COMMITTER_EMAIL='t@t')).stdout.strip()


def write(repo, rel, text):
    p = Path(repo, rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def commit(repo, msg):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', msg)
    return git(repo, 'rev-parse', 'HEAD')


def check(repo, marker, rev):
    r = subprocess.run(['bash', '-c', '. "$1"; engine_inputs_diff "$2" "$3" "$4"', 'sh', str(HELPER), str(repo), marker, rev],
                       capture_output=True, text=True)
    return r.returncode, r.stdout


class EngineInputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, 'init', '-q', '-b', 'main')
        write(self.repo, 'engine/core/a.cc', 'a\n')
        write(self.repo, 'engine/patches/p.patch', 'p\n')
        write(self.repo, 'engine/BUILD.gn', 'b\n')
        write(self.repo, 'engine/NOTES.md', 'n\n')
        write(self.repo, 'CHROMIUM_VERSION', '1\n')
        self.base = commit(self.repo, 'base')

    def tearDown(self):
        self.tmp.cleanup()

    def branch_commit(self, name, rel, text):
        git(self.repo, 'checkout', '-q', '-b', name, self.base)
        write(self.repo, rel, text)
        sha = commit(self.repo, name)
        git(self.repo, 'checkout', '-q', 'main')
        return sha

    def test_identical_inputs_not_ancestor_passes(self):
        # The marker is on a release branch (not an ancestor of main), with the same engine tree as main.
        marker = self.branch_commit('release', 'docs/release.md', 'notes\n')
        write(self.repo, 'apps/x.swift', 'x\n')
        main = commit(self.repo, 'main app change')
        self.assertNotEqual(subprocess.run(['git', '-C', str(self.repo), 'merge-base', '--is-ancestor', marker, main]).returncode, 0)
        self.assertEqual(check(self.repo, marker, main), (0, ''))

    def test_doc_only_engine_change_passes(self):
        write(self.repo, 'engine/NOTES.md', 'changed\n')
        write(self.repo, 'engine/host/t.cc', 'host\n')
        main = commit(self.repo, 'docs')
        self.assertEqual(check(self.repo, self.base, main)[0], 0)

    def test_differing_engine_refuses_and_names_paths(self):
        marker = self.branch_commit('release', 'docs/release.md', 'notes\n')
        write(self.repo, 'engine/core/a.cc', 'changed\n')
        write(self.repo, 'engine/patches/q.patch', 'q\n')
        main = commit(self.repo, 'engine change')
        rc, out = check(self.repo, marker, main)
        self.assertEqual(rc, 1)
        self.assertEqual(sorted(out.split()), ['engine/core/a.cc', 'engine/patches/q.patch'])

    def test_chromium_version_and_gn_count(self):
        write(self.repo, 'CHROMIUM_VERSION', '2\n')
        write(self.repo, 'engine/BUILD.gn', 'c\n')
        main = commit(self.repo, 'bump')
        rc, out = check(self.repo, self.base, main)
        self.assertEqual((rc, sorted(out.split())), (1, ['CHROMIUM_VERSION', 'engine/BUILD.gn']))

    def test_unknown_marker_is_a_distinct_failure(self):
        rc, out = check(self.repo, 'f' * 40, 'HEAD')
        self.assertEqual(rc, 2)
        self.assertIn('not in this repo', out)


if __name__ == '__main__':
    unittest.main()
