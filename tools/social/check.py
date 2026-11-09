# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Checks a built pack before it's shown to anyone: X's limits, alt text, post lengths, and an OCR pass over every image
and every distinct video frame for words that must never appear (the private patterns file, e-mail addresses, home
folders). OCR needs rapidocr_onnxruntime; without it that part is reported as skipped, never as passed."""
import json
import os
import re
import subprocess
from pathlib import Path

import social
import studio

PATTERNS = Path(os.environ.get("AIRC_PRIVATE_PATTERNS") or studio.ROOT.parent / "private-patterns.txt")
GENERIC = [r"[\w.+-]+@(?!example\.)[\w-]+\.[\w.]+", r"/Users/\w+", r"/home/\w+"]


def patterns():
    out = []
    lines = PATTERNS.read_text().splitlines() if PATTERNS.exists() else []
    for line in lines + GENERIC:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            out.append(re.compile(line, re.I))
        except re.error:
            out.append(re.compile(re.escape(line), re.I))
    return out, PATTERNS.exists()


def ocr_engine():
    try:
        from rapidocr_onnxruntime import RapidOCR
    except ImportError:
        return None
    return RapidOCR()


def ocr_text(engine, path):
    result, _ = engine(str(path))
    return " ".join(r[1] for r in (result or []))


def probe(path):
    out = subprocess.run([studio.tool("ffprobe"), "-v", "error", "-show_entries", "stream=codec_name,width,height,pix_fmt,r_frame_rate",
                          "-show_entries", "format=duration", "-of", "json", str(path)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def step_backs(path, width=320):
    """Seconds where a video jumps back to a picture it showed a moment before (within 40 frames): a stutter, such as
    a cross-fade that starts from the old frame after the new one was already on screen."""
    import numpy as np
    info = probe(path)["streams"][0]
    num, den = map(int, info["r_frame_rate"].split("/"))
    h = round(info["height"] * width / info["width"] / 2) * 2
    raw = subprocess.run([studio.tool("ffmpeg"), "-v", "error", "-i", str(path), "-vf", f"scale={width}:{h}", "-f", "rawvideo",
                          "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, h, width).astype(np.int16)
    out = []
    for i in range(2, len(a)):
        jump = np.abs(a[i] - a[i - 1]).mean()
        if jump < 2:
            continue
        back = min(np.abs(a[i] - a[i - k]).mean() for k in range(2, min(40, i) + 1))
        if back < 0.15 * jump:
            out.append(i * den / num)
    return out


def run(pack, data):
    d = social.out_dir(pack)
    problems, notes = [], []
    for r in data["images"]:
        f = d / r["file"]
        if not f.exists():
            problems.append(f"{r['file']}: missing")
            continue
        from PIL import Image
        with Image.open(f) as im:
            if im.size != (r["width"], r["height"]):
                problems.append(f"{r['file']}: {im.size}, expected {r['width']}×{r['height']}")
            if im.format not in ("PNG", "JPEG"):
                problems.append(f"{r['file']}: {im.format}")
        if f.stat().st_size >= 5_000_000:
            problems.append(f"{r['file']}: {f.stat().st_size / 1e6:.1f} MB (X takes images under 5 MB)")
        if not r.get("alt"):
            problems.append(f"{r['file']}: no alt text")
        if r.get("upscale", 1) > 1.25:
            notes.append(f"{r['file']}: window upscaled {r['upscale']}×")
    for v in data["videos"]:
        f = d / v["file"]
        if not f.exists():
            problems.append(f"{v['file']}: missing")
            continue
        if v["kind"] == "gif":
            if f.stat().st_size >= 15_000_000:
                problems.append(f"{v['file']}: {f.stat().st_size / 1e6:.1f} MB (GIFs under 15 MB)")
            continue
        info = probe(f)
        stream = info["streams"][0]
        seconds = float(info["format"]["duration"])
        if stream["codec_name"] != "h264" or stream.get("pix_fmt") != "yuv420p":
            problems.append(f"{v['file']}: {stream['codec_name']} {stream.get('pix_fmt')}, expected h264 yuv420p")
        if not 6 <= seconds <= 30:
            problems.append(f"{v['file']}: {seconds:.1f} s (6 to 30 s)")
        if f.stat().st_size >= 512_000_000:
            problems.append(f"{v['file']}: over 512 MB")
        if not v.get("alt"):
            problems.append(f"{v['file']}: no alt text")
        back = step_backs(f)
        if back:
            problems.append(f"{v['file']}: steps back to an earlier picture at {', '.join(f'{t:.2f} s' for t in back)}")
    for i, p in enumerate(pack.get("post", []), 1):
        n = social.x_length(p["text"].strip())
        if n > 280:
            problems.append(f"post {i}: {n} characters (280 at most)")
        missing = [m for m in p.get("media", []) if not social.media_files([m], data["images"], data["videos"])]
        if missing:
            problems.append(f"post {i}: media not built: {', '.join(missing)}")

    # Privacy: OCR every image, every poster and each distinct frame the videos were made from.
    pats, have_file = patterns()
    if not have_file:
        notes.append(f"no private patterns file at {PATTERNS}; only generic patterns checked")
    engine = ocr_engine()
    scanned = 0
    if engine is None:
        notes.append("OCR SKIPPED: rapidocr_onnxruntime isn't installed; look at every frame yourself")
    else:
        files = [d / r["file"] for r in data["images"]] + sorted({d / v["poster"] for v in data["videos"] if v.get("poster")})
        motions = {spec["motion"] for spec in pack.get("video", []) if spec.get("motion")}
        motions |= {g["motion"] for spec in pack.get("video", []) for g in spec.get("segments", [])}
        for motion in sorted(motions):
            frames = studio.ARTIFACTS / "_frames" / motion
            m = frames / f"{motion}.json"
            if m.exists():
                files += [frames / f["file"] for f in json.loads(m.read_text())["frames"]]
        for f in dict.fromkeys(files):
            if not f.exists():
                continue
            text = ocr_text(engine, f)
            scanned += 1
            for p in pats:
                hit = p.search(text)
                if hit:
                    problems.append(f"PRIVATE? {f.name}: matches pattern {pats.index(p) + 1}: “{hit.group(0)}”")
    report = {"pack": pack["slug"], "ok": not problems, "problems": problems, "notes": notes, "ocr_scanned": scanned}
    (d / "check.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    print(f"== check: {'OK' if not problems else 'PROBLEMS'} ({scanned} files read by OCR)")
    for p in problems:
        print("  ✗ " + p)
    for n in notes:
        print("  · " + n)
    return not problems
