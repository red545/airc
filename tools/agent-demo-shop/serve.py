#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Serves site/ the way the app does (`/x` → x.html, `/` → index.html, any method), for previews and measure.py.
Usage: python3 serve.py <port>"""
import http.server
import os
import sys

SITE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css", ".webp": "image/webp", ".png": "image/png",
         ".ttf": "font/ttf", ".woff2": "font/woff2", ".txt": "text/plain"}


def resolve(path):
    path = path.split("?")[0].split("#")[0]
    if path == "/":
        return os.path.join(SITE, "index.html")
    f = os.path.normpath(os.path.join(SITE, path.lstrip("/")))
    if not f.startswith(SITE):
        return None
    if os.path.isfile(f):
        return f
    if os.path.isfile(f + ".html"):
        return f + ".html"
    return None


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        f = resolve(self.path)
        if not f:
            self.send_response(404); self.end_headers(); return
        body = open(f, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", TYPES.get(os.path.splitext(f)[1], "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_GET

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
