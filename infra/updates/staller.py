#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Loopback update host whose first archive download stalls mid-body (updretry).

It reproduces the stall seen on a bad route to the update host (artifacts/updstall): the response starts normally,
then no more bytes arrive and the connection stays open until the client gives up. The first `--stall` GETs of an
archive (`.zip`, `.delta`, `.dmg`) send the headers and `--after` bytes of the body, then go silent for `--hold`
seconds; every later GET is served in full. Other files (the appcast) are always served in full.
Every request is appended to `--log` as one JSON line when it ends (`phase: done`); a stall also writes one when
it starts (`phase: stalling`).

    staller.py <dir> [--port 0] [--stall 1] [--after 262144] [--hold 120] [--log requests.jsonl] [--port-file f]
"""
import argparse
import http.server
import json
import threading
import time
from functools import partial
from pathlib import Path

ARCHIVES = ('.zip', '.delta', '.dmg')


class Staller:
    def __init__(self, stall, after, hold, log):
        self.stall, self.after, self.hold, self.log = stall, after, hold, log
        self.archive_gets = 0
        self.lock = threading.Lock()
        self.release = threading.Event()  # set on shutdown: stalled handlers stop holding

    def record(self, entry):
        if self.log:
            with self.lock, open(self.log, 'a') as f:
                f.write(json.dumps(entry) + '\n')


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def __init__(self, *args, staller, **kwargs):
        self.staller = staller
        super().__init__(*args, **kwargs)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

    def list_directory(self, path):
        self.send_error(404)

    def log_message(self, *args):
        pass

    def send_head(self):
        target = Path(self.translate_path(self.path)).resolve()
        if not target.is_relative_to(Path(self.directory).resolve()):
            self.send_error(403)
            return None
        return super().send_head()

    def do_GET(self):
        started = time.time()
        f = self.send_head()
        if f is None:
            self.staller.record({'path': self.path, 'status': 'error', 'time': started})
            return
        s = self.staller
        stall = False
        if self.path.split('?')[0].endswith(ARCHIVES):
            with s.lock:
                s.archive_gets += 1
                n = s.archive_gets
            stall = n <= s.stall
        else:
            n = None
        sent = 0
        try:
            with f:
                if stall:
                    chunk = f.read(s.after)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent = len(chunk)
                    s.record({'path': self.path, 'archiveGet': n, 'stalled': True, 'phase': 'stalling', 'bytesSent': sent,
                              'time': time.time(), 'client': self.client_address[1]})
                    # The far end has dropped the flow: nothing more, and no FIN, until the client gives up.
                    s.release.wait(s.hold)
                    self.close_connection = True
                else:
                    while chunk := f.read(1 << 20):
                        self.wfile.write(chunk)
                        sent += len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        s.record({'path': self.path, 'archiveGet': n, 'stalled': stall, 'phase': 'done', 'bytesSent': sent,
                  'seconds': round(time.time() - started, 3), 'time': started, 'client': self.client_address[1]})


def serve(directory, port=0, stall=1, after=256 * 1024, hold=120, log=None):
    staller = Staller(stall, after, hold, log)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port),
                                             partial(Handler, directory=str(directory), staller=staller))
    server.daemon_threads = True
    server.staller = staller
    return server


if __name__ == '__main__':
    a = argparse.ArgumentParser()
    a.add_argument('directory')
    a.add_argument('--port', type=int, default=0)
    a.add_argument('--stall', type=int, default=1, help='how many archive GETs stall (default 1)')
    a.add_argument('--after', type=int, default=256 * 1024, help='body bytes sent before the stall')
    a.add_argument('--hold', type=float, default=120, help='seconds a stalled connection stays open')
    a.add_argument('--log')
    a.add_argument('--port-file')
    o = a.parse_args()
    server = serve(o.directory, o.port, o.stall, o.after, o.hold, o.log)
    if o.port_file:
        Path(o.port_file).write_text(f'{server.server_port}\n')
    print(f'staller on 127.0.0.1:{server.server_port}', flush=True)
    try:
        server.serve_forever()
    finally:
        server.staller.release.set()
