"""The alternate app icons (Settings › Appearance › App Icon): Airc's own holographic icon, recoloured.

    python3 alticons.py       # writes build/alt/<id>-large.html and -small.html
    ./alticons.sh             # on the Mac: renders them with WebKit, packs app-icons/AppIcon-<id>.icns

Each variant is airc-holographic.svg (and, for 16 and 32 px, appicon.py's small-size variant) with its gradient stops,
the mark's ink and the face's border swapped: same geometry, same grid, same shadow. Nothing comes from another app.
"""
import contextlib
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).parent
with contextlib.redirect_stdout(io.StringIO()):
    import appicon  # noqa: E402  (imports build.py, which rewrites the logo SVGs identically)

# The holographic icon's colours (build.icon): ring stops, face stops, the four glow blobs (b1–b4).
RING = ["#5fe3b4", "#7fb0ff", "#c79bff", "#ff93c0", "#ffc999", "#9aeccd"]
FACE = ["#b4f0da", "#c4e0ff", "#e2d0ff", "#ffd3e3", "#cdebdd"]
BLOBS = ["#ffb8cf", "#bda5ff", "#8eeec6", "#fff"]

VARIANTS = {
    # The outline mark on white: ring, face and glows white, the black outline and border kept.
    "outline": dict(ring=["#ffffff"] * 6, face=["#ffffff"] * 5, blobs=["#ffffff"] * 4),
    "sunset": dict(ring=["#ff8a65", "#ff6f91", "#ffa36c", "#ffd36e", "#ffb199", "#ff9e7a"],
                   face=["#ffe1cc", "#ffd0d6", "#ffe6c2", "#ffd9b8", "#ffe9d6"],
                   blobs=["#ff9fb3", "#ffb37a", "#ffd98a", "#fff"]),
    "ocean": dict(ring=["#3ad1c8", "#4aa8ff", "#5b7cff", "#47c2ff", "#7de3f0", "#2fd3a6"],
                  face=["#c8f4f0", "#cfe6ff", "#d6dcff", "#c9efff", "#d3f5ec"],
                  blobs=["#8fd8ff", "#a8b6ff", "#7fe8d6", "#fff"]),
    # Night-blue face, white mark; the holographic ring stays.
    "midnight": dict(ring=RING, face=["#1d2747", "#222d57", "#2a2858", "#352a55", "#1d3546"],
                     blobs=["#6b4fd6", "#3557d0", "#1c8a80", "#8fa8ff"], ink="#ffffff"),
    # Monochrome.
    "graphite": dict(ring=["#e8e8e8", "#bcbcbc", "#9a9a9a", "#cdcdcd", "#f3f3f3", "#a6a6a6"],
                     face=["#f5f5f5", "#e3e3e3", "#d4d4d4", "#e8e8e8", "#f0f0f0"],
                     blobs=["#cfcfcf", "#bcbcbc", "#e2e2e2", "#fff"]),
}


def recolor(svg, v):
    """`svg` (build.icon's holographic layout) in variant `v`'s colours."""
    for old, new in zip(RING + FACE + BLOBS, v["ring"] + v["face"] + v["blobs"]):
        svg = svg.replace(f'stop-color="{old}"', f'stop-color="{new}"')
    ink = v.get("ink")
    if ink:
        # The mark's visible layers are the masked rects and, after the last of them, the round caps; inside the
        # masks black means "hide", so only those change.
        svg = svg.replace('fill="#000" mask="url(', f'fill="{ink}" mask="url(')
        i = svg.rfind('mask="url(')
        j = svg.find("</g>", i)
        svg = svg[:i] + svg[i:j].replace('fill="#000"', f'fill="{ink}"') + svg[j:]
    border = v.get("border")
    if border:
        k = svg.rfind('fill="none" stroke="#000"')
        svg = svg[:k] + svg[k:].replace('stroke="#000"', f'stroke="{border}"', 1)
    return svg


if __name__ == "__main__":
    out = ROOT / "build" / "alt"
    out.mkdir(parents=True, exist_ok=True)
    large = (ROOT / "airc-holographic.svg").read_text()
    small = appicon.small_icon()
    for name, v in VARIANTS.items():
        for kind, src, shadow in (("large", large, True), ("small", small, False)):
            svg = out / f"{name}-{kind}.svg"
            svg.write_text(recolor(src, v))
            (out / f"{name}-{kind}.html").write_text(
                appicon.PAGE.format(w=512 * appicon.BODY * 600 / 576, src=appicon.data_uri(svg, "image/svg+xml"),
                                    dy=5 if shadow else 0, blur=6 if shadow else 0, a=0.28 if shadow else 0))
    (out / "variants.json").write_text(json.dumps(list(VARIANTS)))
    if sys.argv[1:] == ["sheet"]:
        cells = "".join(
            f"<figure style='margin:0;text-align:center;color:#888'><img src='{appicon.data_uri(ROOT / 'app-icons' / f'AppIcon-{n}.png', 'image/png')}' "
            f"style='width:128px;height:128px'><figcaption>{n}</figcaption></figure>" for n in VARIANTS)
        (out / "sheet.html").write_text("<!doctype html><body style='margin:0;font:12px -apple-system'>"
                                        f"<div style='display:flex;gap:20px;padding:20px;background:#ECEAE6'>{cells}</div>"
                                        f"<div style='display:flex;gap:20px;padding:20px;background:#1E1C1B'>{cells}</div></body>")
    print("wrote", ", ".join(VARIANTS), "in build/alt")
