# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The staller fixture: the first archive GET stalls mid-body, the next is served whole, the feed never stalls."""
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('staller', Path(__file__).with_name('staller.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Staller(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root/'feed').mkdir()
        self.body = os.urandom(3 * 1024 * 1024)
        (root/'feed/Airc-1.zip').write_bytes(self.body)
        (root/'feed/appcast.xml').write_text('<rss/>')
        self.log = root/'requests.jsonl'
        self.server = module.serve(root/'feed', stall=1, after=100_000, hold=30, log=str(self.log))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.staller.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def get(self, path, timeout):
        c = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=timeout)
        c.request('GET', path)
        r = c.getresponse()
        got = bytearray()
        try:
            while chunk := r.read1(65536):
                got += chunk
        except (socket.timeout, TimeoutError):
            return r.status, int(r.headers['Content-Length']), bytes(got), True
        finally:
            c.close()
        return r.status, int(r.headers['Content-Length']), bytes(got), False

    def test_first_archive_get_stalls_then_serves_whole(self):
        self.assertEqual(self.get('/appcast.xml', 2)[2], b'<rss/>')
        started = time.time()
        status, length, got, timed_out = self.get('/Airc-1.zip', 1.5)
        self.assertEqual((status, length, timed_out), (200, len(self.body), True))
        self.assertEqual(got, self.body[:100_000])  # mid-body, then silence
        self.assertLess(time.time() - started, 10)
        status, length, got, timed_out = self.get('/Airc-1.zip', 5)
        self.assertEqual((status, timed_out), (200, False))
        self.assertEqual(hashlib.sha256(got).hexdigest(), hashlib.sha256(self.body).hexdigest())
        # The feed never counts or stalls.
        self.assertEqual(self.get('/appcast.xml', 2)[2], b'<rss/>')
        self.server.staller.release.set()
        for _ in range(50):
            rows = [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []
            if len(rows) >= 5:
                break
            time.sleep(0.1)
        archive = sorted((r for r in rows if r.get('archiveGet')), key=lambda r: (r['archiveGet'], r['phase']))
        self.assertEqual([(r['archiveGet'], r['stalled'], r['phase']) for r in archive],
                         [(1, True, 'done'), (1, True, 'stalling'), (2, False, 'done')])
        self.assertEqual(archive[1]['bytesSent'], 100_000)
        self.assertEqual(archive[2]['bytesSent'], len(self.body))


if __name__ == '__main__':
    unittest.main()
