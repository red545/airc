#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Summarise an xctrace time-profile export: main-thread samples inside a focus frame (default CA commit),
optionally only inside signpost intervals (an exported os-signpost-interval table, --intervals FILE).
Usage: tpsum.py export.xml [--name SIGNPOST] [--intervals intervals.xml] [--threads] [focus-substring ...]
--threads: every thread, not only the main one, with a per-thread count (an idle trace: what still runs)."""
import sys, collections
import xml.etree.ElementTree as ET

args = sys.argv[1:]
path = args.pop(0)
intervals = None
want_name = None
if args and args[0] == "--name":
    args.pop(0); want_name = args.pop(0)
all_threads = "--threads" in args
if all_threads: args.remove("--threads")
if args and args[0] == "--intervals":
    args.pop(0); ipath = args.pop(0)
    intervals = []
    iids = {}
    def ires(e):
        r = e.get("ref")
        if r is not None: return iids[r]
        i = e.get("id")
        if i is not None: iids[i] = e
        for c in e: ires(c)
        return e
    for row in ET.parse(ipath).getroot().iter("row"):
        start = dur = None; name = ""
        for c in row:
            c = ires(c)
            if c.tag == "start-time": start = int(c.text)
            elif c.tag == "duration": dur = int(c.text)
            elif c.tag == "signpost-name": name = c.get("fmt") or (c.text or "")
        if want_name and name != want_name: continue
        if start is not None and dur is not None:
            intervals.append((start, start + dur))
    intervals.sort()
    print(f"intervals {len(intervals)}, total {sum(b-a for a,b in intervals)/1e6:.1f} ms, median {sorted(b-a for a,b in intervals)[len(intervals)//2]/1e6 if intervals else 0:.2f} ms")
focus = args or None
ids = {}
def resolve(e):
    r = e.get("ref")
    if r is not None:
        return ids[r]
    i = e.get("id")
    if i is not None:
        ids[i] = e
    for c in e:
        resolve(c)
    return e

import bisect
starts = [a for a, b in intervals] if intervals else []
def inside_interval(t):
    if intervals is None: return True
    k = bisect.bisect_right(starts, t) - 1
    return k >= 0 and t <= intervals[k][1]

total = 0; main = 0; inside = 0; threads = collections.Counter()
incl = collections.Counter(); leaf = collections.Counter(); callee = collections.Counter(); ours = collections.Counter()
for row in ET.parse(path).getroot().iter("row"):
    thread = None; bt = None; t = None
    for c in row:
        c = resolve(c)
        if c.tag == "thread": thread = c.get("fmt", "")
        elif c.tag in ("backtrace", "tagged-backtrace"): bt = c
        elif c.tag == "sample-time": t = int(c.text)
    total += 1
    if thread is None or bt is None or (not all_threads and "Main Thread" not in thread): continue
    main += 1
    threads[thread.split(" 0x")[0]] += 1
    if t is None or not inside_interval(t): continue
    frames = [resolve(f).get("name", "?") for f in bt if resolve(f).tag == "frame"]
    idx = None
    if focus:
        for k, name in enumerate(frames):
            if any(s in name for s in focus): idx = k
        if idx is None: continue
        below = frames[:idx]
    else:
        below = frames
    inside += 1
    for name in set(below): incl[name] += 1
    for name in set(frames):
        if "." in name and ("Airc" in name or "Controller" in name or "View" in name) and not name.startswith(("-[", "+[", "CA::", "AG::", "NS")): ours[name] += 1
    if below:
        leaf[below[0]] += 1
        callee[below[-1]] += 1
print(f"samples {total}, {'all threads' if all_threads else 'main'} {main}, selected (focus {focus}): {inside}")
if all_threads: print("-- threads"); [print(f"{n:5d} {k[:120]}") for k, n in threads.most_common(15)]
print("-- direct callees"); [print(f"{n:5d} {k[:150]}") for k, n in callee.most_common(8)]
print("-- inclusive"); [print(f"{n:5d} {k[:150]}") for k, n in incl.most_common(90) if not k.startswith("0x")]
print("-- swift frames"); [print(f"{n:5d} {k[:150]}") for k, n in ours.most_common(30)]
print("-- leaf"); [print(f"{n:5d} {k[:150]}") for k, n in leaf.most_common(15)]
