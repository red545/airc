#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Render the Airc build status page (index.html) from nightly runs and live state of the build Mac.

usage: status.py STATUS_DIR [--live]
  --live  also ask the Mac (over ssh, short timeout) for the Chromium checkout and engine build progress
"""
import html, json, os, re, subprocess, sys, time
from pathlib import Path

status = Path(sys.argv[1])
host = os.environ.get("AIRC_MAC_HOST", "mac")
runs_dir = status / "runs"
runs_dir.mkdir(parents=True, exist_ok=True)


def mac(cmd: str) -> str | None:
    try:
        r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host, cmd],
                           capture_output=True, text=True, timeout=40)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def progress(log: str) -> str:
    """Last ninja '[n/m]' counter or last meaningful line."""
    hits = re.findall(r"\[(\d+)/(\d+)\]", log)
    if hits:
        n, m = map(int, hits[-1])
        return f"{n:,} / {m:,} steps ({100 * n // max(m, 1)}%)"
    lines = [l for l in log.strip().splitlines() if l.strip()]
    return lines[-1][:200] if lines else "no output yet"


live_path = status / "live.json"
if "--live" in sys.argv:
    out = mac("df -h / | tail -1; echo ---; tail -c 3000 ~/arcfork/fetch-chromium.log 2>/dev/null; echo ---; "
              "tail -c 6000 ~/arcfork/airc-engine.log 2>/dev/null; echo ---; screen -ls 2>/dev/null | grep -c airc-engine; "
              "echo ---; du -sh ~/arcfork/chromium 2>/dev/null | cut -f1")
    live = {"checked": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()), "online": out is not None}
    if out is not None:
        parts = out.split("---\n")
        disk, fetch, engine, running, size = (parts + [""] * 5)[:5]
        f = disk.split()
        live["disk_free"] = f[3] if len(f) > 3 else "?"
        if "EXIT 0" in fetch:
            live["checkout"] = f"ready ({size.strip()})"
        elif "EXIT" in fetch:
            live["checkout"] = "failed: " + progress(fetch)
        else:
            live["checkout"] = f"downloading, {size.strip()} so far"
        if engine.strip():
            engine = engine[engine.rfind("START "):] if "START " in engine else engine  # latest run only
            m = re.search(r"EXIT (\d+)\s*$", engine)
            state = ("done" if m.group(1) == "0" else f"failed (exit {m.group(1)})") if m else (
                "running" if running.strip() not in ("", "0") else "stopped")
            live["engine"] = f"{state}: {progress(engine)}"
        else:
            live["engine"] = "not started"
    live_path.write_text(json.dumps(live))
live = json.loads(live_path.read_text()) if live_path.exists() else {}

runs = []
for d in sorted(runs_dir.iterdir(), reverse=True)[:30]:
    steps = []
    if (d / "steps.tsv").exists():
        for line in (d / "steps.tsv").read_text().splitlines():
            name, rc, secs = line.split("\t")
            steps.append((name, int(rc), int(secs)))
    shots = sorted((d / "snapshots").glob("*.png")) if (d / "snapshots").exists() else []
    rev = (d / "rev.txt").read_text().strip() if (d / "rev.txt").exists() else "?"
    subj = (d / "subject.txt").read_text().strip() if (d / "subject.txt").exists() else ""
    runs.append((d.name, rev, subj, steps, shots))

e = html.escape
def badge(rc):
    return '<span class="ok">passed</span>' if rc == 0 else (
        '<span class="skip">skipped</span>' if rc == 3 else f'<span class="bad">failed ({rc})</span>')
def dur(s):
    return f"{s // 3600}h {s % 3600 // 60}m" if s >= 3600 else (f"{s // 60}m {s % 60}s" if s >= 60 else f"{s}s")

rows = []
for i, (name, rev, subj, steps, shots) in enumerate(runs):
    ok = all(rc in (0, 3) for _, rc, _ in steps) and steps
    head = f'<summary><b>{e(name.replace("_", " "))} UTC</b> · <code>{e(rev)}</code> {e(subj)} · {"✅" if ok else "❌"}</summary>'
    body = "".join(f'<tr><td>{e(n)}</td><td>{badge(rc)}</td><td>{dur(s)}</td>'
                   f'<td><a href="runs/{e(name)}/{e(n)}.log">log</a></td></tr>' for n, rc, s in steps)
    gallery = "".join(f'<a href="runs/{e(name)}/snapshots/{e(p.name)}"><img src="runs/{e(name)}/snapshots/{e(p.name)}" loading="lazy"></a>' for p in shots)
    rows.append(f'<details{" open" if i == 0 else ""}>{head}<table>{body}</table><div class="shots">{gallery}</div></details>')

livehtml = "<p>No live data yet.</p>"
if live:
    if live.get("online"):
        livehtml = (f'<table><tr><td>Mac</td><td><span class="ok">online</span>, {e(live.get("disk_free", "?"))} free</td></tr>'
                    f'<tr><td>Chromium checkout</td><td>{e(live.get("checkout", "?"))}</td></tr>'
                    f'<tr><td>Engine build</td><td>{e(live.get("engine", "?"))}</td></tr></table>')
    else:
        livehtml = '<p><span class="bad">Mac offline or asleep</span> (needs the charger and an open lid for night builds).</p>'
    livehtml += f'<p class="dim">Checked {e(live.get("checked", ""))}</p>'

# Optional perf artifacts must not prevent the build status page from rendering.
try:
    from perf.status_section import render as render_perf
    perfhtml = render_perf(runs_dir)
except Exception as error:
    perfhtml = "<p>Performance results unavailable: " + e(str(error)) + "</p>"

def chromium_section():
    try:
        from chromium.status_section import render
        return render()
    except Exception:
        return "<p>Chromium release state unavailable.</p>"


# Optional public project link; deployments must opt in explicitly.
project_url = os.environ.get("AIRC_PROJECT_URL", "")
project_link = (f' · <a href="{e(project_url)}">Project</a>'
                if project_url.startswith("https://") else "")

page = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="120"><title>Airc builds</title><style>
:root{{color-scheme:light dark;--fg:#1d1d1f;--dim:#86868b;--card:#fff;--bg:#f5f5f7;--line:#e5e5ea}}
@media(prefers-color-scheme:dark){{:root{{--fg:#f5f5f7;--dim:#98989d;--card:#1c1c1e;--bg:#000;--line:#2c2c2e}}}}
body{{font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:24px;max-width:960px;margin:auto}}
h1{{font-size:28px;letter-spacing:-.02em;margin:8px 0 2px}}h2{{font-size:17px;margin:28px 0 8px}}
.dim{{color:var(--dim);font-size:13px}}section,details{{background:var(--card);border-radius:14px;padding:14px 18px;margin:10px 0;box-shadow:0 1px 2px #0001}}
summary{{cursor:pointer}}table{{border-collapse:collapse;width:100%;margin-top:8px}}td{{padding:6px 8px;border-top:1px solid var(--line)}}
.ok{{color:#30a46c;font-weight:600}}.bad{{color:#e5484d;font-weight:600}}.skip{{color:var(--dim)}}
.shots{{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px;margin-top:10px}}.shots img{{width:100%;border-radius:10px}}
code{{font:13px ui-monospace,SFMono-Regular,monospace}}a{{color:#0a84ff}}</style></head><body>
<h1>Airc builds</h1><p class="dim">Built and maintained by AI · <a href="work.html">What the agents are doing</a>{project_link}</p>
<h2>Right now</h2><section>{livehtml}</section>
<h2>Chromium</h2><section>{chromium_section()}</section>
<h2>Speed and memory</h2><section>{perfhtml}</section>
<h2>Runs</h2>{"".join(rows) or "<p class=dim>No runs yet.</p>"}
</body></html>"""
(status / "index.html").write_text(page)
print(status / "index.html")
