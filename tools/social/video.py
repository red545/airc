# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Short videos from frames the app rendered itself (SocialFrames.swift, via tools/social/mac-frames.sh).

Each frame is the window as Airc drew it, offscreen, at 2×; nothing is recorded from a screen. Here it is placed on the
brand's paper under a caption (an HTML plate rendered by headless Chrome), given the window's corners, shadow and
traffic lights (as MarketingStudio.swift gives the stills), held for as long as the frame list says, and encoded as an
H.264 MP4 at 60 fps and a GIF. Captions change with the frames' labels, so each video reads without sound.
"""
import html
import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import cards
import studio

FPS = 60
KINDS = {
    # Caption column on the left and the window at half its 2× pixels, running off the right edge (as the cards do);
    # in the square, the caption on top.
    "16x9": {"size": (1920, 1080), "scale": 1.0, "window_at": (760, 90), "caption": (100, 250, 600), "title": 86, "line": 50},
    "1x1": {"size": (1080, 1080), "scale": 0.78, "window_at": (72, 352), "caption": (72, 66, 936), "title": 62, "line": 38},
}
LIGHTS = [((255, 95, 87), (224, 68, 62)), ((254, 188, 46), (222, 161, 35)), ((40, 200, 64), (26, 171, 41))]

PLATE_CSS = """
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:%(w)dpx;height:%(h)dpx;overflow:hidden}
body{position:relative;background:%(bg)s;font-family:Figtree,Inter,sans-serif;color:rgb(20 17 15 / .92);-webkit-font-smoothing:antialiased}
.cap{position:absolute;left:%(cx)dpx;top:%(cy)dpx;width:%(cw)dpx}
.tag{display:inline-flex;align-items:center;gap:10px;height:46px;padding:0 20px;border-radius:23px;font:600 25px/1 Inter,sans-serif;
  background:rgb(49 57 251 / .09);color:#2b33e0;margin-bottom:26px}
.tag.soon{background:rgb(120 72 220 / .10);color:#6232c8}
.tag.soon::before{content:"";width:10px;height:10px;border-radius:5px;background:#8b5cf6}
h1{font-weight:620;font-size:%(title)dpx;line-height:1.06;letter-spacing:-.028em;text-wrap:balance}
p{margin-top:18px;font:500 %(line)dpx/1.22 Figtree,sans-serif;color:rgb(20 17 15 / .5);letter-spacing:-.015em;text-wrap:pretty}
.iglyph{width:.8em;height:.8em;vertical-align:-.06em;display:inline-block}
.steps{list-style:none;margin-top:34px;display:flex;gap:%(stepgap)s;flex-direction:%(stepdir)s;font:600 %(step)dpx/1.15 Figtree,sans-serif;
  color:rgb(20 17 15 / .28);letter-spacing:-.015em}
.steps li.on{color:rgb(20 17 15 / .92)}
.shadow{position:absolute;border-radius:%(r)fpx;background:#fff;
  box-shadow:0 0 0 1px rgb(20 17 15 / .07),0 2px 6px rgb(40 30 20 / .06),0 28px 56px -18px rgb(40 30 20 / .26),0 56px 112px -36px rgb(40 30 20 / .22)}
.end{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:34px}
.end img{height:150px}
.end h1{font-size:%(endtitle)dpx}
.end p{margin-top:0;font-size:%(endline)dpx}
"""


def plate(kind, box, radius, tag, title, line, end=False, steps=None, current="", soon=False, note="", accent=False, lockup=True):
    w, h = KINDS[kind]["size"]
    k = KINDS[kind]
    cx, cy, cw = k["caption"]
    wide = kind == "16x9"
    css = studio.font_faces() + PLATE_CSS % {"w": w, "h": h, "bg": cards.BACKGROUNDS["soon" if soon else "release"], "cx": cx, "cy": cy, "cw": cw,
                                             "title": k["title"], "line": k["line"], "r": radius,
                                             "step": 50 if wide else 32, "stepdir": "column" if wide else "row",
                                             "stepgap": "12px" if wide else "28px", "endline": 46 if wide else 36, "endtitle": 104 if wide else 84}
    if end:
        # A card: the lockup, a title (in the homepage's red for a hook), a line and a quieter note.
        mark = cards.lockup().replace("<b ", "<b style=font-size:80px ") if lockup else ""
        style = ' style="color:#e5484d"' if accent else ""
        body = (f'<div class="end">{mark}<h1{style}>{studio.inline_keys(title)}</h1>'
                + (f'<p>{studio.inline_keys(line)}</p>' if line else "")
                + (f'<p style="font-size:.75em;opacity:.8">{studio.inline_keys(note)}</p>' if note else "") + '</div>')
    else:
        x, y, bw, bh = box
        tag_html = f'<div class="tag{" soon" if soon else ""}">{html.escape(tag)}</div><br>' if tag else ""
        steps_html = ""
        if steps:
            items = "".join(f'<li class="{"on" if current and current in st else ""}">{html.escape(st)}</li>' for st in steps)
            steps_html = f'<ul class="steps">{items}</ul>'
        line_html = f"<p>{studio.inline_keys(line)}</p>" if line else ""
        body = (f'<div class="shadow" style="left:{x}px;top:{y}px;width:{bw}px;height:{bh}px"></div>'
                f'<div class="cap">{tag_html}<h1>{studio.inline_keys(title)}</h1>{line_html}{steps_html}</div>')
    return f'<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'


def window_box(kind, win_w, win_h, scale=None):
    """The window's place on the canvas (it may run off the right edge) and its scale in px per pt."""
    k = KINDS[kind]
    s = scale or k["scale"]
    x, y = k["window_at"]
    return (x, y, round(win_w * s), round(win_h * s)), s


def rounded_mask(size, radius):
    m = Image.new("L", (size[0] * 4, size[1] * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, m.width - 1, m.height - 1), radius=radius * 4, fill=255)
    return m.resize(size, Image.LANCZOS)


def frame_rgb(path):
    """A frame on white where it's transparent (a window's rounded corners), not on black."""
    im = Image.open(path)
    if im.mode not in ("RGBA", "LA", "P"):
        return im.convert("RGB")
    im = im.convert("RGBA")
    out = Image.new("RGB", im.size, (255, 255, 255))
    out.paste(im, mask=im.getchannel("A"))
    return out


def compose(base, frame_png, box, s, lights, height_pt, dark, mask, clip=None, radius=None):
    x, y, w, h = box
    win = frame_rgb(frame_png)
    if clip:
        # Only part of the window (points, from the top left; the frames are 2×): its subject, where the whole window
        # wouldn't fit beside the caption.
        cx, cy, cw, ch = clip
        win = win.crop((round(cx * 2), round(cy * 2), round((cx + cw) * 2), round((cy + ch) * 2)))
    win = win.resize((w, h), Image.LANCZOS)
    d = ImageDraw.Draw(win, "RGBA")
    # The traffic lights in colour (an offscreen window draws them inactive), as MarketingStudio does.
    ox, oy = (clip[0], clip[1]) if clip else (0, 0)
    for (lx, ly), (fill, edge) in zip(lights, LIGHTS):
        cx, cy, r = (lx - ox) * s, (height_pt - ly - oy) * s, 6 * s
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill, outline=edge, width=1)
    out = base.copy()
    out.paste(win, (x, y), mask)
    # The window's hairline edge.
    ImageDraw.Draw(out, "RGBA").rounded_rectangle((x, y, x + w - 1, y + h - 1), radius=radius or studio.WINDOW_RADIUS * s,
                                                  outline=(0, 0, 0, 140 if dark else 40), width=1)
    return out


def build_one(pack, spec, kind, out_dir):
    frames_dir = studio.ARTIFACTS / "_frames" / spec["motion"]
    manifest = json.loads((frames_dir / f"{spec['motion']}.json").read_text())
    win_w, win_h = manifest["width"], manifest["height"]
    clip = spec.get("clip")
    box, s = window_box(kind, clip[2] if clip else win_w, clip[3] if clip else win_h, spec.get(f"scale_{kind}"))
    # The window's own corners (onboarding's are rounder than a browser window's), in points in the manifest.
    radius = manifest.get("radius", studio.WINDOW_RADIUS) * s
    work = studio.CACHE / pack["slug"] / f"{spec['id']}-{kind}"
    work.mkdir(parents=True, exist_ok=True)
    size = KINDS[kind]["size"]
    captions = spec.get("captions", {})
    line_for = lambda label: captions.get(label, spec.get("line", ""))
    plates = {}

    def plate_img(label):
        if label not in plates:
            doc = plate(kind, box, radius, spec.get("tag", ""), spec["title"], line_for(label), steps=spec.get("steps"), current=label,
                        soon=pack.get("kind") == "teaser")
            plates[label] = Image.open(studio.render(doc, work / f"plate-{label or 'default'}.png", *size)).convert("RGB")
        return plates[label]

    end_line = spec.get("end_line") or pack.get("end_line", "Free, for Macs with Apple silicon · aircbrowser.com")
    end_doc = plate(kind, box, radius, "", spec.get("end_title") or pack.get("end_title", "Airc 0.1.2"), end_line, end=True,
                    soon=pack.get("kind") == "teaser", note=spec.get("end_note", ""))
    end = Image.open(studio.render(end_doc, work / "end.png", *size)).convert("RGB")
    mask = rounded_mask((box[2], box[3]), radius)

    mp4 = out_dir / f"{spec['id']}-{size[0]}x{size[1]}.mp4"
    ff = subprocess.Popen([studio.tool("ffmpeg"), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                           "-s", f"{size[0]}x{size[1]}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow",
                           "-crf", "18", "-pix_fmt", "yuv420p", "-profile:v", "high", "-movflags", "+faststart", str(mp4)],
                          stdin=subprocess.PIPE)
    written = 0

    def emit(img, n=1):
        nonlocal written
        data = img.tobytes()
        for _ in range(n):
            ff.stdin.write(data)
        written += n

    # Each frame's caption: a label holds until the next one. With steps (the Spaces' names), the frames between two
    # labels already show the next step, so a name lights up as its swipe starts, not after it has settled.
    frames = manifest["frames"]
    labels, cur = [], ""
    order = reversed(frames) if spec.get("steps") else frames
    for f in order:
        cur = f.get("label") or cur
        labels.append(cur)
    if spec.get("steps"):
        labels.reverse()

    fade_len = 15   # a changed caption fades over 0.25 s, under the moving window
    fade_from, fade_i = None, fade_len
    label = labels[0] if labels else ""
    prev = None
    poster = None
    # Cards before the take (the intro's hook), each faded into the next and into the first frame.
    for n, c in enumerate(spec.get("cards_before", [])):
        doc = plate(kind, box, radius, "", c["title"], c.get("line", ""), end=True, accent=c.get("accent", False),
                    lockup=c.get("lockup", True))
        img = Image.open(studio.render(doc, work / f"card-{n}.png", *size)).convert("RGB")
        if prev is not None:
            a = prev
            for i in range(1, 19):
                t = i / 18
                emit(Image.blend(a, img, t * t * (3 - 2 * t)))
        emit(img, round(c.get("seconds", 1.8) * FPS))
        prev = img
    card_before = prev
    last = None   # the frame before this one, for the window's cross-fade
    win = lambda base, fr: compose(base, frames_dir / fr["file"], box, s, manifest["lights"], win_h, fr.get("dark"), mask, clip, radius)
    for f, new_label in zip(frames, labels):
        if card_before is not None:
            first = win(plate_img(new_label), f)
            for i in range(1, 19):
                t = i / 18
                emit(Image.blend(card_before, first, t * t * (3 - 2 * t)))
            card_before = None
        if new_label != label and (line_for(new_label) != line_for(label) or spec.get("steps")):
            fade_from, fade_i = plate_img(label), 0
        label = new_label
        n = max(1, round(f["hold"] * FPS))
        img = win(plate_img(label), f)
        # Real states a moment apart (a theme changed): a short cross-fade from the last one, taken from this one's hold.
        blend = spec.get("fade_frames", 0) if last is not None and n > spec.get("fade_frames", 0) else 0
        # The caption's fade and the window's cross-fade start on the same frame and run together: one after the other,
        # the picture would show the new window, step back to the old one and fade forward again.
        i, settled = 0, None
        while n > 0 and (i < blend or (fade_from is not None and fade_i < fade_len)):
            i += 1
            if fade_from is not None and fade_i < fade_len:
                fade_i += 1
                base = Image.blend(fade_from, plate_img(label), fade_i / fade_len)
                cur, old = win(base, f), (win(base, last) if i <= blend else None)
            else:
                settled = settled or win(plate_img(label), last)
                cur, old = img, (settled if i <= blend else None)
            if old is not None:
                t = i / blend
                cur = Image.blend(old, cur, t * t * (3 - 2 * t))
            emit(cur)
            n -= 1
        if n > 0:
            emit(img, n)
        prev, last = img, f
        if poster is None and f["hold"] >= 0.5:
            poster = img
    # The end card: a 0.4 s cross-fade, then 1.8 s.
    a, b = np.asarray(prev, dtype=np.float32), np.asarray(end, dtype=np.float32)
    for i in range(1, 25):
        t = i / 24
        t = t * t * (3 - 2 * t)
        emit(Image.fromarray((a * (1 - t) + b * t).astype(np.uint8)))
    emit(end, round(1.8 * FPS))
    ff.stdin.close()
    if ff.wait() != 0:
        raise SystemExit(f"ffmpeg failed for {mp4}")
    poster_file = out_dir / f"{spec['id']}-{size[0]}x{size[1]}-poster.jpg"
    (poster or prev).save(poster_file, quality=90)
    records = [{"id": spec["id"], "kind": kind, "file": mp4.name, "poster": poster_file.name, "width": size[0], "height": size[1],
                "seconds": written / FPS, "bytes": mp4.stat().st_size, "alt": spec["alt"], "title": spec["title"],
                "frames_rendered": len(manifest["frames"])}]
    print(f"  {mp4.name}  {written / FPS:.1f} s  {mp4.stat().st_size / 1e6:.1f} MB")
    if kind == "16x9":
        gif = out_dir / f"{spec['id']}-960x540.gif"
        palette = work / "palette.png"
        ffmpeg = studio.tool("ffmpeg")
        # GIFs stay under 15 MB: a long one (the import's 20 s) gets fewer frames a second.
        for gif_fps in (30, 20, 15):
            subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", str(mp4), "-vf",
                            f"fps={gif_fps},scale=960:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=200", str(palette)], check=True)
            subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", str(mp4), "-i", str(palette), "-lavfi",
                            f"fps={gif_fps},scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                            str(gif)], check=True)
            if gif.stat().st_size < 14_500_000:
                break
        records.append({"id": spec["id"], "kind": "gif", "file": gif.name, "poster": poster_file.name, "width": 960, "height": 540,
                        "seconds": written / FPS, "bytes": gif.stat().st_size, "alt": spec["alt"], "title": spec["title"]})
        print(f"  {gif.name}  {gif.stat().st_size / 1e6:.1f} MB")
    return records


def build_web(pack, spec):
    """The website's copy (ARTIFACTS/web/<feature>/): the window alone at 1× (no caption, no end card, square corners: the
    page gives it its own radius and shadow), looping from its last frame back to its first, with a poster and meta.json."""
    frames_dir = studio.ARTIFACTS / "_frames" / spec["motion"]
    manifest = json.loads((frames_dir / f"{spec['motion']}.json").read_text())
    w, h = round(manifest["width"]), round(manifest["height"])
    s = 1.0
    out = studio.ARTIFACTS / "web" / spec["web"]
    out.mkdir(parents=True, exist_ok=True)
    mp4 = out / f"{spec['web']}.mp4"
    ff = subprocess.Popen([studio.tool("ffmpeg"), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
                           "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "23", "-pix_fmt", "yuv420p",
                           "-profile:v", "high", "-movflags", "+faststart", "-an", str(mp4)], stdin=subprocess.PIPE)
    count, first = 0, None
    for f in manifest["frames"]:
        win = frame_rgb(frames_dir / f["file"]).resize((w, h), Image.LANCZOS)
        d = ImageDraw.Draw(win)
        for (lx, ly), (fill, edge) in zip(manifest["lights"], LIGHTS):
            cx, cy, r = lx * s, (h - ly) * s, 6 * s
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill, outline=edge, width=1)
        first = first or win
        n = max(1, round(f["hold"] * FPS))
        data = win.tobytes()
        for _ in range(n):
            ff.stdin.write(data)
        count += n
    ff.stdin.close()
    if ff.wait() != 0:
        raise SystemExit(f"ffmpeg failed for {mp4}")
    first.save(out / "poster.jpg", quality=88)
    meta = {"feature": spec["web"], "title": spec["title"], "line": spec.get("line", ""), "alt": spec["alt"],
            "since": spec.get("since") or pack.get("since", ""), "released": pack.get("kind") != "teaser", "width": w, "height": h,
            "seconds": round(count / FPS, 2), "file": mp4.name, "poster": "poster.jpg", "pack": pack["slug"],
            "corner_radius_px": manifest.get("radius", studio.WINDOW_RADIUS),
            # The source revision that drew the frames (a release's own source for a released feature).
            "rendered_from": (frames_dir / "source.txt").read_text().strip() if (frames_dir / "source.txt").exists() else ""}
    (out / "meta.json").write_text(json.dumps(meta, indent=1, ensure_ascii=False))
    print(f"  web/{spec['web']}/{mp4.name}  {count / FPS:.1f} s  {mp4.stat().st_size / 1e6:.1f} MB")


def build_reel(pack, spec, kind, out_dir):
    """Several motions' frames in one video (an intro): a title card, each motion under its own caption with a short
    cross-fade between them, each frame held no longer than its segment's `max_hold`, then an end card."""
    size = KINDS[kind]["size"]
    work = studio.CACHE / pack["slug"] / f"{spec['id']}-{kind}"
    work.mkdir(parents=True, exist_ok=True)
    mp4 = out_dir / f"{spec['id']}-{size[0]}x{size[1]}.mp4"
    ff = subprocess.Popen([studio.tool("ffmpeg"), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                           "-s", f"{size[0]}x{size[1]}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow",
                           "-crf", "18", "-pix_fmt", "yuv420p", "-profile:v", "high", "-movflags", "+faststart", str(mp4)],
                          stdin=subprocess.PIPE)
    written = 0

    def emit(img, n=1):
        nonlocal written
        data = img.tobytes()
        for _ in range(n):
            ff.stdin.write(data)
        written += n

    def card(name, title, line):
        doc = plate(kind, (0, 0, 0, 0), 0, "", title, line, end=True)
        return Image.open(studio.render(doc, work / f"{name}.png", *size)).convert("RGB")

    def fade(a, b, n=18):
        for i in range(1, n + 1):
            t = i / n
            emit(Image.blend(a, b, t * t * (3 - 2 * t)))

    intro = card("intro", spec["intro_title"], spec.get("intro_line", ""))
    emit(intro, round(spec.get("intro_seconds", 1.8) * FPS))
    prev, poster = intro, None
    for n, seg in enumerate(spec["segments"]):
        frames_dir = studio.ARTIFACTS / "_frames" / seg["motion"]
        manifest = json.loads((frames_dir / f"{seg['motion']}.json").read_text())
        clip = seg.get("clip")
        box, s = window_box(kind, clip[2] if clip else manifest["width"], clip[3] if clip else manifest["height"], seg.get(f"scale_{kind}"))
        radius = manifest.get("radius", studio.WINDOW_RADIUS) * s
        doc = plate(kind, box, radius, seg.get("tag", ""), seg["title"], seg.get("line", ""))
        base = Image.open(studio.render(doc, work / f"plate-{n}.png", *size)).convert("RGB")
        mask = rounded_mask((box[2], box[3]), radius)
        frames = manifest["frames"][seg.get("start", 0):seg.get("end")]
        for i, f in enumerate(frames):
            img = compose(base, frames_dir / f["file"], box, s, manifest["lights"], manifest["height"], f.get("dark"), mask, clip, radius)
            hold = max(1, round(min(f["hold"], seg.get("max_hold", 0.9)) * FPS))
            if i == 0:
                fade(prev, img)
                if poster is None:
                    poster = img
            emit(img, hold)
            prev = img
    end = card("end", spec["end_title"], spec.get("end_line", ""))
    fade(prev, end, 24)
    emit(end, round(spec.get("end_seconds", 2.6) * FPS))
    ff.stdin.close()
    if ff.wait() != 0:
        raise SystemExit(f"ffmpeg failed for {mp4}")
    poster_file = out_dir / f"{spec['id']}-{size[0]}x{size[1]}-poster.jpg"
    (poster or intro).save(poster_file, quality=90)
    print(f"  {mp4.name}  {written / FPS:.1f} s  {mp4.stat().st_size / 1e6:.1f} MB")
    return [{"id": spec["id"], "kind": kind, "file": mp4.name, "poster": poster_file.name, "width": size[0], "height": size[1],
             "seconds": written / FPS, "bytes": mp4.stat().st_size, "alt": spec["alt"], "title": spec["title"]}]


def build(pack, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for spec in pack.get("video", []):
        if spec.get("segments"):
            missing = [g["motion"] for g in spec["segments"] if not (studio.ARTIFACTS / "_frames" / g["motion"] / f"{g['motion']}.json").exists()]
            if missing:
                print(f"  {spec['id']}: no frames yet for {', '.join(missing)}")
                continue
            for kind in spec.get("kinds", ["16x9", "1x1"]):
                records += build_reel(pack, spec, kind, out_dir)
            continue
        frames = studio.ARTIFACTS / "_frames" / spec["motion"] / f"{spec['motion']}.json"
        if not frames.exists():
            print(f"  {spec['id']}: no frames yet ({frames}); run tools/social/mac-frames.sh --motions {spec['motion']}")
            continue
        for kind in spec.get("kinds", ["16x9", "1x1"]):
            records += build_one(pack, spec, kind, out_dir)
        if spec.get("web"):
            build_web(pack, spec)
    return records
