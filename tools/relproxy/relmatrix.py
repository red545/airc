#!/usr/bin/env python3
"""relproxy: repeated release downloads through two routes, to compare the live
308 to the Blob host's single regional address with a Vercel external rewrite
(aircbrowser.com's anycast edge proxies /releases/* to Blob).

Routes:
  redirect       https://aircbrowser.com/releases/...  (live: 308 -> Blob host DNS address). Read-only control.
  proxy          https://<preview>/releases/...         (preview deployment with the rewrite)
  proxy-anycast  same, curl only, connected to --anycast (the address range aircbrowser.com resolves to)
Clients: curl-h1, curl-h2 (tools/updstall/matrix.py run_curl: 60 s no-data limit like Sparkle),
         us / us-bg (relproxy-download: URLSession configured like Sparkle's SPUDownloader; sends
         Accept-Encoding, so it gets the edge's on-the-fly brotli and decodes it).
Targets: delta (whole 0.1.16->0.1.17 delta), zip16 (Range: first 16 MiB of the ZIP), zip (whole ZIP,
         --full-reps). Every finished download is hashed and compared with the published sha256.
The preview is behind Deployment Protection; the bypass value is read from --bypass-file and sent as
a query parameter (Sparkle can't send headers either). It is never printed or written to the output.

Usage: relmatrix.py --out x.jsonl --preview https://<preview-host> --bypass-file F [--reps 30]
                    [--routes proxy,proxy-anycast,redirect] [--redirect-reps 10]
                    [--clients curl-h1,curl-h2,us,us-bg] [--targets delta,zip16] [--full-reps 0]
                    [--probe ./relproxy-download] [--host-label linux]
"""
import argparse, hashlib, json, os, random, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "updstall"))
import matrix  # noqa: E402  (run_curl, STALL_GAP)

PATH = "/releases/0.1.17/202611151025/"
FILES = {
    "delta": ("Airc-202611151025-202611150343.delta", None, 2908106,
              "1142ddae9d84675adafb54b97601fc0bc7edd6d62a8bab1adbaa9d2ca0495165"),
    "zip16": ("Airc-0.1.17.zip", 16 * 1024 * 1024, 16 * 1024 * 1024,
              None),  # filled from --zip16-sha (first 16 MiB of the published ZIP)
    "zip": ("Airc-0.1.17.zip", None, 212349576,
            "a0e2a8e7f89dcba4c134c33d86e39c67d8755bf1b77941c722d14513acd8787b"),
}


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_us(client, url, rng, probe):
    cmd = [probe, url]
    if client == "us-bg":
        cmd.append("--background")
    if rng:
        cmd += ["--range", str(rng)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=420, stdin=subprocess.DEVNULL)
        r = json.loads((p.stdout.strip().splitlines() or ["{}"])[-1])
    except Exception as e:
        return {"ok": False, "error": str(e)[:200]}
    tx = r.get("transactions") or [{}]
    r["peer"] = tx[-1].get("peer")
    r["httpVersion"] = tx[-1].get("protocol")
    r["redirects"] = max(0, len(tx) - 1)
    r.pop("client", None)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--preview", required=True)
    ap.add_argument("--bypass-file", required=True)
    ap.add_argument("--reps", type=int, default=30)
    ap.add_argument("--redirect-reps", type=int, default=10)
    ap.add_argument("--routes", default="proxy,proxy-anycast,redirect")
    ap.add_argument("--clients", default="curl-h1,curl-h2,us,us-bg")
    ap.add_argument("--targets", default="delta,zip16")
    ap.add_argument("--full-reps", type=int, default=0)
    ap.add_argument("--anycast", default="216.150.1.1")
    ap.add_argument("--zip16-sha", required=True)
    ap.add_argument("--probe", default=os.path.join(HERE, "relproxy-download"))
    ap.add_argument("--host-label", default="linux")
    ap.add_argument("--seed", type=int, default=11)
    a = ap.parse_args()
    FILES["zip16"] = FILES["zip16"][:3] + (a.zip16_sha,)
    bypass = open(a.bypass_file).read().strip()
    preview_host = a.preview.split("://", 1)[1].rstrip("/")
    rnd = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix="relproxy-")
    out = open(a.out, "a", buffering=1)
    clients = a.clients.split(",")
    routes = a.routes.split(",")
    combos = [(r, c, t) for r in routes for c in clients for t in a.targets.split(",")
              if not (r == "proxy-anycast" and not c.startswith("curl"))]
    if a.full_reps:
        full = [(r, c, "zip") for r in routes for c in clients if r != "redirect"
                and not (r == "proxy-anycast" and not c.startswith("curl"))]
    total_reps = max(a.reps, a.full_reps)
    for rep in range(1, total_reps + 1):
        todo = [x for x in combos if rep <= (a.redirect_reps if x[0] == "redirect" else a.reps)]
        if a.full_reps and rep <= a.full_reps:
            todo += full
        rnd.shuffle(todo)
        for route, c, target in todo:
            name, rng, expected, want_sha = FILES[target]
            if route == "redirect":
                url = "https://aircbrowser.com" + PATH + name
            else:
                url = f"https://{preview_host}{PATH}{name}?x-vercel-protection-bypass={bypass}"
            if c.startswith("curl"):
                resolve = [f"{preview_host}:443:{a.anycast}"] if route == "proxy-anycast" else []
                r = matrix.run_curl(c, url, rng, resolve, work)
                body = os.path.join(work, "body")
                r["sha256"] = sha(body) if os.path.exists(body) else ""
                if os.path.exists(body):
                    os.remove(body)
                if r.get("error"):
                    r["error"] = r["error"].replace(bypass, "BYPASS")
            else:
                r = run_us(c, url, rng, a.probe)
            r.update({"host": a.host_label, "rep": rep, "route": route, "client": c, "target": target,
                      "expected": expected, "t": round(time.time(), 3)})
            r["complete"] = bool(r.get("ok")) and r.get("bytes") == expected
            r["shaOk"] = r.get("sha256") == want_sha
            r["stall"] = (r.get("maxGap") or 0) >= matrix.STALL_GAP or not r["complete"]
            line = json.dumps(r, sort_keys=True)
            assert bypass not in line
            out.write(line + "\n")
            print(f"{rep:02d} {route:13s} {c:6s} {target:5s} {'STALL' if r['stall'] else 'ok':5s} "
                  f"sha {'ok' if r['shaOk'] else 'BAD'} {r.get('bytes')} {r.get('seconds')}s "
                  f"gap {r.get('maxGap')} peer {r.get('peer')} {r.get('contentEncoding') or ''}", flush=True)
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
