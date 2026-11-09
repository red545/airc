# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Still images for X: a real window from assets/screenshots on the brand's paper, with a short headline.

Each image is an HTML page rendered by headless Chrome at the post's size (1600 × 900 or 1200 × 1200). The window is the
shot's own pixels, scaled once with Lanczos and placed so its `focus` (window points, from the top left) fills the
image's picture area; the rest of the window runs off the edge. Nothing in the window is drawn here.
"""
import html
from pathlib import Path

from PIL import Image

import studio

SIZES = {"16x9": (1600, 900), "1x1": (1200, 1200)}

# Where the focus goes (x, y, w, h in px) and the text column, per size.
LAYOUT = {
    "16x9": {"target": (700, 96, 820, 708), "area": (676, 0, 1600, 900), "text": (96, 108, 540), "title": 50, "brand": "bottom"},
    "1x1": {"target": (88, 468, 1024, 644), "area": (0, 444, 1200, 1200), "text": (88, 150, 1024), "title": 54, "brand": "top"},
}

BACKGROUNDS = {
    # The homepage hero's glows, quieter: mint top left, lilac top right, apricot and sky below.
    "release": ("radial-gradient(60% 75% at -8% -12%, rgb(95 227 180 / .30), transparent 70%),"
                "radial-gradient(55% 70% at 108% -8%, rgb(199 155 255 / .30), transparent 70%),"
                "radial-gradient(60% 70% at 105% 110%, rgb(255 201 153 / .34), transparent 70%),"
                "radial-gradient(50% 60% at 18% 112%, rgb(127 176 255 / .24), transparent 70%), #FCFBFA"),
    # Coming soon: the cool half of the ring only (sky and lilac), so a teaser never looks like a release card.
    "soon": ("radial-gradient(60% 75% at -8% -12%, rgb(127 176 255 / .26), transparent 70%),"
             "radial-gradient(55% 70% at 108% -8%, rgb(199 155 255 / .32), transparent 70%),"
             "radial-gradient(60% 70% at 105% 110%, rgb(196 224 255 / .40), transparent 70%),"
             "radial-gradient(50% 60% at 18% 112%, rgb(226 208 255 / .34), transparent 70%), #FBFBFD"),
}

CSS = """
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:%(w)dpx;height:%(h)dpx;overflow:hidden}
body{position:relative;background:%(bg)s;font-family:Figtree,Inter,system-ui,sans-serif;color:rgb(20 17 15 / .92);
  -webkit-font-smoothing:antialiased;font-feature-settings:"ss01"}
.win{position:absolute;overflow:hidden;border-radius:%(r)fpx;background:#fff;
  box-shadow:0 0 0 1px rgb(20 17 15 / .07),0 2px 6px rgb(40 30 20 / .06),0 28px 56px -18px rgb(40 30 20 / .26),0 56px 112px -36px rgb(40 30 20 / .22)}
.win img{display:block;width:100%%;height:100%%}
.text{position:absolute;left:%(tx)dpx;top:%(ty)dpx;width:%(tw)dpx}
.tag{display:inline-flex;align-items:center;gap:8px;height:34px;padding:0 14px;border-radius:17px;font:600 18px/1 Inter,sans-serif;
  letter-spacing:-.005em;margin-bottom:22px}
.tag.new{background:rgb(49 57 251 / .09);color:#2b33e0}
.tag.soon{background:rgb(120 72 220 / .10);color:#6232c8}
.tag.soon::before{content:"";width:8px;height:8px;border-radius:4px;background:#8b5cf6}
h1{font-weight:620;font-size:%(title)dpx;line-height:1.08;letter-spacing:-.025em;text-wrap:balance}
h1 .grey{color:rgb(20 17 15 / .42)}
h1.hero{font-size:%(hero)dpx;line-height:1;letter-spacing:-.035em}
p.line{margin-top:18px;font:500 %(line)dpx/1.3 Figtree,sans-serif;color:rgb(20 17 15 / .5);letter-spacing:-.015em;text-wrap:pretty}
.keys{display:flex;gap:10px;margin-top:30px}
kbd{display:inline-grid;place-items:center;min-width:58px;height:58px;padding:0 14px;border-radius:13px;background:#fff;
  font:600 26px/1 Inter,sans-serif;color:rgb(20 17 15 / .78);
  box-shadow:inset 0 0 0 1px rgb(20 17 15 / .10),0 1.5px 0 rgb(20 17 15 / .10),0 6px 14px -6px rgb(40 30 20 / .18)}
kbd .glyph{width:26px;height:26px}
.iglyph{width:.8em;height:.8em;vertical-align:-.06em;display:inline-block}
.brand{position:absolute;display:flex;align-items:center;gap:14px;font:500 19px/1 Inter,sans-serif;color:rgb(20 17 15 / .5)}
.brand img{height:36px;width:auto}
.note{position:absolute;font:500 17px/1.3 Inter,sans-serif;color:rgb(20 17 15 / .5)}
"""


def lockup():
    """The brand kit's lockup (icon and name) if present, else the icon alone with the name set in Figtree."""
    kit = studio.BRAND / "kit/airc-lockup.svg"
    if kit.exists():
        return f'<img src="{kit.as_uri()}" alt="">'
    icon = studio.BRAND / "airc-holographic.svg"
    return f'<img src="{icon.as_uri()}" alt=""><b style="font:650 30px Figtree;color:#14110F">Airc</b>'


def place(win_pts, focus, target, align="center"):
    """Scale (px per pt) and top-left (px) for a window so `focus` (pt) fits `target` (px)."""
    fx, fy, fw, fh = focus
    tx, ty, tw, th = target
    s = min(tw / fw, th / fh)
    ax = 0 if "left" in align else 1 if "right" in align else 0.5
    ay = 0 if "top" in align else 1 if "bottom" in align else 0.5
    return s, tx + (tw - fw * s) * ax - fx * s, ty + (th - fh * s) * ay - fy * s


def picture(spec, size, layout, work, pack):
    """The window (or the whole shot, `mode = "plate"`) scaled for this image: (html, upscale factor)."""
    rev = spec.get("shots_rev") or pack.get("shots_rev")
    if spec.get("mode", "window") == "plate":
        img, k, src = studio.shot(spec["shot"], rev)
        k = k or 1
        pts = (img.width / k, img.height / k)
        radius_pt = 10
    else:
        img, k, pts, src = studio.window(spec["shot"], rev)
        radius_pt = studio.WINDOW_RADIUS * 1.3   # a little rounder than the window, so no desktop shows at the corners
    # `clip` (pt): only that part of the window is shown, as its own rounded card (to leave out what isn't ours to show).
    clip = spec.get("clip")
    if clip:
        cx, cy, cw, ch = clip
        img = img.crop((round(cx * k), round(cy * k), round((cx + cw) * k), round((cy + ch) * k)))
        focus = spec.get(f"focus_{size}") or spec.get("focus") or [cx, cy, cw, ch]
        focus = [focus[0] - cx, focus[1] - cy, focus[2], focus[3]]
        pts = (cw, ch)
    else:
        focus = spec.get(f"focus_{size}") or spec.get("focus") or [0, 0, pts[0], pts[1]]
    target = spec.get(f"target_{size}") or layout["target"]
    s, x, y = place(pts, focus, target, spec.get("align", "center"))
    w, h = round(pts[0] * s), round(pts[1] * s)
    scaled = img.resize((w, h), Image.LANCZOS)
    # Never over the text: what falls outside the picture area is cut off, and the cut edge gets the same rounding.
    ax0, ay0, ax1, ay1 = spec.get(f"area_{size}") or layout["area"]
    vx0, vy0 = max(x, ax0), max(y, ay0)
    vx1, vy1 = min(x + w, ax1 + 400), min(y + h, ay1 + 400)   # past the far edges the page itself crops it
    if (vx0, vy0) != (x, y):
        scaled = scaled.crop((round(vx0 - x), round(vy0 - y), round(vx1 - x), round(vy1 - y)))
        x, y, w, h = vx0, vy0, scaled.width, scaled.height
    out = work / f"{spec['id']}-{size}-window.png"
    scaled.save(out)
    upscale = s / k
    return (f'<div class="win" style="left:{x:.1f}px;top:{y:.1f}px;width:{w}px;height:{h}px;'
            f'border-radius:{radius_pt * s:.1f}px"><img src="{out.as_uri()}" alt=""></div>'), upscale, src


def page(spec, size, pack, work):
    w, h = SIZES[size]
    layout = LAYOUT[size]
    kind = pack.get("kind", "release")
    pic, upscale, src = picture(spec, size, layout, work, pack)
    tx, ty, tw = layout["text"]
    if spec.get(f"text_{size}"):
        tx, ty, tw = spec[f"text_{size}"]
    css = studio.font_faces() + CSS % {
        "w": w, "h": h, "bg": BACKGROUNDS["soon" if kind == "teaser" else "release"], "r": 20, "tx": tx, "ty": ty, "tw": tw,
        "title": spec.get(f"title_px_{size}", layout["title"]), "hero": 104 if size == "16x9" else 112, "line": 30 if size == "16x9" else 32,
    }
    tag = spec.get("tag") or pack.get("tag", "")
    tag_html = f'<div class="tag {"soon" if kind == "teaser" else "new"}">{html.escape(tag)}</div>' if tag else ""
    if spec.get("hero"):
        title = f'<h1 class="hero">{studio.inline_keys(spec["title"])}</h1>'
        title += f'<p class="line">{studio.inline_keys(spec.get("line", ""))}</p>' if spec.get("line") else ""
    else:
        title = (f'<h1><span>{studio.inline_keys(spec["title"])}</span> '
                 f'<span class="grey">{studio.inline_keys(spec.get("line", ""))}</span></h1>')
    keys = f'<div class="keys">{studio.keycaps(spec["keys"])}</div>' if spec.get("keys") else ""
    if layout["brand"] == "bottom":
        brand = f'<div class="brand" style="left:{tx}px;bottom:84px">{lockup()}</div>'
    else:
        brand = f'<div class="brand" style="left:{tx}px;top:76px">{lockup()}</div>'
    note = ""
    # A teaser's line on every card ("Not in …"), or one card's own (a caveat from the release notes).
    note_text = spec.get("note") or (pack.get("note", "") if kind == "teaser" else "")
    if note_text:
        pos = f"left:{tx}px;bottom:44px" if size == "16x9" else f"right:88px;top:84px;text-align:right"
        note = f'<div class="note" style="{pos}">{html.escape(note_text)}</div>'
    body = f'{pic}<div class="text">{tag_html}{title}{keys}</div>{brand}{note}'
    return f'<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>', upscale, src


def build(pack, out_dir):
    """Renders every image of the pack in its sizes. Returns one record per file."""
    work = studio.CACHE / pack["slug"]
    work.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for n, spec in enumerate(pack.get("image", []), 1):
        for size in spec.get("sizes", ["16x9", "1x1"]):
            w, h = SIZES[size]
            doc, upscale, src = page(spec, size, pack, work)
            name = f"{n:02d}-{spec['id']}-{w}x{h}"
            png = studio.render(doc, out_dir / f"{name}.png", w, h)
            final = png
            if png.stat().st_size > 4_800_000:   # X takes images under 5 MB
                final = out_dir / f"{name}.jpg"
                Image.open(png).convert("RGB").save(final, quality=92, optimize=True, progressive=True)
                png.unlink()
            records.append({"id": spec["id"], "size": size, "file": final.name, "width": w, "height": h,
                            "bytes": final.stat().st_size, "alt": spec["alt"], "title": spec["title"],
                            "line": spec.get("line", ""), "shot": spec["shot"], "source": src, "upscale": round(upscale, 3)})
            note = f"  {final.name}  {final.stat().st_size / 1e6:.2f} MB"
            if upscale > 1.05:
                note += f"  (window upscaled {upscale:.2f}×)"
            print(note)
    return records
