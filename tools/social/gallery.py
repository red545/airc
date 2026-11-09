# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""ARTIFACTS/index.html: every pack (images, videos, posts with their lengths, alt text, the posting order and the
check), newest first, for the owner to review on a phone. Static: any file server shows it."""
import html
import json
import re
from pathlib import Path
from datetime import datetime, timezone

import social
import studio

CSS = """
:root{color-scheme:light;--ink:20 17 15}
*{box-sizing:border-box;margin:0}
body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif;background:#f7f6f4;color:rgb(var(--ink)/.9);
  -webkit-font-smoothing:antialiased;letter-spacing:-.01em}
header{padding:28px 20px 8px;max-width:1180px;margin:0 auto}
h1{font:650 26px/1.2 -apple-system,"SF Pro Display",Figtree,sans-serif;letter-spacing:-.02em}
h2{font:650 22px/1.25 -apple-system,"SF Pro Display",sans-serif;letter-spacing:-.02em;margin:0 0 4px}
h3{font:600 15px/1.3 -apple-system,sans-serif;margin:26px 0 10px;color:rgb(var(--ink)/.55);text-transform:uppercase;letter-spacing:.04em}
.lede{color:rgb(var(--ink)/.6);margin-top:6px;max-width:760px}
nav{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}
nav a{font-size:14px;padding:6px 12px;border-radius:999px;background:#fff;box-shadow:0 0 0 1px rgb(var(--ink)/.08);color:inherit;text-decoration:none}
section.pack{overflow:hidden;max-width:1180px;margin:18px auto 40px;padding:22px 20px;background:#fcfbfa;border-radius:18px;box-shadow:0 0 0 1px rgb(var(--ink)/.07)}
.meta{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:4px 0 10px;font-size:14px;color:rgb(var(--ink)/.55)}
.badge{font:600 13px/1 -apple-system,sans-serif;padding:6px 10px;border-radius:999px}
.badge.release{background:rgb(49 57 251/.09);color:#2b33e0}.badge.teaser{background:rgb(120 72 220/.11);color:#6232c8}
.badge.ok{background:rgb(47 158 98/.12);color:#1f7a49}.badge.bad{background:rgb(229 72 77/.12);color:#b4262c}
.prose{color:rgb(var(--ink)/.72);font-size:15px;max-width:760px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
figure{background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 0 0 1px rgb(var(--ink)/.07)}
figure img,figure video{display:block;width:100%;height:auto;background:#eee}
figcaption{padding:10px 12px 12px;font-size:13px;color:rgb(var(--ink)/.6)}
figcaption b{color:rgb(var(--ink)/.85);font-weight:600}
figcaption a{color:#2b33e0}
.alt{margin-top:6px;font-size:12.5px;line-height:1.45}
.posts{display:grid;grid-template-columns:minmax(0,1fr);gap:14px}
.post{min-width:0;background:#fff;border-radius:14px;padding:14px 16px;box-shadow:0 0 0 1px rgb(var(--ink)/.07)}
.post .label{font-size:13px;font-weight:600;color:rgb(var(--ink)/.5);margin-bottom:6px}
.post .text{white-space:pre-wrap;font-size:16px;line-height:1.45}
.post .count{font-size:12.5px;color:rgb(var(--ink)/.5);margin-top:8px}
.post .count.over{color:#b4262c;font-weight:600}
.post .media{display:flex;gap:8px;margin-top:10px;overflow-x:auto}
.post .media img{height:84px;width:auto;border-radius:8px;box-shadow:0 0 0 1px rgb(var(--ink)/.08)}
.problems{font-size:14px;color:#b4262c}
footer{max-width:1180px;margin:0 auto;padding:10px 20px 40px;font-size:13px;color:rgb(var(--ink)/.5)}
"""


def esc(s):
    return html.escape(str(s))


def para(text):
    """Hard-wrapped TOML prose as HTML: wrapped lines joined, list items ("1.", "-") on lines of their own."""
    lines = []
    for line in text.strip().splitlines():
        if lines and line.strip() and not re.match(r"\s*(\d+\.|-)\s", line):
            lines[-1] += " " + line.strip()
        else:
            lines.append(line.strip())
    return "<br>".join(esc(l) for l in lines)


def thumb(slug, name, width=640):
    """A small JPEG of an image or poster for the page (the full file is a tap away): `slug/_thumbs/<name>.jpg`, made
    again when the file is newer. A page of full-size PNGs and inline GIFs weighed over 100 MB on a phone."""
    from PIL import Image
    src = studio.ARTIFACTS / slug / name
    out = studio.ARTIFACTS / slug / "_thumbs" / (Path(name).stem + ".jpg")
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        out.parent.mkdir(exist_ok=True)
        with Image.open(src) as im:
            im = im.convert("RGB")
            if im.width > width:
                im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
            im.save(out, quality=80, optimize=True, progressive=True)
    return f"{slug}/_thumbs/{out.name}"


def pack_html(data, check):
    slug = data["slug"]
    kind = data.get("kind", "release")
    parts = [f'<section class="pack" id="{esc(slug)}"><h2>{esc(data["title"])}</h2><div class="meta">']
    parts.append(f'<span class="badge {kind}">{"Release" if kind == "release" else "Coming soon (not released)"}</span>')
    if check:
        ok = check.get("ok")
        parts.append(f'<span class="badge {"ok" if ok else "bad"}">{"Checks passed" if ok else "Check problems"}'
                     f' · OCR read {check.get("ocr_scanned", 0)} files</span>')
    parts.append(f'<a href="{esc(slug)}/copy.md">copy.md</a></div>')
    if data.get("summary"):
        parts.append(f'<p class="prose">{para(data["summary"])}</p>')
    if check and check.get("problems"):
        parts.append('<div class="problems">' + "<br>".join(esc(p) for p in check["problems"]) + "</div>")
    by_file = {r["file"]: r for r in data.get("images", [])}
    posts = data.get("post", [])
    if posts:
        parts.append("<h3>Posts</h3>")
        if data.get("order"):
            parts.append(f'<p class="prose"><b>Posting order.</b><br>{para(data["order"])}</p><br>')
        parts.append('<div class="posts">')
        for i, p in enumerate(posts, 1):
            n = social.x_length(p["text"].strip())
            media = social.media_files(p.get("media", []), data.get("images", []), data.get("videos", []))
            thumbs = []
            for m in media:
                if m in by_file:
                    thumbs.append(f'<a href="{esc(slug)}/{esc(m)}"><img src="{esc(thumb(slug, m, 320))}" alt="" loading="lazy"></a>')
                else:
                    v = next((v for v in data.get("videos", []) if v["file"] == m), None)
                    if v and v.get("poster"):
                        thumbs.append(f'<a href="{esc(slug)}/{esc(m)}"><img src="{esc(thumb(slug, v["poster"], 320))}" alt="" loading="lazy"></a>')
            parts.append(f'<div class="post"><div class="label">{i}. {esc(p.get("label", ""))}</div>'
                         f'<div class="text">{esc(p["text"].strip())}</div>'
                         f'<div class="count{" over" if n > 280 else ""}">{n} / 280 · {esc(", ".join(media))}</div>'
                         f'<div class="media">{"".join(thumbs)}</div></div>')
        parts.append("</div>")
    if data.get("videos"):
        parts.append("<h3>Videos</h3><div class=\"grid\">")
        for v in data["videos"]:
            src = f"{esc(slug)}/{esc(v['file'])}"
            poster = esc(thumb(slug, v["poster"])) if v.get("poster") else ""
            # A GIF isn't played on the page (several MB each): its poster, and the file a tap away.
            media = (f'<a href="{src}"><img src="{poster}" alt="" loading="lazy"></a>' if v["kind"] == "gif" else
                     f'<video src="{src}" poster="{poster}" controls muted loop playsinline preload="none"></video>')
            parts.append(f'<figure>{media}<figcaption><b>{esc(v["file"])}</b> · {v["width"]}×{v["height"]} · {v["seconds"]:.1f} s · '
                         f'{v["bytes"] / 1e6:.1f} MB · <a href="{src}" download>download</a>'
                         f'<div class="alt">Alt: {esc(v["alt"])}</div></figcaption></figure>')
        parts.append("</div>")
    if data.get("images"):
        parts.append("<h3>Images</h3><div class=\"grid\">")
        for r in data["images"]:
            src = f"{esc(slug)}/{esc(r['file'])}"
            parts.append(f'<figure><a href="{src}"><img src="{esc(thumb(slug, r["file"]))}" alt="{esc(r["alt"])}" loading="lazy"></a>'
                         f'<figcaption><b>{esc(r["file"])}</b> · {r["bytes"] / 1e6:.2f} MB · <a href="{src}" download>download</a>'
                         f'<div class="alt">Alt: {esc(r["alt"])}</div></figcaption></figure>')
        parts.append("</div>")
    if data.get("requests"):
        parts.append(f'<h3>Requests for the owner</h3><p class="prose">{para(data["requests"])}</p>')
    parts.append("</section>")
    return "".join(parts)


def brand_html():
    """ARTIFACTS/brand-x (brandx.py): the profile's own pictures, each with a download link."""
    m = studio.ARTIFACTS / "brand-x" / "manifest.json"
    if not m.exists():
        return ""
    files = json.loads(m.read_text())["files"]
    parts = ['<section class="pack" id="brand-x"><h2>For the X profile</h2>'
             '<p class="prose">Upload a profile picture as it is: X shows it in a circle, and the icon sits inside it. '
             'Headers are 1500 × 500; X puts your profile picture over their bottom left, which they keep clear. '
             'Long-press (or right-click) an image and save it, or tap download.</p><div class="grid">']
    for f in files:
        src = f"brand-x/{esc(f['file'])}"
        parts.append(f'<figure><a href="{src}"><img src="{esc(thumb("brand-x", f["file"]))}" alt="" loading="lazy"></a>'
                     f'<figcaption><b>{esc(f["kind"])}</b> · {esc(f["size"])} · {f["bytes"] / 1e6:.2f} MB · '
                     f'<a href="{src}" download>download</a><div class="alt">{esc(f["about"])}</div></figcaption></figure>')
    parts.append("</div>")
    bios = json.loads(m.read_text()).get("bio", [])
    if bios:
        parts.append('<h3>Bio</h3><div class="posts">')
        for b in bios:
            parts.append(f'<div class="post"><div class="label">{esc(b["label"])}</div><div class="text">{esc(b["text"])}</div>'
                         f'<div class="count">{b["chars"]} / 160 characters · website: aircbrowser.com</div></div>')
        parts.append("</div>")
    parts.append("</section>")
    return "".join(parts)


def queue_html():
    """The posting queue (tools/social/xpost.py): what goes out when, approved or not, and each live post's link."""
    q = studio.ARTIFACTS / "_queue" / "queue.json"
    if not q.exists():
        return ""
    items = sorted(json.loads(q.read_text())["items"], key=lambda i: i["due"])
    paused = studio.ARTIFACTS / "_queue" / "PAUSED"
    parts = ['<section class="pack" id="queue"><h2>Posting queue</h2><p class="prose">What goes out on X, and when (UTC). '
             'Nothing is posted until the owner has approved it and said to start, and the studio has reviewed it (media '
             'looked at, text checked against the release notes); a reply goes under the post above it, as a thread.</p>']
    if paused.exists():
        parts.append(f'<p class="problems">Paused: {esc(paused.read_text().strip())}</p>')
    if not (studio.ARTIFACTS / "_queue" / "STARTED").exists():
        parts.append('<p class="prose"><b>Not started:</b> nothing posts until the owner says to start.</p>')
    day = None
    for i in items:
        d = i["due"][:10]
        if d != day:
            parts.append(f"<h3>{esc(datetime.fromisoformat(i['due']).strftime('%A %-d %B'))}</h3>")
            day = d
        if i["status"] == "posted":
            state = f'<a class="badge ok" href="{esc(i["posted"]["url"])}">posted</a>'
        elif i["approved"]:
            by = (i.get("approved_by") or {}).get("by", "")
            state = f'<span class="badge release" title="{esc(by)}">approved by the owner</span>'
        else:
            state = '<span class="badge teaser">not approved</span>'
        if i["status"] == "queued":
            import xpost
            state += ' <span class="badge ok">reviewed</span>' if xpost.reviewed(i) else ' <span class="badge">not reviewed</span>'
        if i.get("error"):
            state += f' <span class="problems">{esc(i["error"])}</span>'
        thumbs = ""
        for ref in i["media"]:
            slug, _, ref = ref.rpartition("/")
            slug = slug or i["pack"]
            pack = json.loads((studio.ARTIFACTS / slug / "pack.json").read_text()) if (studio.ARTIFACTS / slug / "pack.json").exists() else {}
            rid, _, size = ref.partition(":")
            size = size or "16x9"
            rec = next((r for r in pack.get("images", []) if r["id"] == rid and r["size"] == size), None)
            rec = rec or next((v for v in pack.get("videos", []) if v["id"] == rid and v.get("kind") == size), None)
            if rec is None:
                thumbs += f'<span class="problems">{esc(rid)}: not built yet</span>'
            else:
                pic = rec.get("poster") or rec["file"]
                thumbs += f'<a href="{esc(slug)}/{esc(rec["file"])}"><img loading="lazy" src="{esc(thumb(slug, pic, 320))}" alt=""></a>'
        parts.append(f'<div class="post"><div class="label">{esc(i["due"][11:16])} · {esc(i["id"])} · '
                     f'{"↳ reply · " if i.get("reply_to") else ""}{esc(i["label"])} {state}</div>'
                     f'<div class="text">{esc(i["text"])}</div><div class="media">{thumbs}</div></div>')
    parts.append("</section>")
    return "".join(parts)


def build():
    packs = []
    for m in sorted(studio.ARTIFACTS.glob("*/pack.json"), reverse=True):
        if m.parent.name.startswith("_"):
            continue
        data = json.loads(m.read_text())
        check_file = m.parent / "check.json"
        packs.append((data, json.loads(check_file.read_text()) if check_file.exists() else None))
    nav = "".join(f'<a href="#{esc(d["slug"])}">{esc(d["title"])}</a>' for d, _ in packs)
    brand = brand_html()
    if brand:
        nav = '<a href="#brand-x">X profile: logo and header</a>' + nav
    queue = queue_html()
    if queue:
        nav = '<a href="#queue">Posting queue</a>' + nav
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    doc = (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
           f'<title>Airc social studio</title><style>{CSS}</style></head><body><header><h1>Airc social studio</h1>'
           f'<p class="lede">Drafts for X: images, short videos and post text for each release and feature. Only what the '
           f'posting queue shows as posted is on X. Every picture is the real app with demo data; the videos are frames Airc '
           f'rendered itself.</p><nav>{nav}</nav></header>'
           + queue + brand + "".join(pack_html(d, c) for d, c in packs)
           + f'<footer>Built {stamp} by tools/social. Tap an image for full size.</footer></body></html>')
    (studio.ARTIFACTS / "index.html").write_text(doc)
    print(f"== gallery: {studio.ARTIFACTS / 'index.html'} ({len(packs)} packs)")
