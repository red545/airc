#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Compile-only preflight using release flags; never writes the engine checkout."""
import os, pathlib, shlex, subprocess
repo = pathlib.Path(__file__).resolve().parents[3]
src = pathlib.Path(os.environ.get('CHROMIUM_SRC', pathlib.Path.home() / 'arcfork/chromium/src'))
out = src / 'out/AircRelease'
work = repo / 'build/apis-compile'
(work / 'airc').mkdir(parents=True, exist_ok=True)
link = work / 'airc/core'
if not link.exists(): link.symlink_to(repo / 'engine/core')
cmd = subprocess.check_output([str(pathlib.Path.home() / 'arcfork/depot_tools/ninja'), '-C', str(out), '-t', 'commands', 'obj/airc/core/core/airc_tab_page.o'], text=True, errors='replace', cwd=src).splitlines()[-1]
args = shlex.split(cmd)
for flag, value in [('-MF',str(work / 'exports.d')), ('-o',str(work / 'exports.o')), ('-c',str(repo / 'engine/core/airc_tab_exports.mm'))]:
    args[args.index(flag)+1] = value
args.insert(1, '-I'+str(work))
raise SystemExit(subprocess.call(args, cwd=out))
