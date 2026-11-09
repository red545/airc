# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The X profile's own pictures, from the brand kit: avatars (1000 × 1000; X shows them in a circle, so the icon sits well
inside it) and header banners (1500 × 500; X puts the avatar over the bottom left, so that corner stays empty), into
ARTIFACTS/brand-x/ with a manifest the gallery lists for download.

    python3 tools/social/brandx.py
"""
import json

from PIL import Image

import cards
import studio

OUT = studio.ARTIFACTS / "brand-x"
ICON = studio.BRAND / "airc-holographic.svg"

WASH = ("radial-gradient(70% 90% at 0% 0%, rgb(95 227 180 / .55), transparent 70%),"
        "radial-gradient(60% 80% at 100% 0%, rgb(199 155 255 / .55), transparent 70%),"
        "radial-gradient(70% 80% at 100% 100%, rgb(255 201 153 / .6), transparent 70%),"
        "radial-gradient(60% 70% at 10% 100%, rgb(127 176 255 / .45), transparent 70%), #FCFBFA")

# The profile's bio (160 characters at most). Each claim is the homepage's or the launch copy's: free, open source,
# Arc's sidebar, Spaces and ⌘T, the Arc import; AI agents build and maintain it.
BIO = [
    ("Recommended", "Arc, kept going. A free, open-source Mac browser with Arc's sidebar, Spaces and ⌘T. Built and maintained "
                    "by AI agents."),
    ("Leads with the import", "Leaving Arc? Airc brings your Spaces, pinned tabs and ⌘T over in about a minute. Free, open "
                              "source, built and maintained by AI agents."),
    ("Shortest", "A Mac browser that works the way Arc does. Free and open source. Built and maintained by AI agents."),
]

AVATARS = [
    ("airc-x-avatar-paper", "Paper, the brand's light background", cards.BACKGROUNDS["release"]),
    ("airc-x-avatar-wash", "The icon's own colours, stronger", WASH),
    ("airc-x-avatar-night", "Night, for a dark profile", "#110F0E"),
]

CSS = """*{margin:0;padding:0;box-sizing:border-box}html,body{width:%(w)dpx;height:%(h)dpx;overflow:hidden}
body{position:relative;background:%(bg)s;font-family:Figtree,Inter,sans-serif;-webkit-font-smoothing:antialiased;color:rgb(20 17 15 / .92)}"""


def avatar(name, bg):
    w = h = 1000
    icon = 660   # 66 %: the squircle's corners stay inside X's circle (checked with a circle mask)
    body = (f'<img src="{ICON.as_uri()}" style="position:absolute;left:{(w - icon) // 2}px;top:{(h - icon) // 2}px;'
            f'width:{icon}px;height:{icon}px;filter:drop-shadow(0 18px 40px rgb(40 30 20 / .22))">')
    doc = f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS % {"w": w, "h": h, "bg": bg}}</style></head><body>{body}</body></html>'
    return studio.render(doc, OUT / f"{name}.png", w, h, transparent=False)


def banner_brand():
    """The lockup and one line, centred: clear of the avatar at the bottom left on every screen."""
    w, h = 1500, 500
    css = studio.font_faces() + CSS % {"w": w, "h": h, "bg": WASH} + """
    .c{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:22px}
    .c img{height:96px}.c p{font:500 34px/1.2 Figtree,sans-serif;color:rgb(20 17 15 / .58);letter-spacing:-.015em}
    .u{position:absolute;right:56px;bottom:40px;font:500 22px Inter,sans-serif;color:rgb(20 17 15 / .5)}"""
    body = (f'<div class="c">{cards.lockup().replace("<b ", "<b style=font-size:64px ")}'
            f'<p>The Arc-style browser for Mac.</p></div><div class="u">aircbrowser.com</div>')
    doc = f'<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'
    return studio.render(doc, OUT / "airc-x-header.png", w, h)


def banner_spaces():
    """The real app on the right (the Spaces shot's four sidebars), the lockup on the left above the avatar's corner."""
    w, h = 1500, 500
    img, k, src = studio.shot("spaces")
    # The four windows, without most of the shot's desktop.
    crop = img.crop((round(110 * k), round(40 * k), img.width - round(60 * k), img.height - round(70 * k)))
    scale = 470 / crop.height
    crop = crop.resize((round(crop.width * scale), 470), Image.LANCZOS)
    tmp = studio.CACHE / "brand-x-spaces.png"
    crop.save(tmp)
    css = studio.font_faces() + CSS % {"w": w, "h": h, "bg": cards.BACKGROUNDS["release"]} + """
    .s{position:absolute;right:28px;top:15px;border-radius:18px;overflow:hidden;
      box-shadow:0 0 0 1px rgb(20 17 15 / .07),0 24px 48px -18px rgb(40 30 20 / .26)}
    .s img{display:block;height:470px}
    .t{position:absolute;left:64px;top:96px;width:420px}.t img{height:76px}
    .t p{margin-top:20px;font:600 40px/1.1 Figtree,sans-serif;letter-spacing:-.025em}
    .t p span{color:rgb(20 17 15 / .45)}
    .u{position:absolute;left:64px;top:300px;font:500 22px Inter,sans-serif;color:rgb(20 17 15 / .5)}"""
    body = (f'<div class="s"><img src="{tmp.as_uri()}"></div>'
            f'<div class="t">{cards.lockup().replace("<b ", "<b style=font-size:52px ")}'
            f'<p>Spaces, the way Arc did them. <span>Free for Mac.</span></p></div><div class="u">aircbrowser.com</div>')
    doc = f'<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'
    return studio.render(doc, OUT / "airc-x-header-spaces.png", w, h), src


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    files = []
    for name, about, bg in AVATARS:
        f = avatar(name, bg)
        files.append({"file": f.name, "kind": "Profile picture", "size": "1000 × 1000", "about": about})
    f = banner_brand()
    files.append({"file": f.name, "kind": "Header", "size": "1500 × 500", "about": "The lockup and one line, centred"})
    f, src = banner_spaces()
    files.append({"file": f.name, "kind": "Header", "size": "1500 × 500",
                  "about": "With the real app: four Spaces, each in its own colour (assets/screenshots/spaces)"})
    for r in files:
        r["bytes"] = (OUT / r["file"]).stat().st_size
        print(f"  brand-x/{r['file']}  {r['bytes'] / 1e6:.2f} MB")
    bio = [{"label": label, "text": text, "chars": len(text)} for label, text in BIO]
    for b in bio:
        if b["chars"] > 160:
            raise SystemExit(f"bio “{b['label']}” is {b['chars']} characters; X takes 160")
    (OUT / "manifest.json").write_text(json.dumps({"files": files, "bio": bio, "website": "aircbrowser.com"},
                                                  indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
