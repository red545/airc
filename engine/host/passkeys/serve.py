#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Loopback-only HTTPS fixture; cert/key are disposable files outside the repo.
Usage: serve.py CERT KEY [PORT]. No server-side credential persistence.
"""
import http.server
import pathlib
import ssl
import sys
from functools import partial
server = http.server.HTTPServer(('127.0.0.1', int(sys.argv[3]) if len(sys.argv) > 3 else 9443),
    partial(http.server.SimpleHTTPRequestHandler, directory=str(pathlib.Path(__file__).parent)))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
