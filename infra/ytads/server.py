#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Local-only YouTube-shaped response server. Does not inject the blocker."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status, extra = 200, {}
        if self.path.split('?')[0] == '/youtubei/v1/player':
            body = json.dumps(dict(playabilityStatus=dict(status='OK'), videoDetails=dict(videoId='fixture'),
                streamingData=dict(formats=[dict(url='/movie.mp4')]), captions=dict(fixture='preserved'),
                adPlacements=[dict(kind='preroll'), dict(kind='midroll')], playerAds=[1], adSlots=[1])).encode()
            kind = 'application/json'
        elif self.path == '/movie.mp4':
            root = Path(os.environ.get('AIRC_YTADS_SOURCE', str(Path(__file__).resolve().parents[2])))
            body = (root / 'apps/marketing/public/video/command.mp4').read_bytes()
            kind = 'video/mp4'
            extra['Accept-Ranges'] = 'bytes'
            value = self.headers.get('Range')
            if value:
                size = len(body)
                try:
                    if not value.startswith('bytes='): raise ValueError()
                    first, last = value[6:].split('-')
                    start = int(first) if first else max(0, size - int(last))
                    end = min(int(last), size - 1) if first and last else size - 1
                    if not (0 <= start <= end < size) or (not first and int(last) <= 0): raise ValueError()
                    body = body[start:end + 1]
                    status, extra['Content-Range'] = 206, f'bytes {start}-{end}/{size}'
                except (ValueError, TypeError):
                    status, body, extra['Content-Range'] = 416, b'', f'bytes */{size}'
        elif self.path == '/captions.vtt':
            body = b'WEBVTT\n\n00:00.000 --> 00:20.000\nFixture captions\n'
            kind = 'text/vtt'
        elif self.path in ['/doubleclick/ad', '/youtube/api/stats/ads']:
            body = b'ad'
            kind = 'text/plain'
        else:
            body = Path(__file__).with_name('fixture.html').read_bytes()
            kind = 'text/html; charset=utf-8'
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        for name, value in extra.items(): self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18761)
    args = parser.parse_args()
    HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
