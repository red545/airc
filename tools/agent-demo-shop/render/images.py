# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Renders (PNG from products.py) → the shop's WebP photos, plus its favicon. Needs Pillow.
Usage: python3 images.py <render dir> <site dir>"""
import math
import os
import sys

from PIL import Image, ImageDraw

src, site = sys.argv[1], sys.argv[2]
img = os.path.join(site, "assets", "img")
os.makedirs(img, exist_ok=True)
for f in sorted(os.listdir(src)):
    if not f.endswith(".png"):
        continue
    im = Image.open(os.path.join(src, f)).convert("RGB")
    w = 2000 if im.width > im.height else 1000
    im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
    im.save(os.path.join(img, f[:-4] + ".webp"), quality=84, method=6)
    print(f, "→", im.size, os.path.getsize(os.path.join(img, f[:-4] + ".webp")) // 1024, "KB")

# The drop mark on the brand's pine, 128 px.
S = 512
fav = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(fav)
d.rounded_rectangle((0, 0, S - 1, S - 1), radius=112, fill=(36, 69, 58, 255))
pts = []
for i in range(181):
    t = i / 180 * math.pi * 2
    # a drop: circle bottom, pointed top
    x = math.sin(t) * (1 - 0.0) * 120 * (0.55 + 0.45 * (1 - math.cos(t)) / 2) ** 0.0
    pts.append((S / 2 + math.sin(t) * 120 * min(1, (1 - math.cos(t)) / 1.2), S / 2 + 40 - math.cos(t) * 150))
d.polygon(pts, fill=(246, 242, 236, 255))
fav.resize((128, 128), Image.LANCZOS).save(os.path.join(site, "assets", "favicon.png"))
print("favicon")

# The demo profile's made-up sites (Debug/MarketingAgentDemo.swift): a letter on a colour, 64 px.
from PIL import ImageFont

font_path = os.environ.get("AIDEMO_FAV_FONT")
if font_path:
    favdir = os.path.join(site, "assets", "fav")
    os.makedirs(favdir, exist_ok=True)
    for name, letter, colour in [("kite", "K", (59, 110, 214)), ("daybook", "D", (226, 98, 74)), ("loop", "L", (124, 88, 214)),
                                 ("shelf", "S", (222, 160, 52)), ("tally", "T", (46, 150, 96)), ("crumb", "C", (214, 128, 60)),
                                 ("atlas", "A", (32, 140, 150)), ("fieldnotes", "F", (38, 38, 44)), ("stride", "R", (220, 62, 92))]:
        im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        d.rounded_rectangle((0, 0, S - 1, S - 1), radius=120, fill=(*colour, 255))
        f = ImageFont.truetype(font_path, 330)
        d.text((S / 2, S / 2 + 8), letter, font=f, fill=(255, 255, 255, 255), anchor="mm")
        im.resize((64, 64), Image.LANCZOS).save(os.path.join(favdir, name + ".png"))
    print("favs")
