#!/usr/bin/env python3
"""Synthetic update-download stall matrix (updstall).

Downloads the live update enclosures repeatedly, one fresh process (and so a
fresh connection) per download, interleaving clients in a shuffled order per
repetition so time-of-day effects hit every client alike. Read-only: never
touches network settings, feeds or published files.

Clients:
  curl-h1   curl --http1.1
  curl-h2   curl --http2
  us        sparkle-like-download (URLSession configured like SPUDownloader)
  us-bg     same, networkServiceType .background (Sparkle's background checks)
  nw-h1     HTTP/1.1 over NWConnection (Network.framework user-space TCP, no h2)
DNS variants (curl only): "sys" = system resolver order (Tailscale first on the
build Mac); "router" = curl --resolve with the address the LAN router's DNS
returns, so the system resolver is bypassed for that one process.

Usage: matrix.py --out results.jsonl [--reps 30] [--clients curl-h1,curl-h2,us,us-bg]
                 [--targets delta,zip16] [--full-zip-reps 5] --router-dns <addr> [--extra-dns name=<addr>,...]
                 [--probe path/to/sparkle-like-download]
Each line of the output is one download (or one DNS sample).
"""
import argparse, json, os, random, shutil, subprocess, sys, tempfile, time, socket
from urllib.parse import urlparse

FEED_BASE = "https://aircbrowser.com/releases/0.1.16/202611150343/"
TARGETS = {
    "delta": (FEED_BASE + "Airc-202611150343-202611141334.delta", None, 3552698),
    "zip16": (FEED_BASE + "Airc-0.1.16.zip", 16 * 1024 * 1024, 16 * 1024 * 1024),
    "zip": (FEED_BASE + "Airc-0.1.16.zip", None, 212157205),
}
BLOB_HOST = "hpqylr02za4pig6a.public.blob.vercel-storage.com"
SITE_HOST = "aircbrowser.com"
STALL_GAP = 5.0  # seconds without progress that we count as a stall event


def dig(server, host):
    try:
        if shutil.which("dig"):
            out = subprocess.run(["dig", "+short", "+time=2", "+tries=1", f"@{server}", host, "A"],
                                 capture_output=True, text=True, timeout=6).stdout
            return [l for l in out.split() if l[:1].isdigit()]
    except Exception as e:
        return [f"error {e}"]
    return []


def system_ips(host):
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)})
    except Exception as e:
        return [f"error {e}"]


def run_curl(client, url, rng, resolve, workdir):
    out_path = os.path.join(workdir, "body")
    if os.path.exists(out_path):
        os.remove(out_path)
    cmd = ["curl", "-sS", "-L", "-o", out_path, "--connect-timeout", "15",
           # Same bound as Sparkle: give up after 60 s without data.
           "-y", "60", "-Y", "1", "--max-time", "150",
           "-H", "Cache-Control: no-cache",
           "-w", "%{json}"]
    cmd.append("--http1.1" if client == "curl-h1" else "--http2")
    if rng:
        cmd += ["-r", f"0-{rng - 1}"]
    for r in resolve:
        cmd += ["--resolve", r]
    cmd.append(url)
    start = time.monotonic()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL)
    last_size, last_change, max_gap, gap_at, first_byte = 0, start, 0.0, 0, None
    while p.poll() is None:
        time.sleep(0.1)
        try:
            size = os.path.getsize(out_path)
        except OSError:
            size = 0
        now = time.monotonic()
        if size != last_size:
            if first_byte is None:
                first_byte = now - start
            gap = now - last_change
            if gap > max_gap:
                max_gap, gap_at = gap, last_size
            last_size, last_change = size, now
    out, err = p.communicate()
    end = time.monotonic()
    tail = end - last_change
    try:
        w = json.loads(out)
    except Exception:
        w = {}
    rc = p.returncode
    if rc != 0 and tail > max_gap:
        max_gap, gap_at = tail, last_size
    return {
        "ok": rc == 0 and 200 <= int(w.get("http_code", 0)) < 300,
        "rc": rc,
        "bytes": int(w.get("size_download", last_size) or last_size),
        "status": int(w.get("http_code", 0) or 0),
        "seconds": round(end - start, 3),
        "firstByte": round(first_byte, 3) if first_byte is not None else -1,
        "maxGap": round(max_gap, 3),
        "maxGapAtBytes": gap_at,
        "peer": w.get("remote_ip"),
        "httpVersion": w.get("http_version"),
        "redirects": w.get("num_redirects"),
        "error": (err.strip().splitlines() or [""])[-1][:200] if rc else None,
    }


def run_us(client, url, rng, probe):
    if client == "nw-h1":
        probe = os.path.join(os.path.dirname(probe), "nw-h1-download")
    cmd = [probe, url]
    if client == "us-bg":
        cmd.append("--background")
    if rng:
        cmd += ["--range", str(rng)]
    start = time.monotonic()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=170, stdin=subprocess.DEVNULL)
        line = (p.stdout.strip().splitlines() or ["{}"])[-1]
        r = json.loads(line)
    except subprocess.TimeoutExpired:
        r = {"ok": False, "error": "outer timeout"}
    except Exception as e:
        r = {"ok": False, "error": f"probe output: {e}"}
    r.pop("client", None)
    tx = r.get("transactions") or []
    last = tx[-1] if tx else {}
    r["peer"] = last.get("peer")
    r["httpVersion"] = last.get("protocol")
    r.setdefault("seconds", round(time.monotonic() - start, 3))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--reps", type=int, default=30)
    ap.add_argument("--clients", default="curl-h1,curl-h2,us,us-bg")
    ap.add_argument("--targets", default="delta,zip16")
    ap.add_argument("--dns", default="sys,router")
    ap.add_argument("--full-zip-reps", type=int, default=5)
    ap.add_argument("--router-dns", required=True, help="LAN router DNS server address")
    ap.add_argument("--extra-dns", default="", help="comma-separated name=server resolvers to sample, e.g. tailscale=<addr>")
    ap.add_argument("--probe", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "sparkle-like-download"))
    ap.add_argument("--host-label", default="unlabeled")
    ap.add_argument("--seed", type=int, default=None)
    a = ap.parse_args()
    clients = a.clients.split(",")
    targets = a.targets.split(",")
    dnsmodes = a.dns.split(",")
    rnd = random.Random(a.seed)
    workdir = tempfile.mkdtemp(prefix="updstall-")
    out = open(a.out, "a", buffering=1)

    def emit(rec):
        rec["host"] = a.host_label
        rec["t"] = round(time.time(), 3)
        out.write(json.dumps(rec, sort_keys=True) + "\n")

    def combos(target_list, reps_label):
        cs = []
        for c in clients:
            for t in target_list:
                for d in dnsmodes:
                    if not c.startswith("curl") and d != "sys":
                        continue  # URLSession has no per-process resolver override
                    cs.append((c, t, d))
        return cs

    def one(rep, c, t, d):
        url, rng, expected = TARGETS[t]
        resolve = []
        if d == "router":
            site = dig(a.router_dns, SITE_HOST)
            blob = dig(a.router_dns, BLOB_HOST)
            if site and blob:
                resolve = [f"{SITE_HOST}:443:{site[0]}", f"{BLOB_HOST}:443:{blob[0]}"]
        if c.startswith("curl"):
            r = run_curl(c, url, rng, resolve, workdir)
        else:
            r = run_us(c, url, rng, a.probe)
        r.update({"kind": "download", "rep": rep, "client": c, "target": t, "dns": d,
                  "expected": expected, "resolve": resolve or None})
        r["complete"] = bool(r.get("ok")) and r.get("bytes") == expected
        r["stall"] = (r.get("maxGap") or 0) >= STALL_GAP or not r["complete"]
        emit(r)
        flag = "STALL" if r["stall"] else "ok"
        print(f"{rep:02d} {c:8s} {t:6s} {d:6s} {flag:5s} {r.get('bytes')}/{expected} "
              f"{r.get('seconds')}s gap {r.get('maxGap')} peer {r.get('peer')} {r.get('httpVersion')}",
              flush=True)

    for rep in range(1, a.reps + 1):
        emit({"kind": "dns", "rep": rep,
              "system": {h: system_ips(h) for h in (SITE_HOST, BLOB_HOST)},
              "router": {h: dig(a.router_dns, h) for h in (SITE_HOST, BLOB_HOST)},
              **{n: {h: dig(srv, h) for h in (SITE_HOST, BLOB_HOST)}
                 for n, srv in (x.split("=", 1) for x in a.extra_dns.split(",") if x)}})
        cs = combos(targets, rep)
        rnd.shuffle(cs)
        for c, t, d in cs:
            one(rep, c, t, d)
    for rep in range(1, a.full_zip_reps + 1):
        cs = [(c, "zip", "sys") for c in clients if c not in ("us-bg", "nw-h1")]
        rnd.shuffle(cs)
        for c, t, d in cs:
            one(rep, c, t, d)
    shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
