#!/usr/bin/env python3
"""Downloads and update checks per day, read-only.

    python3 tools/downloads/daily.py [--days 14] [--json] [--record FILE]

Sources (nothing here adds tracking; see README.md):
  PostHog (whole history)
    downloads      site.download: one anonymous event per GET of aircbrowser.com/download (api/download.ts: a
                   random ID, no IP, no cookies; HEAD requests aren't counted). Scripts that GET /download count too.
    new installs   app.launched with first_launch = true (copies with usage data on; it's on by default).
    active         distinct installs sending app.active_day (once per day per install, usage data on).
  Vercel CDN request logs (the last 24 hours only: older ones need Observability Plus)
    dmg            GETs of /releases/*.dmg answered 200 (or 307/308 to Blob before the proxy), or 206 grouped into one per client and file within
                   10 minutes (no IP is logged or used: client = user agent + country).
    via /download  GETs of /download (browsers; scripts listed apart).
    update checks  GETs of /appcast.xml by Airc (Sparkle), by Airc version.
    updates        GETs of update archives (.zip/.delta) by Airc.
  Scripted user agents (curl, python, our own probes) are counted apart, never as downloads.

Credentials: PostHog's personal API key from posthog-cli.env and the Vercel project scope from public-release.env in
$AIRC_SECRETS_DIR (default ~/arcfork/secrets); Vercel itself through the logged-in `vercel` CLI, or VERCEL_TOKEN in the
environment. Nothing secret is printed.
--record FILE appends today's Vercel-derived counts as one JSON line, so a daily run keeps what Vercel forgets.
"""

import argparse
import collections
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

SECRETS = Path(os.environ.get("AIRC_SECRETS_DIR", Path.home() / "arcfork" / "secrets"))
POSTHOG_HOST = "https://eu.posthog.com"
PROJECT = "airc-homepage"
SCRIPTED = re.compile(r"^(curl|wget|python|go-http|node|undici|axios|okhttp|libwww|java|ruby|httpie|postman|[a-z0-9]+-[a-z0-9-]+/)", re.I)
BOTS = re.compile(r"bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|monitor|uptime", re.I)


def env_file(name):
    out = {}
    p = SECRETS / name
    if not p.exists():
        return out
    for line in p.read_text().splitlines():
        m = re.match(r"\s*(?:export\s+)?([A-Z0-9_]+)=(.*)", line)
        if m:
            out[m.group(1)] = m.group(2).strip().strip("'\"")
    return out


# --- PostHog -----------------------------------------------------------------------------------------------------
def posthog(days):
    cfg = env_file("posthog-cli.env")
    key, pid = cfg.get("POSTHOG_CLI_API_KEY"), cfg.get("POSTHOG_CLI_PROJECT_ID")
    if not key or not pid:
        return None, "no PostHog key in posthog-cli.env"
    sql = f"""
      select toDate(timestamp) as d,
             countIf(event = 'site.download') as downloads,
             countIf(event = 'app.launched' and properties.first_launch = true) as new_installs,
             count(distinct if(event = 'app.active_day', distinct_id, null)) as active
      from events
      where timestamp >= toStartOfDay(now()) - interval {int(days) - 1} day
        and event in ('site.download', 'app.launched', 'app.active_day')
      group by d order by d"""
    req = urllib.request.Request(
        f"{POSTHOG_HOST}/api/projects/{pid}/query/",
        data=json.dumps({"query": {"kind": "HogQLQuery", "query": sql}}).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        res = json.load(urllib.request.urlopen(req, timeout=60))
    except (urllib.error.URLError, TimeoutError) as e:
        return None, f"PostHog query failed: {getattr(e, 'code', '')} {getattr(e, 'reason', e)}"
    rows = {}
    for d, downloads, new, active in res.get("results", []):
        rows[str(d)[:10]] = {"downloads": downloads, "new_installs": new, "active_installs": active}
    return rows, None


# --- Vercel ------------------------------------------------------------------------------------------------------
def vercel_requests(query):
    scope = env_file("public-release.env").get("AIRC_VERCEL_SCOPE")
    cmd = ["vercel", "logs", "requests", "--project", PROJECT, "-e", "production", "--since", "24h", "-n", "10000",
           "--json", "-q", query]
    if scope:
        cmd += ["--scope", scope]
    records, cursor = [], None
    for _ in range(20):
        run = cmd + (["--next", cursor] if cursor else [])
        p = subprocess.run(run, capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
        cursor = None
        for line in p.stdout.splitlines():
            try:
                j = json.loads(line)
            except ValueError:
                continue
            if j.get("type") == "request":
                records.append(j["data"])
            elif j.get("type") == "summary":
                cursor = (j.get("pagination") or {}).get("next")
            elif j.get("status") == "error":
                raise RuntimeError(j.get("message") or j.get("reason"))
        if p.returncode != 0 and not records:
            raise RuntimeError((p.stderr.strip().splitlines() or ["vercel logs failed"])[-1][:200])
        if not cursor:
            break
    return records


def kind(ua):
    ua = ua or ""
    if not ua or SCRIPTED.match(ua) or BOTS.search(ua):
        return "scripted"
    return "airc" if ua.startswith("Airc") else "browser"


def vercel_today():
    """Counts per UTC day from the last 24 hours of CDN request logs."""
    days = collections.defaultdict(lambda: collections.Counter())
    versions = collections.defaultdict(collections.Counter)

    dmg_seen = {}
    for r in sorted(vercel_requests("requestPath:/releases/*"), key=lambda r: r["timestamp"]):
        day, path, ua = r["timestamp"][:10], r["requestPath"], r.get("clientUserAgent", "")
        # 200 and 206 come from the proxy (since relproxy); 307/308 sent the client on to Blob before it.
        if r.get("requestMethod") != "GET" or r.get("httpStatus") not in (200, 206, 307, 308):
            continue
        k = kind(ua)
        if path.endswith(".dmg"):
            if k == "scripted":
                days[day]["dmg_scripted"] += 1
                continue
            if r["httpStatus"] == 206:  # resumed or chunked: one per client and file within 10 minutes
                client = (ua, r.get("clientIpCountry", ""), path)
                t = dt.datetime.fromisoformat(r["timestamp"].replace("Z", "+00:00"))
                last = dmg_seen.get(client)
                dmg_seen[client] = t
                if last and (t - last).total_seconds() < 600:
                    continue
            days[day]["dmg"] += 1
        elif re.search(r"\.(zip|delta)$", path):
            days[day]["update_downloads" if k == "airc" else "update_downloads_other"] += 1

    for r in vercel_requests("requestPath:/download"):
        if r.get("requestMethod") == "GET":
            days[r["timestamp"][:10]]["via_download" if kind(r.get("clientUserAgent")) != "scripted" else "via_download_scripted"] += 1

    for r in vercel_requests("requestPath:/appcast.xml"):
        if r.get("requestMethod") != "GET" or r.get("httpStatus") not in (200, 304):
            continue
        ua, day = r.get("clientUserAgent", ""), r["timestamp"][:10]
        if kind(ua) == "airc":
            days[day]["update_checks"] += 1
            m = re.match(r"Airc/([\d.]+)", ua)
            versions[day][m.group(1) if m else "?"] += 1
        else:
            days[day]["update_checks_other"] += 1
    return {d: dict(c, by_version=dict(versions[d])) for d, c in days.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--record", metavar="FILE", help="append today's Vercel counts as a JSON line")
    a = ap.parse_args()

    ph, ph_err = posthog(a.days)
    try:
        vc, vc_err = vercel_today(), None
    except Exception as e:  # noqa: BLE001 (report and carry on with PostHog)
        vc, vc_err = {}, f"Vercel logs: {e}"

    today = dt.datetime.now(dt.timezone.utc).date()
    span = [str(today - dt.timedelta(days=i)) for i in reversed(range(a.days))]
    out = {d: {**(ph or {}).get(d, {}), **({"vercel": vc[d]} if d in vc else {})} for d in span}

    if a.record and vc:
        with open(a.record, "a") as f:
            f.write(json.dumps({"recorded": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), "vercel": vc}) + "\n")

    if a.json:
        print(json.dumps({"days": out, "errors": [e for e in (ph_err, vc_err) if e]}, indent=2))
        return
    print("UTC day     downloads  new installs  active installs | last 24 h (Vercel): DMG  via /download  update checks  updates")
    for d in span:
        r, v = out[d], out[d].get("vercel", {})
        vpart = f"{v.get('dmg', 0):>4}  {v.get('via_download', 0):>12}  {v.get('update_checks', 0):>13}  {v.get('update_downloads', 0):>7}" if v else ""
        print(f"{d}  {r.get('downloads', '-'):>9}  {r.get('new_installs', '-'):>12}  {r.get('active_installs', '-'):>15} | {vpart}")
    scripted = sum(v.get(k, 0) for v in vc.values() for k in ("dmg_scripted", "via_download_scripted", "update_checks_other", "update_downloads_other"))
    if vc:
        print(f"\nScripted or non-Airc requests in the last 24 h, not counted above: {scripted}")
        for d, v in sorted(vc.items()):
            if v.get("by_version"):
                print(f"Update checks {d} by version: " + ", ".join(f"{k} {n}" for k, n in sorted(v["by_version"].items())))
    for e in (ph_err, vc_err):
        if e:
            print(f"note: {e}", file=sys.stderr)
    print("\nDownloads count GETs of /download (PostHog, anonymous). New and active installs count only copies with usage "
          "data on. Update checks are Sparkle feed fetches, several per install per day, so they are a proxy, not people.")


if __name__ == "__main__":
    main()
