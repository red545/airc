# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import os
import subprocess
import threading
import unittest
from scratch_paths import probe, storage_root


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


class ScratchTests(unittest.TestCase):
    def test_only_owned_scratch_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            root = home/'arcfork/setup/automation/feed-routing'
            self.assertEqual(storage_root(str(root), home), root)
            for bad in [home/'arcfork/updates-local', home/'arcfork/setup/automation/feed-a/../feed-b',
                        root/'child', Path('feed-relative')]:
                with self.subTest(path=str(bad)), self.assertRaises(ValueError):
                    storage_root(str(bad), home)
            root.parent.mkdir(parents=True)
            root.symlink_to(home, target_is_directory=True)
            with self.assertRaises(ValueError):
                storage_root(str(root), home)

    def test_shell_paths_share_scratch_cache_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            root = home/'arcfork/setup/automation/feed-routing'
            script = Path(__file__).with_name('dev-paths.sh')
            command = ['bash', '-ec', 'source "$1"; printf "%s\\n%s\\n" "$DEV_FEED_DIR" "$DEV_CACHE_DIR"', 'paths', str(script)]
            env = dict(os.environ, HOME=str(home), AIRC_SCRATCH_PUBLISH_ROOT=str(root))
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(root/'feed'), str(root/'cache')])
            env['AIRC_SCRATCH_PUBLISH_ROOT'] = str(home/'arcfork/updates-local')
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')

    def test_probe_distinguishes_service_root_and_removes_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served, other = root/'served', root/'other'
            served.mkdir(); other.mkdir()
            server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(served)))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            url = f'http://127.0.0.1:{server.server_port}/appcast.xml'
            try:
                probe(served, url, attempts=1)
                with self.assertRaises(ValueError):
                    probe(other, url, attempts=1)
                self.assertEqual(list(served.iterdir()), [])
                self.assertEqual(list(other.iterdir()), [])
            finally:
                server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__':
    unittest.main()
