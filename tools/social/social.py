#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The social studio: packs of images, short videos and copy for X, made from the real app (tools/social/README.md).

    social.py build PACK       images, videos, copy.md and pack.json into ARTIFACTS/<slug>/, then check them
    social.py cards PACK       only the images
    social.py video PACK       only the videos (frames from tools/social/mac-frames.sh)
    social.py copy PACK        only copy.md
    social.py check PACK       sizes, formats, post lengths and an OCR pass for private words
    social.py gallery          ARTIFACTS/index.html: every pack, for review on a phone

PACK is a file in tools/social/packs/ (with or without .toml). Drafts only: nothing here posts or uploads anything.
"""
import json
import re
import sys
import tomllib
import unicodedata
from pathlib import Path

import studio


def load(name):
    p = Path(name)
    if not p.exists():
        p = studio.PACKS / (name if name.endswith(".toml") else name + ".toml")
    pack = tomllib.loads(p.read_text())
    pack["_file"] = p.name
    return pack


def out_dir(pack):
    return studio.ARTIFACTS / pack["slug"]


# MARK: Post length, as X counts it (twitter-text v3: a link is 23; most scripts 1 per character, the rest 2)

URL = re.compile(r"(?:https?://)?(?:[a-z0-9-]+\.)+(?:com|org|net|app|dev|io|co)(?:/[^\s]*)?", re.I)


def x_length(text):
    text = unicodedata.normalize("NFC", text)
    n = 0
    for m in URL.finditer(text):
        n += 23
    rest = URL.sub("", text)
    for ch in rest:
        c = ord(ch)
        if ch in "️‍":
            continue
        n += 1 if (c <= 4351 or 8192 <= c <= 8205 or 8208 <= c <= 8223 or 8242 <= c <= 8247) else 2
    return n


# MARK: copy.md

def write_copy(pack, records, videos):
    d = out_dir(pack)
    lines = [f"# {pack['title']}", ""]
    if pack.get("summary"):
        lines += [pack["summary"].strip(), ""]
    lines += ["Drafts for the owner to post. Nothing has been posted. Every image is the real app with demo data.", ""]
    if pack.get("order"):
        lines += ["## Posting order", "", pack["order"].strip(), ""]
    posts = pack.get("post", [])
    if posts:
        lines += ["## Posts", ""]
        for i, p in enumerate(posts, 1):
            n = x_length(p["text"].strip())
            flag = "" if n <= 280 else "  **OVER 280**"
            lines += [f"### {i}. {p.get('label', '')}".rstrip(), "", "```text", p["text"].strip(), "```", "",
                      f"{n} / 280 characters (as X counts them){flag}", ""]
            if p.get("media"):
                lines.append("Media: " + ", ".join(f"`{m}`" for m in media_files(p["media"], records, videos)))
                lines.append("")
    lines += ["## Images and alt text", ""]
    for r in records:
        lines += [f"- `{r['file']}` ({r['width']} × {r['height']}, {r['bytes'] / 1e6:.2f} MB)", f"  Alt: {r['alt']}"]
    for v in videos:
        lines += [f"- `{v['file']}` ({v['width']} × {v['height']}, {v['seconds']:.1f} s, {v['bytes'] / 1e6:.1f} MB)", f"  Alt: {v['alt']}"]
    for s in pack.get("set", []):
        lines += ["", f"## {s['title']}", "", s.get("about", "").strip(), ""]
        for m in media_files(s["media"], records, videos):
            lines.append(f"- `{m}`")
    if pack.get("requests"):
        lines += ["", "## Requests for the owner", "", pack["requests"].strip()]
    if pack.get("checked"):
        lines += ["", "## Checked against", "", pack["checked"].strip()]
    (d / "copy.md").write_text("\n".join(lines).rstrip() + "\n")
    print(f"  copy.md ({len(posts)} posts)")


def media_files(refs, records, videos):
    """`announce` (both sizes) or `announce:16x9`, or a video id → file names."""
    out = []
    for ref in refs:
        rid, _, size = ref.partition(":")
        for r in records:
            if r["id"] == rid and (not size or r["size"] == size):
                out.append(r["file"])
        for v in videos:
            if v["id"] == rid and (not size or v.get("kind") == size):
                out.append(v["file"])
    return out


# MARK: Commands

def cmd_cards(pack):
    import cards
    print(f"== images: {pack['slug']}")
    return cards.build(pack, out_dir(pack))


def cmd_video(pack):
    import video
    print(f"== videos: {pack['slug']}")
    return video.build(pack, out_dir(pack))


def manifest(pack, records=None, videos=None):
    d = out_dir(pack)
    m = d / "pack.json"
    old = json.loads(m.read_text()) if m.exists() else {}
    data = {k: v for k, v in pack.items() if not k.startswith("_") and k not in ("image", "video")}
    data["images"] = records if records is not None else old.get("images", [])
    # A video whose file is gone (a take that was dropped) isn't listed.
    data["videos"] = [v for v in (videos if videos is not None else old.get("videos", [])) if (d / v["file"]).exists()]
    data["source_pack"] = pack["_file"]
    m.write_text(json.dumps(data, indent=1, ensure_ascii=False))
    return data


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[1]
    if cmd == "gallery":
        import gallery
        gallery.build()
        return 0
    if len(argv) < 3:
        print("which pack?", file=sys.stderr)
        return 2
    pack = load(argv[2])
    out_dir(pack).mkdir(parents=True, exist_ok=True)
    if cmd in ("build", "cards"):
        records = cmd_cards(pack)
        data = manifest(pack, records=records)
    if cmd in ("build", "video"):
        videos = cmd_video(pack)
        data = manifest(pack, videos=videos)
    if cmd in ("build", "cards", "video", "copy"):
        data = manifest(pack)
        write_copy(pack, data["images"], data["videos"])
    if cmd in ("build", "check"):
        import check
        ok = check.run(pack, manifest(pack))
        if cmd == "build":
            import gallery
            gallery.build()
        return 0 if ok else 1
    if cmd not in ("build", "cards", "video", "copy", "check"):
        print(f"unknown command {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
