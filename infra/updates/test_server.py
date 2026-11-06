# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The local feed must never serve files outside its configured directory."""
from functools import partial
import http.server
import importlib.util
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

spec = importlib.util.spec_from_file_location('feed_server', Path(__file__).with_name('server.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ServerBoundary(unittest.TestCase):
    def test_get_and_head_share_directory_boundary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            feed = root/'feed'
            feed.mkdir()
            (feed/'appcast.xml').write_text('<rss/>')
            (root/'private').write_text('must not leave the machine')
            (feed/'escape').symlink_to(root/'private')
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), partial(module.Handler, directory=str(feed)))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for method in ('GET', 'HEAD'):
                    for path, expected in (('/appcast.xml', 200), ('/', 404), ('/escape', 403), ('/../private', 404)):
                        with self.subTest(method=method, path=path):
                            req = Request(f'http://127.0.0.1:{server.server_port}{path}', method=method)
                            try:
                                with urlopen(req) as response:
                                    code = response.status
                                    self.assertEqual(response.headers['Cache-Control'], 'no-cache')
                            except HTTPError as error:
                                code = error.code
                                error.close()
                            self.assertEqual(code, expected)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    unittest.main()
