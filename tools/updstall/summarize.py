#!/usr/bin/env python3
"""Summarize updstall matrix JSONL files: stalls per host/client/target/dns."""
import json, sys
from collections import defaultdict


def main(paths):
    rows, dns = [], []
    for p in paths:
        for line in open(p):
            r = json.loads(line)
            (rows if r.get("kind") == "download" else dns).append(r)
    g = defaultdict(list)
    for r in rows:
        g[(r["host"], r["client"], r["target"], r["dns"])].append(r)
    print(f"{'host':10s} {'client':8s} {'target':6s} {'dns':6s} {'n':>3s} {'stall':>5s} {'fail':>4s}  median_s  stalls (bytes@gap s, peer)")
    for k in sorted(g):
        rs = g[k]
        st = [r for r in rs if r["stall"]]
        fail = [r for r in rs if not r["complete"]]
        secs = sorted(r["seconds"] for r in rs if r["complete"])
        med = secs[len(secs) // 2] if secs else float("nan")
        desc = ", ".join(f"{r.get('maxGapAtBytes')}@{r.get('maxGap')}{'' if r['complete'] else '!'} {r.get('peer')}" for r in st)
        print(f"{k[0]:10s} {k[1]:8s} {k[2]:6s} {k[3]:6s} {len(rs):3d} {len(st):5d} {len(fail):4d}  {med:7.2f}  {desc}")
    peers = defaultdict(lambda: [0, 0])
    for r in rows:
        peers[(r["host"], r.get("peer"))][0] += 1
        peers[(r["host"], r.get("peer"))][1] += r["stall"]
    print("\npeer IPs (downloads, stalls):", {f"{h} {p}": v for (h, p), v in peers.items()})
    answers = defaultdict(set)
    for d in dns:
        for src in sorted(k for k in d if isinstance(d[k], dict)):
            for h, ips in (d.get(src) or {}).items():
                answers[(d["host"], src, h)].update(ips)
    print("\nDNS answers seen:")
    for k in sorted(answers):
        print(" ", k, sorted(answers[k]))


if __name__ == "__main__":
    main(sys.argv[1:])
