# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Shared pieces of the social studio (tools/social/README.md): paths, the brand's look, the shots and headless Chrome."""
import hashlib
import html
import json
import os
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageChops

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHOTS = ROOT / "assets/screenshots"
BRAND = ROOT / "assets/brand"
FONTS = ROOT / "apps/marketing/node_modules/@fontsource-variable"
PACKS = HERE / "packs"
# Generated media stays out of git: artifacts/social next to the repo, unless set.
ARTIFACTS = Path(os.environ.get("AIRC_SOCIAL_ARTIFACTS") or ROOT.parent / "artifacts" / "social")
# Where PNG originals of the shots are (outside the repo, next to it): scripts/marketing-shots.sh writes them under
# artifacts, agents' own runs under scratch. AIRC_SOCIAL_ORIGINALS: other folders, separated by ":".
ORIGINALS = [Path(p) for p in os.environ.get("AIRC_SOCIAL_ORIGINALS", "").split(os.pathsep) if p] or \
    [ROOT.parent / "artifacts", ROOT.parent / "scratch"]


def _originals(name):
    for root in ORIGINALS:
        if root.exists():
            yield from root.rglob(f"{name}.png")
CACHE = ARTIFACTS / "_cache"

# MarketingStudio.swift: room around a window on the shot's desktop, in points, and the shots' scale.
MARGIN = {"top": 64, "left": 84, "bottom": 104, "right": 84}
SCALE = 2
WINDOW_RADIUS = 16

# assets/brand/kit/airc-colors.json
INK = "#14110F"
PAPER = "#FCFBFA"
BLUE = "#3139FB"
RING = {"mint": "#5FE3B4", "sky": "#7FB0FF", "lilac": "#C79BFF", "rose": "#FF93C0", "apricot": "#FFC999", "seafoam": "#9AECCD"}


def tool(name):
    """ffmpeg and ffprobe: AIRC_FFMPEG_DIR, else PATH."""
    d = os.environ.get("AIRC_FFMPEG_DIR")
    path = str(Path(d) / name) if d else shutil.which(name)
    if not path or not Path(path).exists():
        raise SystemExit(f"{name} not found: put a static build on PATH or set AIRC_FFMPEG_DIR")
    return path


def chrome():
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"):
        if shutil.which(name):
            return shutil.which(name)
    raise SystemExit("no headless Chrome found")


def render(page_html, out, width, height, transparent=False):
    """Renders an HTML page at width × height CSS px (device scale 1) to a PNG with headless Chrome."""
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    src = CACHE / "html" / (out.stem + "-" + hashlib.sha1(page_html.encode()).hexdigest()[:10] + ".html")
    src.parent.mkdir(parents=True, exist_ok=True)
    src.write_text(page_html)
    args = [chrome(), "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
            "--run-all-compositor-stages-before-draw", "--virtual-time-budget=8000", "--allow-file-access-from-files",
            f"--screenshot={out}", f"--window-size={width},{height}"]
    if transparent:
        args.append("--default-background-color=00000000")
    subprocess.run(args + [src.as_uri()], capture_output=True, check=True, timeout=120)
    if not out.exists():
        raise SystemExit(f"Chrome wrote no {out}")
    return out


def font_faces():
    figtree = FONTS / "figtree/files/figtree-latin-wght-normal.woff2"
    inter = FONTS / "inter/files/inter-latin-wght-normal.woff2"
    for f in (figtree, inter):
        if not f.exists():
            raise SystemExit(f"{f} is missing: run pnpm install in apps/marketing (the homepage's fonts)")
    return (f'@font-face{{font-family:Figtree;src:url({figtree.as_uri()}) format("woff2");font-weight:300 900}}'
            f'@font-face{{font-family:Inter;src:url({inter.as_uri()}) format("woff2");font-weight:100 900}}')


# Keys: no font on the Linux box has ⌘ ⇧ ⌥ ⌃, so they're drawn (as assets/launch/features/build.py does).
_KEY_SVG = {
    "⌘": '<circle cx="6" cy="6" r="3"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="18" r="3"/>'
         '<path d="M9 6v12M15 6v12M6 9h12M6 15h12"/>',
    "⇧": '<path d="M12 3.5 3.5 12.5H8v8h8v-8h4.5z"/>',
    "⌥": '<path d="M3 6h5l8 12h5M14 6h7"/>',
    "⌃": '<path d="m5 14 7-7 7 7"/>',
}


def key_glyph(ch):
    if ch in _KEY_SVG:
        return ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
                f'stroke-linejoin="round" class="glyph">{_KEY_SVG[ch]}</svg>')
    return html.escape(ch)


def keycaps(keys):
    """"⇧⌘2" → three keycaps."""
    return "".join(f'<kbd>{key_glyph(ch)}</kbd>' for ch in keys)


def inline_keys(text):
    """Text with ⌘ ⇧ ⌥ ⌃ drawn inline (escaped otherwise); a word with a key never breaks ("⌘-click")."""
    words = []
    for word in text.split(" "):
        if any(ch in _KEY_SVG for ch in word):
            inner = "".join(key_glyph(ch).replace('class="glyph"', 'class="iglyph"') if ch in _KEY_SVG else html.escape(ch) for ch in word)
            words.append(f'<span style="white-space:nowrap">{inner}</span>')
        else:
            words.append(html.escape(word))
    return " ".join(words)


# MARK: Shots

def _thumb(img, w=320):
    img = img.convert("RGB")
    return img.resize((w, max(1, round(img.height * w / img.width))), Image.LANCZOS)


def committed(name, rev=None):
    """assets/screenshots/<name>.webp as it is now, or as it was at commit `rev` (a release's own shots: a shot retaken
    later may show what that release doesn't have). None if there is none."""
    if not rev:
        webp = SHOTS / f"{name}.webp"
        return webp if webp.exists() else None
    out = CACHE / "rev" / rev / f"{name}.webp"
    if not out.exists():
        r = subprocess.run(["git", "-C", str(ROOT), "show", f"{rev}:assets/screenshots/{name}.webp"], capture_output=True)
        if r.returncode != 0:
            return None
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(r.stdout)
    return out


def original(name, rev=None):
    """The 2× PNG original of the committed shot (now, or at `rev`) if one under ORIGINALS matches it pixel for pixel
    (within WebP's loss), else None. Check captures share some names, so a file is used only when it is that shot."""
    webp = committed(name, rev)
    if webp is None:
        return None
    CACHE.mkdir(parents=True, exist_ok=True)
    memo = CACHE / "originals.json"
    known = json.loads(memo.read_text()) if memo.exists() else {}
    key = f"{name}:{hashlib.sha1(webp.read_bytes()).hexdigest()[:16]}"
    if key in known:
        return Path(known[key]) if known[key] and Path(known[key]).exists() else None
    ref = Image.open(webp)
    ref_t = _thumb(ref)
    best, best_d = None, 1e9
    for p in _originals(name):
        if ARTIFACTS in p.parents:
            continue
        try:
            im = Image.open(p)
            if abs(im.width / im.height - ref.width / ref.height) > 0.002:
                continue
            t = _thumb(im)
            if t.size != ref_t.size:
                continue
            diff = ImageChops.difference(t, ref_t).convert("L")
            d = sum(diff.getdata()) / (t.width * t.height)
        except OSError:
            continue
        if d < best_d:
            best, best_d = p, d
    chosen = str(best) if best is not None and best_d < 2.5 else ""
    known[key] = chosen
    memo.write_text(json.dumps(known, indent=1, sort_keys=True))
    return Path(chosen) if chosen else None


def shot(name, rev=None):
    """(image, px per pt, source) for a shot: its 2× original when there is one, else the committed WebP."""
    o = original(name, rev)
    if o:
        return Image.open(o).convert("RGB"), SCALE, str(o)
    webp = committed(name, rev)
    if webp is None:
        if rev:
            raise SystemExit(f"no shot {name} at {rev}")
        # Shots of features not committed to assets/screenshots yet (a teaser): a PNG original by name.
        found = sorted(_originals(name), key=lambda p: p.stat().st_mtime, reverse=True)
        found = [p for p in found if "marketing" in p.parts and ARTIFACTS not in p.parents]
        if not found:
            raise SystemExit(f"no shot {name}")
        return Image.open(found[0]).convert("RGB"), SCALE, str(found[0])
    img = Image.open(webp).convert("RGB")
    # A WebP made from a wider original: its scale from the window's known widths (browser 1440 pt, Settings 780 pt).
    for pts_w, pts_h in ((1440, 900), (780, 600)):
        cw, ch = pts_w + MARGIN["left"] + MARGIN["right"], pts_h + MARGIN["top"] + MARGIN["bottom"]
        if abs(img.width / img.height - cw / ch) < 0.004:
            return img, img.width / cw, str(webp)
    return img, None, str(webp)


def window(name, rev=None):
    """The shot's main window alone, cut from its desktop: (image, px per pt, window size in pt, source)."""
    img, k, src = shot(name, rev)
    if k is None:
        raise SystemExit(f"{name}: unknown scale; use mode = \"plate\"")
    box = (round(MARGIN["left"] * k), round(MARGIN["top"] * k), round(img.width - MARGIN["right"] * k), round(img.height - MARGIN["bottom"] * k))
    win = img.crop(box)
    return win, k, (win.width / k, win.height / k), src
