#!/usr/bin/env python3
"""Tables from relmatrix.py JSONL. Outcomes per download:
  ok        complete, sha256 = published, no gap >= 5 s
  slowstart complete and sha256 = published, but >= 5 s before the first body byte (not a mid-body stall)
  stall     some body bytes arrived, then >= 5 s without data or the download ended incomplete
  connfail  no connection (curl rc 7 / connect error, 0 bytes): local network, not a mid-body stall
  badsha    complete but sha256 differs (must never happen)
Usage: summarize.py file.jsonl [...]
"""
import collections, json, statistics, sys


def outcome(r):
    if r.get("complete") and not r.get("shaOk"):
        return "badsha"
    if r.get("complete") and not r.get("stall"):
        return "ok"
    if r.get("complete") and r.get("shaOk") and not r.get("maxGapAtBytes"):
        return "slowstart"
    err = (r.get("error") or "") + " " + (r.get("underlying") or "")
    if (r.get("bytes") or 0) == 0 and (r.get("rc") in (6, 7) or "connect" in err.lower() or "-1004" in err):
        return "connfail"
    return "stall"


rows = [json.loads(l) for f in sys.argv[1:] for l in open(f) if l.strip()]
cells = collections.defaultdict(list)
for r in rows:
    cells[(r["host"], r["route"], r["client"], r["target"])].append(r)
print("| host | route | client | target | n | ok | slowstart | stall | connfail | badsha | median s (ok) | peers |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for k in sorted(cells):
    rs = cells[k]
    c = collections.Counter(outcome(r) for r in rs)
    secs = [r["seconds"] for r in rs if outcome(r) == "ok"]
    peers = ",".join(sorted({str(r.get("peer")) for r in rs if r.get("peer")}))
    print(f"| {' | '.join(k)} | {len(rs)} | {c['ok']} | {c['slowstart']} | {c['stall']} | {c['connfail']} | {c['badsha']} | "
          f"{statistics.median(secs) if secs else '-'} | {peers} |")
tot = collections.defaultdict(collections.Counter)
for r in rows:
    tot[(r["host"], r["route"])][outcome(r)] += 1
print()
print("| host | route | n | ok | slowstart | stall | connfail | badsha |")
print("|---|---|---|---|---|---|---|---|")
for k in sorted(tot):
    c = tot[k]
    print(f"| {k[0]} | {k[1]} | {sum(c.values())} | {c['ok']} | {c['slowstart']} | {c['stall']} | {c['connfail']} | {c['badsha']} |")
