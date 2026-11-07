# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Exercise drift reporting against two tiny real Git tags, without syncing Chromium."""
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import update


class UpdateTests(unittest.TestCase):
    def test_header_diff_and_drift(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            src, snap, out = base/'src', base/'snapshot', base/'report'
            src.mkdir(); out.mkdir(); (snap/'engine/core').mkdir(parents=True)
            (snap/'engine/core/test.cc').write_text('#include "api.h"\n#include "generated.h"\n')
            def git(*args):
                return subprocess.run(['git', '-C', str(src), *args], check=True, capture_output=True)
            git('init')
            git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Test')
            (src/'api.h').write_text('old api\n')
            git('add', 'api.h'); git('commit', '-m', 'old'); git('tag', 'old')
            (src/'api.h').write_text('new api\n')
            git('add', 'api.h'); git('commit', '-m', 'new'); git('tag', 'new')
            # Use the real checker with the repository's patch series against the tiny tree:
            # every upstream patch path is absent, and all must be reported, not fail-fast.
            import shutil
            shutil.copytree(update.ROOT/'engine/patches', snap/'engine/patches')
            shutil.copy(update.ROOT/'engine/apply.py', snap/'engine/apply.py')
            with contextlib.redirect_stdout(io.StringIO()):
                update.report(snap, src, 'old', 'new', out)
            headers = (out/'headers.diff').read_text()
            self.assertIn('-old api', headers); self.assertIn('+new api', headers)
            self.assertIn('UNRESOLVED', headers)
            patches = (out/'patches.txt').read_text()
            series = sorted(p.name for p in (snap/'engine/patches').glob('*.patch'))
            self.assertTrue(series)
            self.assertIn(f'{series[0]}: DRIFT', patches)
            for name in series:
                self.assertIn(f'{name}: DRIFT', patches)

    def test_downgrade_does_not_sync(self):
        with patch('sys.argv', ['update.py', '1.0.0.0']), patch.object(update, 'run') as run:
            with self.assertRaisesRegex(SystemExit, 'downgrade'):
                update.main()
            run.assert_not_called()
