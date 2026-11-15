#!/usr/bin/env python3
"""Path control for updstall: the same Blob object (first 16 MiB of the 0.1.16
ZIP) fetched from the Blob host's DNS address (Vercel fra1 edge) and from
Vercel's anycast addresses, which serve the Blob host by SNI too. Clients:
curl --http1.1, curl --http2 (kernel TCP) and nw-h1-download (Network.framework
user-space TCP, the stack URLSession uses). One fresh process per download.

Usage: paths.py --out paths.jsonl [--reps 20] --ips <blob-dns-addr>,<vercel-anycast-addr>
                [--clients curl-h1,curl-h2,nw-h1]
"""
import argparse, json, os, random, socket, subprocess, time, tempfile, shutil
import matrix

BLOB = matrix.BLOB_HOST
URL = f"https://{BLOB}/releases/0.1.16/202611150343/Airc-0.1.16.zip"
RANGE = 16 * 1024 * 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--ips", required=True, help="comma-separated addresses: the Blob host's DNS answer and a Vercel anycast address")
    ap.add_argument("--clients", default="curl-h1,curl-h2,nw-h1")
    ap.add_argument("--host-label", default="buildmac")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    rnd = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix="updstall-paths-")
    out = open(a.out, "a", buffering=1)
    combos = [(c, ip) for c in a.clients.split(",") for ip in a.ips.split(",")]
    for rep in range(1, a.reps + 1):
        rnd.shuffle(combos)
        for c, ip in combos:
            if c.startswith("curl"):
                r = matrix.run_curl(c, URL, RANGE, [f"{BLOB}:443:{ip}"], work)
            else:
                cmd = [os.path.join(here, "nw-h1-download"), URL, "--range", str(RANGE), "--connect", ip]
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=170, stdin=subprocess.DEVNULL)
                    r = json.loads((p.stdout.strip().splitlines() or ["{}"])[-1])
                except Exception as e:
                    r = {"ok": False, "error": str(e)}
                tx = r.get("transactions") or [{}]
                r["peer"] = tx[-1].get("peer")
                r["httpVersion"] = "1.1-nw"
                r.pop("client", None)
            r.update({"kind": "download", "host": a.host_label, "rep": rep, "client": c, "target": "zip16",
                      "dns": f"ip:{ip}", "expected": RANGE, "t": round(time.time(), 3)})
            r["complete"] = bool(r.get("ok")) and r.get("bytes") == RANGE
            r["stall"] = (r.get("maxGap") or 0) >= matrix.STALL_GAP or not r["complete"]
            out.write(json.dumps(r, sort_keys=True) + "\n")
            print(f"{rep:02d} {c:8s} {ip:15s} {'STALL' if r['stall'] else 'ok':5s} {r.get('bytes')} "
                  f"{r.get('seconds')}s gap {r.get('maxGap')} peer {r.get('peer')}", flush=True)
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
