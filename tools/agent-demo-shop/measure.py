#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Centres of the controls the demo agent clicks (elements with data-m), per page, at the agent window's 1280 × 800
viewport, from headless Chrome. The script in Debug/MarketingAgentDemo.swift uses these numbers.
Usage: python3 measure.py <port of serve.py> [chrome]"""
import json
import re
import subprocess
import sys

port = sys.argv[1]
chrome = sys.argv[2] if len(sys.argv) > 2 else "google-chrome"
out = {}
for path in ["/", "/search", "/search#m2", "/compare", "/bag", "/checkout"]:
    dom = subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--window-size=1280,800",
                          "--virtual-time-budget=5000", "--dump-dom", f"http://127.0.0.1:{port}{path}" + ("" if "#" in path else "#m")],
                         capture_output=True, text=True, timeout=60).stdout
    m = re.search(r"<title>(\{.*?\})</title>", dom, re.S)
    out[path] = json.loads(m.group(1).replace("&quot;", '"')) if m else "no measurement"
print(json.dumps(out, indent=1))
